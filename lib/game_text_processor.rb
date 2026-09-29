# frozen_string_literal: true

require_relative 'games'
require_relative 'room_data_processor'
require_relative 'familiar_notifier'
require_relative 'xml_tokenizer'
require_relative 'tag_handlers'
require_relative 'styled_text'
require_relative 'event_bus'
require_relative 'streams'
require_relative 'presets'
require_relative 'boot_profiler'
require_relative 'clock'
require_relative 'pending_render'
require_relative 'server_reader'
require_relative 'line_filter'

# Processes game server output in a dedicated thread, handling XML tag parsing,
# stream routing, room data assembly, spell abbreviation, and UI updates.

# Processes all game text received from the server read thread.
#
# {ServerReader} reads the socket and flushes the screen; this class is its
# line handler, and covers the rest of the pipeline from raw server output
# to UI events:
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
  include RoomDataProcessor
  include FamiliarNotifier
  include TagHandlers

  # Movement verbs that suppress the following prompt and empty line.
  MOVEMENT_PATTERN = /^You (?:run|walk|go|swim|climb|crawl|drag|stride|sneak|stalk)\b/

  # Element names of the bold tags. The last of them on a line tells
  # whether the line leaves bold open (see #carry_bold).
  BOLD_TAGS = %w[pushBold popBold].freeze

  # Create a new processor wired to the given window manager and shared state.
  #
  # @param window_mgr [WindowManager] provides handler hashes for stream/indicator/progress/countdown/room windows
  # @param shared_state [OpenStruct] mutable state shared with the input thread (need_prompt, prompt_text, skip_server_time_offset)
  # @param cmd_buffer [CommandBuffer] the command-line input buffer (its window is refreshed with each screen flush)
  # @param xml_escapes [Hash<String, String>] XML entity to character mappings (e.g. +"&gt;"+ => +">"+)
  # @param event_bus [EventBus] event bus for decoupled UI updates
  # @param boot_profiler [BootProfiler] logs when the first server data,
  #   prompt and screen render arrive (--profile)
  # @param speech_timestamps [Boolean] timestamp the lines of the streams in
  #   {Streams::TIMESTAMPED_IN_WINDOW} and {Streams::TIMESTAMPED_IN_MAIN}
  #   (--speech-ts)
  # @param clock [Clock] read for timestamps and the server time offset (see TagHandlers#handle_prompt_tag)
  # @param game_rules [Games::Rules] the game's death, logon, stun and
  #   spell-name rules (--game, see Games.rules_for); both games' when the
  #   game isn't known
  def initialize(window_mgr:, shared_state:, cmd_buffer:, xml_escapes:, event_bus:,
                 boot_profiler: BootProfiler.new(enabled: false), speech_timestamps: false, clock: Clock.new,
                 game_rules: Games::BOTH_GAMES)
    @wm = window_mgr
    @state = shared_state
    @xml_escapes = xml_escapes
    @event_bus = event_bus
    @boot_profiler = boot_profiler
    @speech_timestamps = speech_timestamps
    @clock = clock
    @game_rules = game_rules

    # Screen updates asked for while parsing; the reader flushes them.
    @pending_render = PendingRender.new
    @reader = ServerReader.new(line_handler: self, pending_render: @pending_render, event_bus: event_bus,
                               cmd_buffer: cmd_buffer, shared_state: shared_state, boot_profiler: boot_profiler)
    @line_filter = LineFilter.new(shared_state: shared_state)

    # Line color/style tracking
    @line_colors = []
    @open_monsterbold = []
    @open_preset = []
    @open_style = nil
    @open_color = []
    @open_link = []

    # Stream and display state
    @current_stream = nil
    # Open pushStreams, innermost last; a pop returns to the one below
    # (see TagHandlers#handle_stream_close). Cleared at every <prompt>.
    @stream_stack = []
    @bold_next_line = false
    @combat_next_line = nil
    @first_prompt = true

    # The last line sent to a stream window, stripped. The game sends some
    # stream text again as the next main line (DR whispers); that copy is
    # dropped. Only the next main-bound line is compared, and it uses the
    # text up whether or not it matched; a <prompt> also clears it.
    @last_stream_text = nil

    # Track movement messages to suppress prompts/empty lines after them
    @last_was_movement = false

    # Room data tracking for RoomWindow
    @room_capture_mode = nil # :title, :desc, or nil
    @room_pending_title = nil
    @room_pending_desc = nil
    @room_pending_objects = nil
    @room_pending_players = nil
    @room_pending_exits = nil
    @room_pending_number = nil
    @current_raw_line = nil # Raw line with XML tags preserved for room object extraction
  end

  # Main processing loop: reads lines from the game server socket until
  # the connection ends, processing each (see {ServerReader#run}).
  #
  # @param server [IO] TCP socket (or socket-like) connected to the game server
  # @return [Symbol] +:disconnected+ or +:crashed+ (see {ServerReader#run})
  def run(server)
    @server = server
    @reader.run(server)
  end

  # Show the "Connection closed / Press any key to exit" notice in the
  # main window and flush it to the screen.
  #
  # @return [void]
  def show_disconnect_message
    @reader.show_disconnect_message
  end

  # First step for one server line, before the render lock is taken:
  # bold carry-over, then gags and blank-line collapsing ({LineFilter}).
  # See {ServerReader}.
  #
  # @param line [String] raw server line, UTF-8, line ending removed
  # @return [String, nil] the line to process, or nil to drop it
  def prepare_line(line)
    @line_filter.filter(carry_bold(line))
  end

  # Second step for one server line, inside the render lock: a blank line
  # shows a pending prompt; any other line is parsed and routed.
  #
  # @param line [String] a line returned by {#prepare_line}
  # @return [void]
  def process_line(line)
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

        # Blank lines from the game are not displayed; a blank line is
        # where a pending prompt is shown, except after movement (use
        # flag OR buffer check), where the prompt is skipped too. The
        # pending flag is consumed either way.
        pending = @state.consume_prompt!
        if @last_was_movement || last_line_was_movement
          @last_was_movement = false
        elsif pending
          @event_bus.emit(:add_prompt, stream: MAIN_STREAM, text: @state.prompt_text)
          @pending_render.request_update
        end
      end
    else
      @current_raw_line = line.dup
      process_line_tags(line)
    end
  end

  private

  # Carry bold across line ends. The game can open bold on one line and
  # close it on a later one, but the tag parser drops any bold region still
  # open at the end of a line (it colors nothing). So a line that leaves
  # bold open gets a closing <popBold/>, and each following line gets an
  # opening <pushBold/>, until a line closes bold. Whichever bold tag comes
  # last on the line decides whether it leaves bold open. A prompt ends
  # carried bold, as it ends an open stream.
  #
  # Runs before gags, so a gagged line still opens or closes bold. A blank
  # line is left blank (it is where a pending prompt shows).
  #
  # @param line [String] server line, line ending removed
  # @return [String] the line with carried bold made explicit
  # @api private
  def carry_bold(line)
    return line if line.empty?

    # Carried bold closed at the very start of the line colors nothing.
    line = "<pushBold/>#{line}" if @bold_next_line && !line.start_with?('<popBold/>')
    names = start_tag_names(line)
    open = names.reverse_each.find { |name| BOLD_TAGS.include?(name) } == 'pushBold'
    line = "#{line}<popBold/>" if open
    @bold_next_line = open && !names.include?('prompt')
    line
  end

  # The element names of a raw line's start tags, in order, as the tag
  # dispatcher reads the line (nil for an end tag or a nameless one).
  #
  # @param line [String] raw server line
  # @return [Array<String, nil>] one name per tag
  # @api private
  def start_tag_names(line)
    XmlTokenizer.tags(line).map { |tag| XmlTokenizer.start_tag_name(tag) }
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

  # Append a speech timestamp to text (e.g., "Hello (3:45:12)").
  #
  # @param text [String] the text to append to
  # @return [String] text with appended timestamp
  # @api private
  def append_speech_timestamp(text)
    "#{text} (#{@clock.h_mm_ss})"
  end

  # A death or logon line: +rest+ after the current time (HH:MM), with the
  # line's highlights and the time drawn in +fg+. Replaces @line_colors.
  #
  # @param rest [String] the text after the time, e.g. the character's name
  # @param fg [String] hex foreground color of the time
  # @return [String] the line, e.g. "14:35 Mahtra"
  # @api private
  def time_prefixed(rest, fg)
    timestamp = @clock.hh_mm
    text = "#{timestamp} #{rest}"
    @line_colors = HighlightProcessor.apply_highlights(text, [])
    @line_colors.push({ start: 0, end: timestamp.length, fg: fg })
    text
  end

  # Emit a prompt to the main stream if one is pending and the last
  # line was not a movement command. Consumes the pending flag either way.
  #
  # @return [void]
  # @api private
  def emit_prompt_if_needed
    return unless @state.consume_prompt!

    @event_bus.emit(:add_prompt, stream: MAIN_STREAM, text: @state.prompt_text) unless @last_was_movement
  end

  # Set the stun countdown timer end time via the event bus.
  #
  # @param seconds [Integer, Float] duration of the stun in seconds
  # @return [void]
  # @api private
  def new_stun(seconds)
    @event_bus.emit(:stun, seconds: seconds)
    @pending_render.request_update
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
    room_captured = process_room_data(text)
    return if room_captured && @state.room_window_only

    check_familiar_notification(text)

    if text =~ /^\[.*?\]>/
      @state.need_prompt = false
    elsif (match = text.match(/^\s*You are stunned for (?<rounds>[0-9]+) rounds?/))
      new_stun(match[:rounds].to_i * 5)
    elsif (seconds = @game_rules.stun_seconds(text))
      # A game's own stun messages (DR: Raise Dead, the Shadow Valley exit)
      new_stun(seconds)
    elsif text =~ /^You glance down at your empty hands\./
      @event_bus.emit(:indicator_update, id: 'right', label: 'Empty')
      @event_bus.emit(:indicator_update, id: 'left', label: 'Empty')
      @pending_render.request_update
    elsif text =~ /^You glance down to see .+ in your right hand and nothing in your left hand\./
      # DR sends a hand tag only when the hand's contents change, so a hand
      # empty since login has never had one; the glance is the only word
      # that it's empty. The held hand keeps the name from its tag.
      @event_bus.emit(:indicator_update, id: 'left', label: 'Empty', value: 0)
      @pending_render.request_update
    elsif text =~ /^You glance down to see (?!.* in your right hand ).+ in your left hand\./
      # Only the left hand holds something: the glance doesn't mention the
      # right hand at all ("You glance down to see <item> in your left hand.").
      @event_bus.emit(:indicator_update, id: 'right', label: 'Empty', value: 0)
      @pending_render.request_update
    else
      if text =~ /^You have.*? very difficult time with muscle control/
        @event_bus.emit(:indicator_update, id: 'nsys', value: 3)
        @pending_render.request_update
      elsif text =~ /^You have.*? constant muscle spasms/
        @event_bus.emit(:indicator_update, id: 'nsys', value: 2)
        @pending_render.request_update
      elsif text =~ /^You have.*? developed slurred speech/
        @event_bus.emit(:indicator_update, id: 'nsys', value: 1)
        @pending_render.request_update
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
    if @current_stream.nil? || @wm.stream[@current_stream] || Streams::FALLBACK_TO_MAIN.include?(@current_stream)
      HighlightProcessor.apply_highlights(text, @line_colors)
    end

    unless text.strip.empty?
      if @current_stream

        if @current_stream == Streams::COMBAT && text.match(GagPatterns.combat_regexp)
          return
        end

        # LNet chat arrives on the thoughts stream. Move it to the lnet window
        # only when the layout has one; otherwise it stays on thoughts, which
        # falls back to main when there is no thoughts window either.
        if @current_stream == Streams::THOUGHTS && @wm.stream[Streams::LNET] && (text =~ /^\[.+?\]-[A-Za-z]+:[A-Z][a-z]+: "|^\[server\]: /)
          @current_stream = Streams::LNET
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
          if @current_stream == Streams::DEATH
            # "HH:MM Name ..." (e.g. DR "Name MF", GS "Name AREA"); an
            # empty entry hides the line (GS vaporized/incinerated)
            if (entry = @game_rules.death_summary(text))
              text = entry.empty? ? '' : time_prefixed(entry, 'ff0000')
            end
          elsif @current_stream == Streams::LOGONS
            if (logon = @game_rules.logon(text))
              name, fg = logon
              text = time_prefixed(name, fg)
            end
          elsif Streams::TIMESTAMPED_IN_WINDOW.include?(@current_stream) && @speech_timestamps
            text = append_speech_timestamp(text)
          end

          if @current_stream == Streams::PERC
            # Shorten the line. The color runs already on it (tag colors and
            # the highlights applied above, on the text as sent) move with
            # the text they color, so a highlight on a full spell name
            # colors its abbreviation.
            styled = StyledText.new(text, @line_colors)

            # Apply configurable text transformations from XML
            # Example: <perc-transform pattern=" (roisaen|roisan)" replace=""/>
            PERC_TRANSFORMS.each do |pattern, replacement|
              styled = styled.sub(pattern, replacement)
            end

            paren_pos = styled.text.index('(')
            if paren_pos && paren_pos > 1
              spell_name = styled.text[0..paren_pos - 2]
              # Shorten spell names
              short_name = @game_rules.spell_abbreviation(spell_name)
              styled = styled.sub(/^#{Regexp.escape(spell_name)}/, short_name) if short_name
            end

            styled = styled.gsub(/  /, ' ').strip
            text = styled.text
            @line_colors = styled.runs

            # Highlights that match the shortened text (e.g. on "POM" or on a
            # transform's "Cyclic"); skip runs already carried over.
            HighlightProcessor.apply_highlights(text, []).each do |run|
              @line_colors.push(run) unless @line_colors.include?(run)
            end

            if (colors = Presets.colors(@current_stream))
              @line_colors.push(start: 0, **colors, end: text.length)
            end
          end
          unless text =~ /^\[server\]: "(?:kill|connect)/
            @event_bus.emit(:stream_text, stream: @current_stream, text: text, colors: @line_colors)
            @pending_render.request_update
            # Remembered so the game's main copy of it, if next, is dropped
            @last_stream_text = text.strip
          end
        elsif Streams::FALLBACK_TO_MAIN.include?(@current_stream)
          # Timestamp thoughts/familiar when --speech-ts is active (not speech:
          # see Streams::TIMESTAMPED_IN_MAIN)
          if Streams::TIMESTAMPED_IN_MAIN.include?(@current_stream) && @speech_timestamps
            text = append_speech_timestamp(text)
          end
          if (colors = Presets.colors(@current_stream))
            @line_colors.push(start: 0, **colors, end: text.length)
          end
          unless text.empty?
            # Detect movement in stream content too
            @last_was_movement = true if text =~ MOVEMENT_PATTERN
            emit_prompt_if_needed
            @event_bus.emit(:stream_text, stream: MAIN_STREAM, text: text, colors: @line_colors)
            @pending_render.request_update
            # Shown in main, so it is the next main-bound line: the stored
            # stream-window text expires. Not compared: this is stream text
            # itself, never the game's main copy of a stream line.
            @last_stream_text = nil
          end
        end
      elsif @wm.stream[MAIN_STREAM]
        # Drop the game's main copy of the line just sent to a stream window.
        # Only this next main-bound line is compared; the stored text is used
        # up either way, so a later main line with the same text still shows.
        duplicate = @last_stream_text && text.strip == @last_stream_text
        @last_stream_text = nil
        unless duplicate
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
          @pending_render.request_update
          @last_was_movement = true if is_movement
        end
      end
    end
  ensure
    @line_colors = []
    @open_monsterbold.clear
    @open_preset.clear
    @open_color.clear
    @open_link.clear
  end
end
