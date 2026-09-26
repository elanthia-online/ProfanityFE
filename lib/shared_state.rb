# frozen_string_literal: true

# shared_state.rb: Thread-safe container for cross-thread state in ProfanityFE.

# Thread-safe container for state shared between the input thread,
# server read thread, and timer threads.
#
# Under MRI's GIL, single-variable assignment is atomic, but multi-step
# check-then-act patterns are not. This class serializes access to the
# cross-thread prompt/time-sync variables via a single mutex.
#
# @example
#   state = SharedState.new
#   state.prompt_text = 'H>'
#   state.need_prompt = true
#   state.consume_prompt!  # => true (was needed), now false
class SharedState
  # @return [String, nil] character name for terminal title (nil disables title updates)
  attr_accessor :char_name

  # @return [Boolean] whether terminal title updates are suppressed
  attr_accessor :no_status

  # @return [Boolean] whether room data is shown only in the room window (not echoed to story)
  attr_accessor :room_window_only

  # @return [Boolean] whether every gagged line is written to the log in full (--log-gags)
  attr_accessor :log_gags

  def initialize
    @mutex = Mutex.new
    @need_prompt = false
    @prompt_text = '>'
    @room_title = ''
    @skip_server_time_offset = false
    @blue_links = false
    @remote_url = false
    @char_name = nil
    @no_status = false
    @room_window_only = false
    @log_gags = false
    @server_time_offset = 0.0
    @last_title = nil
    @title_dirty = false
  end

  # @return [Float] seconds offset between local clock and server clock
  def server_time_offset
    @mutex.synchronize { @server_time_offset }
  end

  # Update the server time offset. Also writes through to the
  # +$server_time_offset+ global for backward compatibility with
  # CountdownWindow which reads it on every tick.
  #
  # @param val [Float] new time offset
  # @return [void]
  def server_time_offset=(val)
    @mutex.synchronize { @server_time_offset = val }
    $server_time_offset = val
  end

  # @return [Boolean] whether a prompt display is pending
  def need_prompt
    @mutex.synchronize { @need_prompt }
  end

  # @param val [Boolean] whether a prompt display is pending
  # @return [void]
  def need_prompt=(val)
    @mutex.synchronize { @need_prompt = val }
  end

  # @return [String] current prompt string (e.g., "H>", ">")
  def prompt_text
    @mutex.synchronize { @prompt_text }
  end

  # @param val [String] new prompt string
  # @return [void]
  def prompt_text=(val)
    @mutex.synchronize do
      @title_dirty = true if @prompt_text != val
      @prompt_text = val
    end
  end

  # @return [String] current room title (for terminal title display)
  def room_title
    @mutex.synchronize { @room_title }
  end

  # @param val [String] new room title
  # @return [void]
  def room_title=(val)
    @mutex.synchronize do
      @title_dirty = true if @room_title != val
      @room_title = val
    end
  end

  # @return [Boolean] whether to skip the next server time offset calculation
  def skip_server_time_offset
    @mutex.synchronize { @skip_server_time_offset }
  end

  # @param val [Boolean] whether to skip time offset
  # @return [void]
  def skip_server_time_offset=(val)
    @mutex.synchronize { @skip_server_time_offset = val }
  end

  # @return [Boolean] whether in-game link highlighting is enabled
  def blue_links
    @mutex.synchronize { @blue_links }
  end

  # @param val [Boolean] enable or disable link highlighting
  # @return [void]
  def blue_links=(val)
    @mutex.synchronize { @blue_links = val }
  end

  # @return [Boolean] whether LaunchURLs are displayed as text instead of opened in browser
  def remote_url
    @mutex.synchronize { @remote_url }
  end

  # @param val [Boolean]
  # @return [void]
  def remote_url=(val)
    @mutex.synchronize { @remote_url = val }
  end

  # Atomically check whether the prompt text changed and update state.
  # If the text changed, sets need_prompt to false and updates prompt_text.
  # If unchanged, sets need_prompt to true (a new prompt of the same text arrived).
  #
  # @param new_prompt_text [String] the incoming prompt text to compare
  # @return [Boolean] true if prompt text changed, false if same
  def update_prompt(new_prompt_text)
    @mutex.synchronize do
      if @prompt_text != new_prompt_text
        @need_prompt = false
        @prompt_text = new_prompt_text
        true
      else
        @need_prompt = true
        false
      end
    end
  end

  # Atomically consume the need_prompt flag.
  # Returns the old value and sets need_prompt to false.
  #
  # @return [Boolean] whether a prompt was pending before this call
  def consume_prompt!
    @mutex.synchronize do
      was = @need_prompt
      @need_prompt = false
      was
    end
  end

  # Update the terminal title and process name from current prompt and room.
  #
  # Builds "CharName [prompt:room]" from {#prompt_text} and {#room_title},
  # stripping the trailing ">" from the prompt. No-op when the title hasn't
  # changed since the last call (dedup, matching EO behavior).
  #
  # Sets the terminal tab/window title via an OSC 0 escape sequence
  # written by a forked +printf+ subprocess (matching EO's approach).
  # This avoids interleaving with curses' stdout buffer.  The
  # screen/tmux +\\ek+ escape is only emitted when +$TERM+ indicates
  # a screen/tmux session.
  #
  # @return [void]
  def update_terminal_title
    return if @char_name.nil? || @no_status
    return unless @title_dirty

    prompt = @mutex.synchronize { @prompt_text.to_s.delete('>').strip }
    room   = @mutex.synchronize { @room_title.to_s.strip }
    parts  = [prompt, room].reject(&:empty?).join(':')
    title  = parts.empty? ? @char_name : "#{@char_name} [#{parts}]"

    return if title == @last_title

    Process.setproctitle(title)
    # Set the terminal tab/window title via OSC 0 escape sequence.
    # Uses system() to fork a subprocess (matching EO's approach) so the
    # escape bytes are written independently from curses' stdout buffer —
    # no interleaving possible.  Array form of system() avoids shell
    # injection and bypasses the shell entirely.
    # Clear dirty/dedup state AFTER the system() calls so that a fork
    # failure leaves @title_dirty true for retry on the next prompt.
    system('printf', '\033]0;%s\007', title)
    if ENV['TERM']&.match?(/^screen|^tmux/)
      system('printf', '\ek%s\e\\', @char_name)
    end
    @title_dirty = false
    @last_title = title
  rescue StandardError
    # ignore title update failures (e.g. no controlling terminal)
  end
end
