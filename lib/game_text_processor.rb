# frozen_string_literal: true

require_relative 'games'
require_relative 'room_assembler'
require_relative 'familiar_notifier'
require_relative 'xml_tokenizer'
require_relative 'tag_handlers'
require_relative 'event_bus'
require_relative 'streams'
require_relative 'presets'
require_relative 'boot_profiler'
require_relative 'clock'
require_relative 'pending_render'
require_relative 'server_reader'
require_relative 'line_filter'
require_relative 'prompt_tracker'
require_relative 'stream_router'

# Processes game server output in a dedicated thread: parses each line's
# markup and hands its text to the collaborators that route and assemble it.

# Parses the game text received from the server read thread and wires the
# pieces of the pipeline together:
#
# - {ServerReader} reads the socket, guards each line and flushes the
#   screen when no more data is waiting; this class is its line handler.
# - {LineFilter} drops gagged lines (keeping their stream tags) and runs
#   of blank lines.
# - The markup parse stays here: bold carry-over across lines, the
#   tokenize-and-dispatch tag parser ({TagHandlers}: colors, bold, presets,
#   links, indicators, progress bars, countdowns), and the game-text checks
#   (familiar notifications, stun, the hands glance, nerve damage).
# - {StreamRouter} owns the current stream and the pushStream stack, and
#   routes each chunk of text to its window or to main.
# - {RoomAssembler} assembles the room window's data from both room
#   pipelines.
# - {PromptTracker} decides when the prompt shows (movement suppression)
#   and drops the game's main copy of stream text.
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
  include FamiliarNotifier
  include TagHandlers

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
  # @param clock [Clock] read for timestamps (see StreamRouter) and the
  #   server time offset (see PromptTracker#prompt_tag)
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
    @game_rules = game_rules

    # Screen updates asked for while parsing; the reader flushes them.
    @pending_render = PendingRender.new
    @reader = ServerReader.new(line_handler: self, pending_render: @pending_render, event_bus: event_bus,
                               cmd_buffer: cmd_buffer, shared_state: shared_state, boot_profiler: boot_profiler)
    @line_filter = LineFilter.new(shared_state: shared_state)
    @prompts = PromptTracker.new(shared_state: shared_state, event_bus: event_bus, pending_render: @pending_render,
                                 window_mgr: window_mgr, clock: clock, boot_profiler: boot_profiler)
    @room = RoomAssembler.new(window_mgr: window_mgr, event_bus: event_bus, pending_render: @pending_render,
                              shared_state: shared_state)
    @router = StreamRouter.new(window_mgr: window_mgr, event_bus: event_bus, pending_render: @pending_render,
                               prompts: @prompts, room: @room, game_rules: game_rules, clock: clock,
                               speech_timestamps: speech_timestamps)

    # Line color/style tracking
    @line_colors = []
    @open_monsterbold = []
    @open_preset = []
    @open_style = nil
    @open_color = []
    @open_link = []

    # Whether the last line left bold open (see #carry_bold)
    @bold_next_line = false
  end

  # Main processing loop: reads lines from the game server socket until
  # the connection ends, processing each (see {ServerReader#run}).
  #
  # @param server [IO] TCP socket (or socket-like) connected to the game server
  # @return [Symbol] +:disconnected+ or +:crashed+ (see {ServerReader#run})
  def run(server)
    @prompts.server = server
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
      @prompts.blank_line if @router.current_stream.nil?
    else
      @room.line_started(line.dup)
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
  ensure
    # A bold, preset or color span still open at the end of the line
    # colors nothing more.
    @open_monsterbold.clear
    @open_preset.clear
    @open_color.clear
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
    # A style or color still open colors this text to its end and, when
    # this is a mid-line flush, continues from the start of the text that
    # follows (see TagHandlers#flush_text_buffer). Done first, so this holds
    # for text captured for the room window only.
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

    # Room data capture for RoomWindow.
    # Always capture for the room window; only suppress from the story window
    # when --room-window-only is active.
    room_captured = @room.process_room_data(text, @router.current_stream)
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

    @router.route(text, @line_colors, room_captured: room_captured)
  ensure
    @line_colors = []
    # Links aren't carried over a flush: one without a cmd attribute takes
    # its command from its text, which the flush would cut.
    @open_link.clear
  end
end
