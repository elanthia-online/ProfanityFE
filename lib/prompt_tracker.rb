# frozen_string_literal: true

require_relative 'xml_tokenizer'
require_relative 'boot_profiler'
require_relative 'clock'

# Decides when the prompt is shown in the main window, and which main
# lines are the game's copies of stream text.
#
# Owns:
# - the <prompt> tag: the server time offset, the 'look' sent at the first
#   prompt, and showing a changed prompt;
# - showing a pending prompt at a blank line or before the next main line,
#   except right after a movement line (the movement flag and the backup
#   check of the main window's newest line);
# - the last line sent to a stream window, so the game's copy of it as the
#   next main line is dropped.
class PromptTracker
  # Movement verbs that suppress the following prompt and empty line.
  MOVEMENT_PATTERN = /^You (?:run|walk|go|swim|climb|crawl|drag|stride|sneak|stalk)\b/

  # The socket the 'look' is written to at the first prompt; set by
  # {GameTextProcessor#run} before any line is read.
  #
  # @return [IO, nil]
  attr_writer :server

  # @param shared_state [SharedState] holds the prompt text, whether a
  #   prompt is pending, and whether the server time offset is known
  # @param event_bus [EventBus] receives +:add_prompt+ and +:prompt_changed+
  # @param pending_render [PendingRender] asked for a flush when a prompt is shown
  # @param window_mgr [WindowManager] its main window is read by the
  #   movement backup check
  # @param clock [Clock] its server time offset is set at the first prompt
  # @param boot_profiler [BootProfiler] logs the first prompt (--profile)
  def initialize(shared_state:, event_bus:, pending_render:, window_mgr:, clock: Clock.new,
                 boot_profiler: BootProfiler.new(enabled: false))
    @state = shared_state
    @event_bus = event_bus
    @pending_render = pending_render
    @wm = window_mgr
    @clock = clock
    @boot_profiler = boot_profiler
    @server = nil
    @first_prompt = true

    # The last line sent to a stream window, stripped. The game sends some
    # stream text again as the next main line (DR whispers); that copy is
    # dropped. Only the next main-bound line is compared, and it uses the
    # text up whether or not it matched; a <prompt> also clears it.
    @last_stream_text = nil

    # Track movement messages to suppress prompts/empty lines after them
    @last_was_movement = false
  end

  # Handle a <prompt time='...'>text&gt;</prompt> paired tag.
  # Syncs server time offset and updates the prompt display.
  # Also forgets the last stream-window line, so a main line after the
  # prompt is not taken for the game's copy of it and dropped.
  #
  # @param xml [String] the whole paired tag
  # @return [void]
  def prompt_tag(xml)
    @last_stream_text = nil
    return unless (time = XmlTokenizer.attrs(xml)['time'])&.match?(/\A[0-9]+\z/)
    # The text must end with an escaped >, the only part decoded.
    return unless (text = XmlTokenizer.content(xml))&.end_with?('&gt;')

    unless @state.skip_server_time_offset
      @clock.server_time_offset = @clock.now.to_f - time.to_f
      @state.skip_server_time_offset = true
    end

    if @first_prompt
      @first_prompt = false
      # Sent once the render lock is released, so a full socket send
      # buffer cannot block drawing (see CursesRenderer.outside_lock).
      CursesRenderer.outside_lock do
        @server.puts 'look'
        @server.flush
      end
      @boot_profiler.log_elapsed('first prompt (sent look)')
    end

    new_prompt_text = "#{text.delete_suffix('&gt;')}>"
    return unless @state.update_prompt(new_prompt_text)

    @event_bus.emit(:add_prompt, stream: MAIN_STREAM, text: new_prompt_text)
    @event_bus.emit(:prompt_changed, text: new_prompt_text)
    @pending_render.request_update
  end

  # A blank line from the game in main-window context: show the pending
  # prompt, unless the last line was movement.
  #
  # Blank lines from the game are not displayed; a blank line is where a
  # pending prompt is shown, except after movement (the flag, or the
  # backup check of the main window's newest line), where the prompt is
  # skipped too. The pending flag is consumed either way.
  #
  # @return [void]
  def blank_line
    last_line_was_movement = main_window_ends_with_movement?
    pending = @state.consume_prompt!
    if @last_was_movement || last_line_was_movement
      @last_was_movement = false
    elsif pending
      @event_bus.emit(:add_prompt, stream: MAIN_STREAM, text: @state.prompt_text)
      @pending_render.request_update
    end
  end

  # Emit a prompt to the main stream if one is pending and the last
  # line was not a movement command. Consumes the pending flag either way.
  #
  # @return [void]
  def emit_prompt_if_needed
    return unless @state.consume_prompt!

    @event_bus.emit(:add_prompt, stream: MAIN_STREAM, text: @state.prompt_text) unless @last_was_movement
  end

  # @param text [String] a line of game text
  # @return [Boolean] whether it reports the character moving
  def movement?(text)
    text.match?(MOVEMENT_PATTERN)
  end

  # Record that a movement line was shown, so the next prompt is skipped.
  #
  # @return [void]
  def movement_seen
    @last_was_movement = true
  end

  # Remember a line sent to a stream window, so the game's copy of it, if
  # it is the next main-bound line, is dropped.
  #
  # @param text [String] the line as sent to the window
  # @return [void]
  def stream_text_sent(text)
    @last_stream_text = text.strip
  end

  # Forget the stream-window line: the next main-bound line was shown
  # without being compared (stream text that fell back to main).
  #
  # @return [void]
  def forget_stream_text
    @last_stream_text = nil
  end

  # Whether a main-bound line is the game's copy of the line just sent to
  # a stream window. Only this next main-bound line is compared; the
  # stored text is used up either way, so a later main line with the same
  # text still shows.
  #
  # @param text [String] the main-bound line
  # @return [Boolean]
  def stream_text_copy?(text)
    duplicate = @last_stream_text && text.strip == @last_stream_text
    @last_stream_text = nil
    duplicate ? true : false
  end

  private

  # The movement backup check: whether the newest non-blank line of the
  # main window (of any of its tabs, when it is tabbed) is a movement line.
  #
  # @return [Boolean, nil]
  # @api private
  def main_window_ends_with_movement?
    main_window = @wm.stream[MAIN_STREAM]
    if main_window.is_a?(TabbedTextWindow)
      # Check all tabs for recent movement (movement could be in main, combat, etc.)
      main_window.tabs.each_value do |tab_buffer|
        last_entry = tab_buffer.find { |entry| entry[0] && !entry[0].strip.empty? }
        return true if last_entry && last_entry[0] =~ MOVEMENT_PATTERN
      end
      false
    elsif main_window.respond_to?(:buffer) && !main_window.buffer.empty?
      last_entry = main_window.buffer.find { |entry| entry[0] && !entry[0].strip.empty? }
      last_entry && last_entry[0] =~ MOVEMENT_PATTERN
    else
      false
    end
  end
end
