# frozen_string_literal: true

BOOT_PROFILE = false unless defined?(BOOT_PROFILE)

require_relative 'spell_abbreviations'
require_relative 'games/dragonrealms'
require_relative 'games/gemstone'
require_relative 'room_data_processor'
require_relative 'familiar_notifier'
require_relative 'xml_tokenizer'
require_relative 'tag_handlers'
require_relative 'styled_text'
require_relative 'event_bus'

# Processes game server output in a dedicated thread, handling XML tag parsing,
# stream routing, room data assembly, spell abbreviation, and UI updates.

# Processes all game text received from the server read thread.
#
# Handles the full pipeline from raw server output to rendered UI:
# XML tag parsing, stream routing (combat, death, logons, etc.),
# room data assembly (title, description, objects, players, exits),
# spell name abbreviation for percWindow, indicator/progress/countdown
# updates, stun detection, bold/color/preset tracking, highlight
# application, and movement suppression.
#
# Tag processing uses a tokenize-and-dispatch architecture:
# XmlTokenizer splits each line into text and tag segments,
# TagHandlers dispatches each tag to a focused handler method
# via a hash lookup table.
#
# UI updates are emitted via an EventBus rather than calling window
# methods directly. This decouples parsing from rendering and enables
# testing without curses.
#
# @example
#   bus = EventBus.new
#   processor = GameTextProcessor.new(
#     window_mgr:  wm,
#     shared_state: state,
#     cmd_buffer:   cmd_buffer,
#     xml_escapes:  { '&gt;' => '>', '&lt;' => '<' },
#     event_bus:    bus
#   )
#   processor.run(server)
class GameTextProcessor
  include Games::DragonRealms
  include RoomDataProcessor
  include FamiliarNotifier
  include TagHandlers

  # Movement verbs that suppress the following prompt and empty line.
  MOVEMENT_PATTERN = /^You (?:run|walk|go|swim|climb|crawl|drag|stride|sneak|stalk)\b/

  # Precomputed merged logon patterns (DR + GS) and matching regex.
  # Built once at load time instead of on every logon line.
  ALL_LOGON_PATTERNS = Games::DragonRealms::LOGON_PATTERNS.merge(Games::GemStone::LOGON_PATTERNS).freeze
  LOGON_REGEXP = /^\s\*\s(?<name>[A-Z][a-z]+) (?<type>#{ALL_LOGON_PATTERNS.keys.map { |k| Regexp.escape(k) }.join('|')})/

  # Create a new processor wired to the given window manager and shared state.
  #
  # @param window_mgr [WindowManager] provides handler hashes for stream/indicator/progress/countdown/room windows
  # @param shared_state [OpenStruct] mutable state shared with the input thread (need_prompt, prompt_text, skip_server_time_offset)
  # @param cmd_buffer [CommandBuffer] the command-line input buffer (used for Curses refresh coordination)
  # @param xml_escapes [Hash<String, String>] XML entity to character mappings (e.g. +"&gt;"+ => +">"+)
  # @param event_bus [EventBus] event bus for decoupled UI updates
  def initialize(window_mgr:, shared_state:, cmd_buffer:, xml_escapes:, event_bus:)
    @wm = window_mgr
    @state = shared_state
    @cmd_buffer = cmd_buffer
    @xml_escapes = xml_escapes
    @event_bus = event_bus

    # Line color/style tracking
    @line_colors = []
    @open_monsterbold = []
    @open_preset = []
    @open_style = nil
    @open_color = []
    @open_link = []

    # Stream and display state
    @current_stream = nil
    @bold_next_line = false
    @emptycount = 0
    @combat_next_line = nil
    @need_update = false
    @need_room_render = false
    @first_render = true

    # Track content sent to dedicated stream windows to prevent duplicates to main
    @last_stream_text = nil

    # Track movement messages to suppress prompts/empty lines after them
    @last_was_movement = false

    # Room data tracking for RoomWindow
    @room_capture_mode = nil # :title, :desc, or nil
    @room_pending_title = nil
    @room_pending_title_colors = nil
    @room_pending_desc = nil
    @room_pending_objects = nil
    @room_pending_players = nil
    @room_pending_exits = nil
    @room_pending_number = nil
    @current_raw_line = nil # Raw line with XML tags preserved for room object extraction
  end

  # Main processing loop. Blocks on +server.gets+ reading lines from the
  # game server socket and processes each through XML tag extraction,
  # stream routing, bold/color tracking, room data assembly, and window
  # updates. Exits (calls +exit+) when the connection is closed or an
  # unrecoverable error occurs.
  #
  # @param server [IO] TCP socket (or socket-like) connected to the game server
  # @return [void] never returns normally; calls +exit+ on disconnect or error
  def run(server)
    line = nil
    first_line = true

    while (line = server.gets)
      if first_line && BOOT_PROFILE
        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - BOOT_T0) * 1000).round(1)
        ProfanityLog.write('boot-profile', "first server data received: #{elapsed}ms")
        first_line = false
      end

      if line =~ %r{^<popBold/>}
        @bold_next_line = false
      elsif @bold_next_line == true
        line = "<pushBold/>#{line.chomp}<popBold/>\n"
      elsif line =~ %r{<pushBold/>\r\n$}
        @bold_next_line = true
      end

      line.chomp!

      if line.match(GagPatterns.general_regexp)
        next
      elsif line.empty?
        @emptycount += 1
        if @emptycount > 1
          line = nil
          next
        end
      else
        @emptycount = 0
      end

      # Synchronize all curses operations (noutrefresh calls from indicator,
      # text, countdown, and room window updates) with the final doupdate so
      # that timer and input threads cannot flush a half-updated virtual screen. # -- flat indent avoids re-indent
      CursesRenderer.synchronize do
        if line.empty?
          if @current_stream.nil?
            # Check if last line in ANY tab was movement (backup check)
            main_window = @wm.stream[MAIN_STREAM]
            last_line_was_movement = false
            if main_window.is_a?(TabbedTextWindow)
              # Check all tabs for recent movement (movement could be in main, combat, etc.)
              main_window.tabs.each_value do |tab_buffer|
                last_entry = tab_buffer.find { |entry| entry[0] && !entry[0].strip.empty? }
                if last_entry && last_entry[0] =~ MOVEMENT_PATTERN
                  last_line_was_movement = true
                  break
                end
              end
            elsif main_window.respond_to?(:buffer) && !main_window.buffer.empty?
              last_entry = main_window.buffer.find { |entry| entry[0] && !entry[0].strip.empty? }
              last_line_was_movement = last_entry && last_entry[0] =~ MOVEMENT_PATTERN
            end

            # Skip prompt and empty line after movement (use flag OR buffer check)
            if @last_was_movement || last_line_was_movement
              @state.need_prompt = false
              @last_was_movement = false
              # Skip the empty line entirely
            else
              if @state.need_prompt
                @state.need_prompt = false
                @event_bus.emit(:add_prompt, stream: MAIN_STREAM, text: @state.prompt_text)
              end
              @event_bus.emit(:stream_text, stream: MAIN_STREAM, text: String.new, colors: [])
              @need_update = true
            end
          end
        else
          @current_raw_line = line.dup
          process_line_tags(line)
        end
        #
        # Flush screen update unless more game lines are waiting (batch rendering).
        # IO.select returns nil (no data waiting) when we should flush now.
        #
        if @need_update && !IO.select([server], nil, nil, 0.001)
          @need_update = false
          if @need_room_render
            @event_bus.emit(:room_render)
            @need_room_render = false
          end
          @cmd_buffer.window&.noutrefresh
          Curses.doupdate
          if @first_render && BOOT_PROFILE
            elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - BOOT_T0) * 1000).round(1)
            ProfanityLog.write('boot-profile', "first screen render: #{elapsed}ms")
            @first_render = false
          end
        end
      end # CursesRenderer.synchronize
      # Flush terminal title AFTER curses operations complete.
      # Writing escape sequences to $stdout inside the synchronize block
      # interleaves with curses output, causing visible artifacts.
      @state.update_terminal_title
    end
    # After loop exits (connection closed):
    show_disconnect_message
    @cmd_buffer.window&.getch
    exit
  rescue IOError => e
    # Normal disconnect — socket closed by another thread (e.g., Lich shutdown)
    ProfanityLog.write('game_text_processor', "disconnected: #{e.message}")
    show_disconnect_message
    @cmd_buffer.window&.getch
    exit
  rescue StandardError => e
    ProfanityLog.write('game_text_processor', e.to_s, backtrace: e.backtrace)
    exit
  end

  private

  def show_disconnect_message
    @event_bus.emit(:disconnect)
    CursesRenderer.render do
      @cmd_buffer.window&.noutrefresh
    end
  end

  # Parse a room subtitle attribute into a clean room title string.
  #
  # Handles both GemStone and DragonRealms subtitle formats:
  # - GS: +" - [Town Square, Center]"+ → +"Town Square, Center"+
  # - DR: +" - [Bosque Deriel, Shacks] (230008)"+ → +"Bosque Deriel, Shacks (230008)"+
  #
  # @param subtitle [String] raw subtitle attribute value
  # @return [String] cleaned room title (may be empty)
  # @api private
  def parse_room_subtitle(subtitle)
    # Strip leading " - " prefix
    text = subtitle.sub(/^\s*-\s*/, '')
    # DR format: [Room Title] (RoomNum) — strip brackets, keep room number
    # GS format: [Room Title]          — strip brackets
    text.sub(/^\[(.+?)\]/, '\1').strip
  end

  # Evaluate a layout dimension string to an integer, substituting
  # Curses terminal dimensions for the tokens "lines" and "cols".
  #
  # @param str [String] dimension expression (e.g. "lines-2", "cols/3")
  # @return [Integer] computed dimension value
  # @api private
  def fix_layout_number(str)
    str = str.gsub('lines', Curses.lines.to_s).gsub('cols', Curses.cols.to_s)
    safe_eval_arithmetic(str)
  end

  # Append a speech timestamp to text (e.g., "Hello (3:45:12)").
  #
  # @param text [String] the text to append to
  # @return [String] text with appended timestamp
  # @api private
  def append_speech_timestamp(text)
    "#{text} (#{Time.now.strftime('%H:%M:%S').sub(/^0/, '')})"
  end

  # Emit a prompt to the main stream if one is pending and the last
  # line was not a movement command. Consumes the pending flag either way.
  #
  # @return [void]
  # @api private
  def emit_prompt_if_needed
    return unless @state.need_prompt

    @state.need_prompt = false
    @event_bus.emit(:add_prompt, stream: MAIN_STREAM, text: @state.prompt_text) unless @last_was_movement
  end

  # Set the stun countdown timer end time via the event bus.
  #
  # @param seconds [Integer, Float] duration of the stun in seconds
  # @return [void]
  # @api private
  def new_stun(seconds)
    @event_bus.emit(:stun, seconds: seconds)
    @need_update = true
  end

  # Process a line from the game server by tokenizing it into text and
  # tag segments, dispatching each tag to its handler, and flushing the
  # accumulated text through handle_game_text.
  #
  # Replaces the original mutating regex-and-slice while loop. Entity
  # unescaping happens per text segment before it enters the buffer,
  # so color positions are always relative to the final unescaped text.
  #
  # @param line [String] raw game server line
  # @return [void]
  # @api private
  def process_line_tags(line)
    segments = XmlTokenizer.tokenize(line)
    text_buffer = String.new

    segments.each do |type, content|
      case type
      when :text
        text_buffer << unescape_entities(content)
      when :tag
        dispatch_tag(content, text_buffer)
      end
    end

    handle_game_text(text_buffer)
  end

  # Process a chunk of game text after XML tags have been stripped.
  #
  # Captures room data (title, description, objects, players, exits)
  # for RoomWindow, matches notification patterns for the familiar
  # stream, detects stun/movement/health text, applies color presets
  # and highlight patterns, and routes the final text to the
  # appropriate window (stream, main, or dedicated handler).
  #
  # @param text [String] game text with XML tags already removed and
  #   entities already unescaped
  # @return [void]
  # @api private
  def handle_game_text(text)
    # Room data capture for RoomWindow.
    # Always capture for the room window; only suppress from the story window
    # when --room-window-only is active.
    room_captured = process_room_data(text, @line_colors)
    return if room_captured && @state.room_window_only

    check_familiar_notification(text)

    if text =~ /^\[.*?\]>/
      @state.need_prompt = false
    elsif (match = text.match(/^\s*You are stunned for (?<rounds>[0-9]+) rounds?/))
      new_stun(match[:rounds].to_i * 5)
    elsif text =~ Games::DragonRealms::RAISE_DEAD_PATTERN
      # Raise Dead stun (cleric spell — all deity-specific messaging variants)
      new_stun(30.6)
    elsif text =~ Games::DragonRealms::SHADOW_VALLEY_PATTERN
      # Shadow Valley exit stun
      new_stun(16.2)
    elsif text =~ /^You glance down at your empty hands\./
      @event_bus.emit(:indicator_update, id: 'right', label: 'Empty')
      @event_bus.emit(:indicator_update, id: 'left', label: 'Empty')
      @need_update = true
    else
      if text =~ /^You have.*? very difficult time with muscle control/
        @event_bus.emit(:indicator_update, id: 'nsys', value: 3)
        @need_update = true
      elsif text =~ /^You have.*? constant muscle spasms/
        @event_bus.emit(:indicator_update, id: 'nsys', value: 2)
        @need_update = true
      elsif text =~ /^You have.*? developed slurred speech/
        @event_bus.emit(:indicator_update, id: 'nsys', value: 1)
        @need_update = true
      end
    end

    if @open_style
      h = @open_style.dup
      h[:end] = text.length
      @line_colors.push(h)
      @open_style[:start] = 0
    end
    @open_color.each do |oc|
      ocd = oc.dup
      ocd[:end] = text.length
      @line_colors.push(ocd)
      oc[:start] = 0
    end

    # Apply highlight patterns to all routable streams
    if @current_stream.nil? || @wm.stream[@current_stream] || @current_stream =~ /^(?:death|logons|thoughts|voln|familiar|assess|ooc|shopWindow|combat|moonWindow|atmospherics)$/
      HighlightProcessor.apply_highlights(text, @line_colors)
    end

    unless text.strip.empty?
      if @current_stream

        if @current_stream == 'combat' && text.match(GagPatterns.combat_regexp)
          return
        end

        if @current_stream == 'thoughts' && (text =~ /^\[.+?\]-[A-z]+:[A-Z][a-z]+: "|^\[server\]: /)
          @current_stream = 'lnet'
        end

        # Handle room components for dedicated RoomWindow
        room_result = process_room_stream(text)
        if room_result == :consumed
          return
        elsif room_result == :continue
          # Room players: also update the indicator, then stop
          update_room_players_indicator(text, @line_colors)
          return
        end

        if (@wm.stream[@current_stream])
          if @current_stream == 'death'
            if (death_match = text.match(Games::DragonRealms::DEATH_PATTERN))
              # DR death: "Name" or "Name MF" (moonfire phoenix)
              name = death_match[:name]
              timestamp = Time.now.strftime('%H:%M')
              text = if text.match?(/A fiery phoenix soars into the heavens as/)
                       "#{timestamp} #{name} MF"
                     else
                       "#{timestamp} #{name}"
                     end
              @line_colors = HighlightProcessor.apply_highlights(text, [])
              @line_colors.push({ start: 0, end: 5, fg: 'ff0000' })
            elsif (gs_match = text.match(Games::GemStone::DEATH_PATTERN))
              # GS death: "Name AREA HH:MM" with area code consolidation
              name = gs_match[:name]
              area = Games::GemStone.resolve_death_area(gs_match[:area])
              timestamp = Time.now.strftime('%H:%M')
              text = "#{timestamp} #{name} #{area}"
              @line_colors = HighlightProcessor.apply_highlights(text, [])
              @line_colors.push({ start: 0, end: 5, fg: 'ff0000' })
            elsif text.match?(Games::GemStone::DEATH_SUPPRESS_PATTERN)
              # GS vaporized/incinerated — suppress
              text = ''
            end
          elsif @current_stream == 'logons'
            if (logon_match = text.match(LOGON_REGEXP))
              name = logon_match[:name]
              logon_type = logon_match[:type]
              timestamp = Time.now.strftime('%H:%M')
              text = "#{timestamp} #{name}"
              @line_colors = HighlightProcessor.apply_highlights(text, [])
              @line_colors.push({
                start: 0,
                end: 5,
                fg: ALL_LOGON_PATTERNS[logon_type]
              })
            end
          elsif @current_stream =~ /^(?:speech|thoughts|familiar)$/ && SPEECH_TS
            text = append_speech_timestamp(text)
          end

          if @current_stream == 'exp'
            @wm.stream['exp']
          elsif @current_stream == 'percWindow'
            @wm.stream['percWindow']

            # Apply configurable text transformations from XML
            # Example: <perc-transform pattern=" (roisaen|roisan)" replace=""/>
            PERC_TRANSFORMS.each do |pattern, replacement|
              text.sub!(pattern, replacement)
            end

            paren_pos = text.index('(')
            if paren_pos && paren_pos > 1
              spell_name = text[0..paren_pos - 2]
              # Shorten spell names
              text.sub!(/^#{Regexp.escape(spell_name)}/, abbreviate_spell(spell_name)) if Games::DragonRealms::SPELL_ABBREVIATIONS.include?(spell_name.strip)
            end

            text.gsub!(/  /, ' ')
            text.strip!

            # Apply highlight patterns to percWindow text
            HighlightProcessor.apply_highlights(text, @line_colors)

            if PRESET[@current_stream]
              @line_colors.push(start: 0, fg: PRESET[@current_stream][0], bg: PRESET[@current_stream][1],
                                end: text.length)
            end
          end
          unless text =~ /^\[server\]: "(?:kill|connect)/
            @event_bus.emit(:stream_text, stream: @current_stream, text: text, colors: @line_colors)
            @need_update = true
            # Track content sent to stream windows to prevent duplicate to main
            @last_stream_text = text.strip
          end
        elsif @current_stream =~ /^(?:death|logons|thoughts|voln|familiar|assess|ooc|shopWindow|combat|moonWindow|atmospherics)$/
          # Append timestamp to speech/thoughts/familiar when --speech-ts is active
          if @current_stream =~ /^(?:thoughts|familiar)$/ && SPEECH_TS
            text = append_speech_timestamp(text)
          end
          if PRESET[@current_stream]
            @line_colors.push(start: 0, fg: PRESET[@current_stream][0], bg: PRESET[@current_stream][1],
                              end: text.length)
          end
          unless text.empty?
            # Detect movement in stream content too
            @last_was_movement = true if text =~ MOVEMENT_PATTERN
            emit_prompt_if_needed
            @event_bus.emit(:stream_text, stream: MAIN_STREAM, text: text, colors: @line_colors)
            @need_update = true
          end
        end
      elsif @wm.stream[MAIN_STREAM]
        # Skip duplicate content that was already sent to a stream window
        if @last_stream_text && text.strip == @last_stream_text
          @last_stream_text = nil
        else
          # Detect movement messages to suppress following prompts/empty lines
          is_movement = text =~ MOVEMENT_PATTERN
          emit_prompt_if_needed

          # Strip leading whitespace from room-captured text (e.g., "  You also see..."
          # left after description extraction from the same server line)
          if room_captured
            styled = StyledText.new(text, @line_colors).lstrip
            text = styled.text
            @line_colors = styled.runs
          end
          @event_bus.emit(:stream_text, stream: MAIN_STREAM, text: text, colors: @line_colors, indent: room_captured ? false : nil)
          @need_update = true
          @last_was_movement = true if is_movement
        end
      end
    end
    @line_colors = []
    @open_monsterbold.clear
    @open_preset.clear
    @open_color.clear
    @open_link.clear
  end
end
