# frozen_string_literal: true

require_relative 'dot_command'
require_relative 'streams'
require_relative 'feedback'
require_relative 'boot_profiler'
require_relative 'clock'
require_relative 'games'
require_relative 'server_connection'
require_relative 'key_action_registry'
require_relative 'macro_interpreter'
require_relative 'mouse_controller'

# Core application class for ProfanityFE.
#
# Owns all runtime state that was previously captured by closures in
# profanity.rb: the command buffer, window manager, shared state,
# key bindings, and the {ServerConnection}; mouse handling is in the
# {MouseController} and macros run in the {MacroInterpreter}.
#
# Converts closure-captured local variables to instance variables. The
# key actions are Procs by name (SettingsLoader requires this), built by
# {KeyActionRegistry}.
#
# @example
#   app = Application.new(cli_options, settings_file: '/home/user/.profanity/mahtra.xml',
#                                      host: '127.0.0.1', port: 8000)
#   app.run
class Application
  attr_reader :key_binding, :key_action, :cmd_buffer, :window_mgr,
              :shared_state, :mouse_scroll

  # @return [ServerConnection] the connection to the game server
  attr_reader :connection

  # The dot-commands, in the order {#execute_command} tries them (the first
  # match wins) and +.help+ lists them. Each handler runs with
  # +instance_exec+ on the Application.
  DOT_COMMANDS = [
    DotCommand.new(name: 'quit',
                   help: ['.quit              Exit Profanity immediately'],
                   handler: proc { exit }),
    DotCommand.new(name: 'key',
                   help: ['.key               Show raw keycode of next key press'],
                   handler: proc { handle_dot_key }),
    DotCommand.new(name: 'fixcolor',
                   help: ['.fixcolor          Reinitialize custom Curses colors'],
                   handler: proc { ColorManager.reinitialize_colors }),
    DotCommand.new(name: 'resync',
                   help: ['.resync            Reset server time offset for timers'],
                   handler: proc { @shared_state.skip_server_time_offset = false }),
    DotCommand.new(name: 'reload',
                   help: ['.reload            Hot-reload settings XML file'],
                   handler: proc { handle_dot_reload }),
    DotCommand.new(name: 'layout',
                   args: :required,
                   help: ['.layout <name>     Switch to a named window layout'],
                   handler: proc { |layout|
                     @window_mgr.load_layout(layout)
                     @cmd_buffer.window = @window_mgr.command_window
                     @key_action['resize'].call
                   }),
    DotCommand.new(name: 'resize',
                   help: ['.resize            Recalculate window sizes for terminal'],
                   handler: proc { @key_action['resize'].call }),
    DotCommand.new(name: 'tab',
                   args: :optional,
                   help: ['.tab               List tabs (active marked with *)',
                          '.tab <N|name>      Switch tab by number or name'],
                   handler: proc { |arg| handle_dot_tab(arg) }),
    DotCommand.new(name: 'arrow',
                   help: ['.arrow             Cycle arrow keys: history/page/line'],
                   handler: proc { handle_dot_arrow }),
    DotCommand.new(name: 'links',
                   help: ['.links             Toggle in-game link highlighting'],
                   handler: proc { handle_dot_links }),
    DotCommand.new(name: 'select',
                   help: ['.select            Toggle drag-to-select without links'],
                   handler: proc { handle_dot_select }),
    DotCommand.new(name: 'draghl',
                   help: ['.draghl            Toggle live highlight while dragging'],
                   handler: proc { handle_dot_draghl }),
    DotCommand.new(name: 'scrollcfg',
                   help: ['.scrollcfg         Configure mouse scroll wheel'],
                   handler: proc { @mouse_scroll.start_configuration }),
    DotCommand.new(name: 'unhighlight',
                   args: :required,
                   help: ['.unhighlight <text> Remove an inline highlight'],
                   handler: proc { |pattern| handle_dot_unhighlight(pattern) }),
    DotCommand.new(name: 'highlight',
                   args: :optional,
                   help: ['.highlight <text>   Add cyan highlight for text (session only)',
                          '.highlight          List active inline highlights'],
                   handler: proc { |pattern| handle_dot_highlight(pattern) }),
    DotCommand.new(name: 'help',
                   help: ['.help              Show this help'],
                   handler: proc { handle_dot_help })
  ].freeze

  # How long .key waits for a key press before giving up, in milliseconds.
  DOT_KEY_TIMEOUT_MS = 5000

  # Seconds "Press any key to exit..." waits for a key after the game
  # server disconnects before the client exits anyway.
  EXIT_KEY_TIMEOUT = 30

  # Seconds to wait for the TCP connection to the game server before giving
  # up (see {ServerConnection::CONNECT_TIMEOUT}).
  CONNECT_TIMEOUT = ServerConnection::CONNECT_TIMEOUT

  # Color of the highlights added with +.highlight+ (cyan).
  INLINE_HIGHLIGHT_COLOR = '00ffff'

  # Create a new application instance with the given CLI options.
  #
  # @param cli_options [Hash] parsed CLI options from OptionParser
  # @param settings_file [String] path of the settings XML, loaded at
  #   startup and by +.reload+
  # @param host [String] game server (Lich) host
  # @param port [Integer] game server (Lich) port
  # @param boot_profiler [BootProfiler] records startup timings (--profile);
  #   also passed to the {GameTextProcessor}
  # @param game_rules [Games::Rules] the game's rules for the
  #   {GameTextProcessor} (--game, see Games.rules_for)
  def initialize(cli_options, settings_file:, host:, port:, boot_profiler: BootProfiler.new(enabled: false),
                 game_rules: Games::BOTH_GAMES)
    @cli_options = cli_options
    @settings_file = settings_file
    @boot_profiler = boot_profiler
    @game_rules = game_rules
    @connection = ServerConnection.new(host: host, port: port)

    @xml_escapes = {
      '&lt;'   => '<',
      '&gt;'   => '>',
      '&quot;' => '"',
      '&apos;' => "'",
      '&amp;'  => '&'
    }

    @shared_state = SharedState.new
    @shared_state.char_name = cli_options[:char]&.capitalize || 'ProfanityFE'
    @shared_state.no_status = cli_options[:no_status]
    @shared_state.blue_links = cli_options[:links]
    @shared_state.remote_url = cli_options[:remote_url]
    @shared_state.room_window_only = cli_options[:room_window_only]
    @shared_state.log_gags = cli_options[:log_gags]
    @shared_state.update_terminal_title

    @cmd_buffer = CommandBuffer.new
    @clock = Clock.new
    @window_mgr = WindowManager.new(clock: @clock)
    @key_binding = {}
    @selection_enabled = false

    @key_action = KeyActionRegistry.new(cmd_buffer: @cmd_buffer, window_mgr: @window_mgr,
                                        key_binding: @key_binding,
                                        send_command: method(:send_command),
                                        send_history_command: method(:send_history_command)).actions
    @macro_interpreter = MacroInterpreter.new(cmd_buffer: @cmd_buffer, send_command: method(:send_command))

    @mouse_controller = MouseController.new(key_action: @key_action, window_mgr: @window_mgr,
                                            shared_state: @shared_state, cmd_buffer: @cmd_buffer,
                                            write_to_client: method(:write_to_client),
                                            send_to_server: @connection.method(:send_line),
                                            links: cli_options[:links])
    @mouse_scroll = @mouse_controller.mouse_scroll
    @boot_profiler.mark('Application.new')
  end

  # Load settings, connect to the game server, and run the input loop.
  # This is the main entry point -- blocks until the connection closes
  # or the user quits.
  #
  # @return [void] never returns normally; calls +exit+ on disconnect
  def run
    load_settings_and_layout
    @boot_profiler.mark('settings + layout')
    connect_server
    @boot_profiler.mark('connect_server')
    start_server_thread
    @boot_profiler.mark('server thread started')
    @boot_profiler.log_timings
    input_loop
  end

  # Execute a dot-command or forward to the game server.
  #
  # The first of {DOT_COMMANDS} that matches (see {DotCommand#match}) is
  # handled locally; everything else is forwarded to the server with a
  # leading '.' replaced by ';'. A dot-command matches case-insensitively,
  # at the start of the input and only as a whole word (its name followed by
  # whitespace or end of input), so Lich scripts such as .arrows or
  # .tabulate still reach the server, and a dot-command on a later line of
  # multi-line input (from a macro containing a newline) is not run.
  #
  # @param cmd [String] the command text to execute
  # @return [void]
  def execute_command(cmd)
    DOT_COMMANDS.each do |command|
      next unless (args = command.match(cmd))

      return instance_exec(*args, &command.handler)
    end
    @connection.send_line(cmd.sub(/^\./, ';'))
  end

  # Interpret and execute a macro string (see {MacroInterpreter}).
  #
  # Inserts characters into the command buffer while handling escape
  # sequences: \\ (literal backslash), \x (clear buffer), \r (send
  # command), \@ (literal @), \? (backfill cursor position). A bare @
  # marks the final cursor position. {SettingsLoader} binds macro keys to
  # this method.
  #
  # @param macro [String] the macro string to execute
  # @return [void]
  def do_macro(macro)
    @macro_interpreter.call(macro)
  end

  private

  # ---- Feedback helpers ----

  # Show feedback lines in the main window (see {Feedback.write}). With
  # no main window nothing is drawn, the command line is not redrawn and
  # the screen is not flushed. Takes no lock of its own: it runs inside
  # the render lock only if the caller holds it.
  #
  # @param lines [Array<String>] the lines, oldest first
  # @param fg [String] hex foreground color of the lines
  # @param banner [Boolean] frame the lines with {Feedback::BANNER} rows
  # @param refresh [Boolean] redraw the command line afterwards, which
  #   puts the cursor back on it
  # @param doupdate [Boolean] flush the screen afterwards with
  #   {CursesRenderer.doupdate}
  # @return [Boolean] whether there was a main window
  def write_to_client(*lines, fg: FEEDBACK_COLOR, banner: false, refresh: true, doupdate: true)
    return false unless Feedback.write(@window_mgr.stream[MAIN_STREAM], *lines, fg: fg, banner: banner)

    @cmd_buffer.refresh if refresh
    CursesRenderer.doupdate if doupdate
    true
  end

  # ---- Dot-command handlers ----

  def handle_dot_key
    return unless write_to_client(Feedback::BANNER, '* Waiting for key press...')

    ch = wait_for_key
    msg = if ch.nil?
            "* No key pressed within #{DOT_KEY_TIMEOUT_MS / 1000} seconds"
          else
            "* Detected keycode: #{ch}"
          end
    write_to_client(msg, Feedback::BANNER, refresh: false)
  end

  # Read one key from the command window, waiting up to DOT_KEY_TIMEOUT_MS.
  #
  # {#input_loop} keeps the window in nodelay mode, where a read returns nil
  # at once. This switches to a bounded wait for the one read, then puts
  # nodelay back even if the read raises. The caller holds the curses monitor,
  # so the server thread cannot draw during the wait; the bound keeps that
  # pause short if no key comes.
  #
  # @return [Integer, String, nil] the key read (see {#read_key}), or nil
  #   if none arrived
  def wait_for_key
    @cmd_buffer.window.timeout = DOT_KEY_TIMEOUT_MS
    read_key
  ensure
    @cmd_buffer.window.nodelay = true
  end

  # Read one key press from the command window.
  #
  # Reads with +get_char+ (wget_wch), not +getch+: getch hands back each
  # byte of a non-ASCII character such as "é" as a separate Integer, so the
  # character never reached the command line. Everything else keeps getch's
  # shape so key bindings match as before: a function key is its Integer
  # code, a control character (Enter, Tab, ESC, ctrl+letter, DEL) is its
  # Integer byte, and a typed character is a one-character UTF-8 String.
  #
  # A key the locale cannot decode (a non-ASCII key under the C locale)
  # raises RangeError in the curses binding; that key is dropped, as the
  # stray bytes from getch were.
  #
  # @return [Integer, String, nil] the key, or nil if none was read
  def read_key
    key = @cmd_buffer.window.get_char
    return key unless key.is_a?(String)
    return key.ord if key.ord < 0x20 || key.ord == 0x7F

    key.encode(Encoding::UTF_8)
  rescue RangeError, EncodingError
    nil
  end

  def handle_dot_tab(arg)
    if TabbedTextWindow.list.empty?
      write_to_client('* No tabbed windows configured', refresh: false)
    elsif arg.nil? || arg.empty?
      lines = TabbedTextWindow.list.map do |win|
        tabs_info = win.tabs.keys.each_with_index.map do |name, i|
          "#{i + 1}:#{name}#{name == win.active_tab ? '*' : ''}"
        end.join(' ')
        "* Tabs: #{tabs_info}"
      end
      write_to_client(*lines, refresh: false)
    elsif arg =~ /^\d+$/
      TabbedTextWindow.list.each { |w| w.switch_tab_by_index(arg.to_i) }
      CursesRenderer.doupdate
    else
      TabbedTextWindow.list.each { |w| w.switch_tab(arg) }
      CursesRenderer.doupdate
    end
  end

  def handle_dot_arrow
    @key_action['switch_arrow_mode'].call
    mode = if @key_binding[Curses::KEY_UP] == @key_action['previous_command']
             'history'
           elsif @key_binding[Curses::KEY_UP] == @key_action['scroll_current_window_up_page']
             'page scroll'
           else
             'line scroll'
           end
    write_to_client("* Arrow mode: #{mode}", refresh: false)
  end

  def handle_dot_links
    @shared_state.blue_links = !@shared_state.blue_links
    if @shared_state.blue_links
      @mouse_scroll.enable_click_events
    elsif !@selection_enabled
      # Keep mouse capture when .select is still on
      @mouse_scroll.disable_click_events
    end
    if (room_win = @window_mgr.room[Streams::ROOM])
      room_win.links_enabled = @shared_state.blue_links
      room_win.render
    end
    msg = if @shared_state.blue_links
            '* Links: ON (clickable links + drag-to-select; Shift+drag for native selection)'
          elsif @selection_enabled
            '* Links: OFF (drag-to-select still on via .select)'
          else
            '* Links: OFF (native terminal selection)'
          end
    write_to_client(msg, refresh: false)
  end

  def handle_dot_select
    @selection_enabled = !@selection_enabled
    if @selection_enabled || @shared_state.blue_links
      @mouse_scroll.enable_click_events
    else
      @mouse_scroll.disable_click_events
    end
    msg = if @selection_enabled
            '* Select: ON (drag-to-select; Shift+drag for native selection)'
          elsif @shared_state.blue_links
            '* Select: OFF (drag-to-select still on via .links)'
          else
            '* Select: OFF (native terminal selection)'
          end
    write_to_client(msg)
  end

  def handle_dot_draghl
    @mouse_scroll.drag_highlight = !@mouse_scroll.drag_highlight
    msg = if @mouse_scroll.drag_highlight
            '* Drag highlight: ON (highlight follows the pointer while dragging)'
          else
            '* Drag highlight: OFF (highlight appears when you release)'
          end
    write_to_client(msg)
  end

  # Reload the settings file. A file that fails to load changes nothing,
  # and a one-line error in the main window says why. Highlights added with
  # +.highlight+ are kept on top of the file's.
  #
  # @return [void]
  def handle_dot_reload
    error = SettingsLoader.load(@settings_file, @key_binding, @key_action, method(:do_macro),
                                reload: true, keep_highlights: @inline_highlights || {})
    write_to_client("* Reload failed, settings unchanged: #{settings_error_reason(error)}") if error
  end

  # Summarize a settings load error on one line: the first line of its
  # message, plus the line number for an XML parse error.
  #
  # @param error [StandardError] the error returned by SettingsLoader.load
  # @return [String] a one-line reason
  def settings_error_reason(error)
    reason = error.message.lines.first.to_s.strip
    reason = error.class.name if reason.empty?
    line = error.line if error.respond_to?(:line)
    line.is_a?(Integer) && line.positive? ? "#{reason} (line #{line})" : reason
  end

  # Add an inline highlight for literal, case-insensitive text, or list the
  # inline highlights when no text is given. Inline highlights are kept in
  # HIGHLIGHT and in +@inline_highlights+ (regex => colors), which
  # {#handle_dot_reload} keeps on top of the file's highlights.
  #
  # @param pattern [String, nil] the text to highlight, optionally in double quotes
  # @return [void]
  def handle_dot_highlight(pattern)
    return unless @window_mgr.stream[MAIN_STREAM]

    if pattern.nil? || pattern.empty?
      @inline_highlights ||= {}
      if @inline_highlights.empty?
        write_to_client('* No inline highlights active', refresh: false)
      else
        write_to_client(*@inline_highlights.keys.map { |regex| "*   #{regex.source}" },
                        fg: INLINE_HIGHLIGHT_COLOR, banner: true, refresh: false)
      end
      return
    end

    @inline_highlights ||= {}
    pattern = pattern.sub(/^"(.*)"$/, '\1')
    begin
      regex = Regexp.new(Regexp.escape(pattern), Regexp::IGNORECASE)
    rescue RegexpError => e
      write_to_client("* Invalid pattern: #{e.message}", refresh: false)
      return
    end

    colors = [INLINE_HIGHLIGHT_COLOR, nil, nil]
    SETTINGS_LOCK.synchronize do
      HIGHLIGHT[regex] = colors
    end
    @inline_highlights[regex] = colors

    write_to_client("* Highlight added: #{pattern}", fg: INLINE_HIGHLIGHT_COLOR, refresh: false)
  end

  def handle_dot_unhighlight(pattern)
    return unless @window_mgr.stream[MAIN_STREAM]

    @inline_highlights ||= {}
    pattern = pattern.sub(/^"(.*)"$/, '\1')
    target = @inline_highlights.keys.find { |r| r.source == Regexp.escape(pattern) }
    unless target
      write_to_client("* No inline highlight found for: #{pattern}", refresh: false)
      return
    end

    SETTINGS_LOCK.synchronize do
      HIGHLIGHT.delete(target)
    end
    @inline_highlights.delete(target)

    write_to_client("* Highlight removed: #{pattern}", refresh: false)
  end

  def handle_dot_help
    write_to_client(*DOT_COMMANDS.flat_map(&:help).map { |line| "*   #{line}" }, banner: true, refresh: false)
  end

  # ---- Command sending ----

  # Send the command line: clear it, echo it after the prompt in the main
  # window, add it to the history and run it (see {#execute_command}).
  # Bound to the +send_command+ key action and run by a macro's +\r+.
  #
  # @return [void]
  def send_command
    cmd = @cmd_buffer.clear_and_get
    @shared_state.need_prompt = false
    if (window = @window_mgr.stream[MAIN_STREAM])
      @window_mgr.add_prompt(window, @shared_state.prompt_text, cmd)
    end
    @cmd_buffer.refresh
    CursesRenderer.doupdate
    @cmd_buffer.add_to_history(cmd)
    execute_command(cmd)
  end

  # Resend a command from the history, echoing it first when there is a
  # main window. Bound to the +send_last_command+ (1) and
  # +send_second_last_command+ (2) key actions.
  #
  # Only lines that were sent are resent (see {CommandBuffer#recent_command}):
  # never an edit left in a recalled entry or a line saved by the down
  # arrow.
  #
  # @param index [Integer] 1 = the last command sent, 2 = the one before it
  # @return [void]
  def send_history_command(index)
    if (cmd = @cmd_buffer.recent_command(index))
      if (window = @window_mgr.stream[MAIN_STREAM])
        @window_mgr.add_prompt(window, @shared_state.prompt_text, cmd)
        @cmd_buffer.refresh
        CursesRenderer.doupdate
      end
      execute_command(cmd)
    end
  end

  # ---- Initialization ----

  # Load the settings file and build the default layout, exiting with an
  # error (and the reason the file failed to load, if it did) when there is
  # no layout or no command window.
  #
  # @return [void]
  def load_settings_and_layout
    error = SettingsLoader.load(@settings_file, @key_binding, @key_action, method(:do_macro))

    if LAYOUT.empty?
      if error
        fatal_error("ERROR: Could not load settings from #{@settings_file}.", settings_error_reason(error))
      else
        fatal_error("ERROR: No layouts found in #{@settings_file}.",
                    'The XML file may be malformed. Check for unclosed tags or encoding errors.')
      end
    end

    @window_mgr.load_layout('default')
    @cmd_buffer.window = @window_mgr.command_window
    @window_mgr.room[Streams::ROOM]&.links_enabled = @cli_options[:links]

    unless @cmd_buffer.window
      fatal_error("ERROR: Layout has no command window. Add <window class='command'/> to your layout.")
    end

    TextWindow.list.each { |w| w.maxy.times { w.add_string "\n".dup } }
  end

  # Connect to the game server (see {ServerConnection#connect}), forget the
  # server time offset of the last connection and start the time sync
  # thread. Exits with an error if the connection fails.
  #
  # @return [void]
  def connect_server
    @connection.connect

    @clock.server_time_offset = 0.0

    # Time sync thread
    Thread.new do
      sleep TIME_SYNC_DELAY
      @shared_state.skip_server_time_offset = false
    end
  rescue ServerConnection::ConnectError => e
    fatal_error(e.message, 'Is the game server running?')
  end

  # Print an error and exit with status 1, closing the curses screen first.
  #
  # Until +close_screen+, curses owns the terminal's alternate screen, which
  # is discarded when the program exits, so an error printed earlier is
  # never seen. The server thread is stopped first: a draw after
  # +close_screen+ would switch back to the alternate screen.
  #
  # @param lines [Array<String>] lines to print to stderr
  # @return [void] never returns
  def fatal_error(*lines)
    @connection.stop
    Curses.close_screen
    lines.each { |line| $stderr.puts line }
    exit 1
  end

  # Build the event bus and the {GameTextProcessor}, and start the server
  # thread that feeds the processor from the connection.
  #
  # @return [Thread] the server thread
  def start_server_thread
    @event_bus = EventBus.new
    @window_mgr.subscribe_to_events(@event_bus)
    # WindowManager resizes the command window when the prompt width
    # changes; re-fit the command line to the new width afterwards.
    @event_bus.on(:prompt_changed) { @cmd_buffer.redraw }

    @processor = GameTextProcessor.new(
      window_mgr: @window_mgr,
      shared_state: @shared_state,
      cmd_buffer: @cmd_buffer,
      xml_escapes: @xml_escapes,
      event_bus: @event_bus,
      boot_profiler: @boot_profiler,
      speech_timestamps: @cli_options[:speech_ts],
      clock: @clock,
      game_rules: @game_rules
    )
    # The server thread only reports how the connection ended; the input
    # loop picks that up and ends the session on the main thread.
    @connection.start_reader { |socket| @processor.run(socket) }
  end

  # End the session once the server thread reports that the connection is
  # over. Called from {#input_loop}, so it runs on the main thread: the
  # notice is drawn and the key read by the thread that owns the keyboard,
  # with no competing getch. Exits through SystemExit, so the input loop's
  # +ensure+ restores the terminal.
  #
  # @param outcome [Symbol] +:disconnected+ or +:crashed+, from
  #   {GameTextProcessor#run}
  # @return [void] never returns
  def end_session(outcome)
    unless outcome == :disconnected
      fatal_error('ProfanityFE stopped: error reading from the game server. See the log file for details.')
    end

    @processor.show_disconnect_message
    wait_for_exit_key
    exit 0
  end

  # Wait for a key press, at most +timeout+ seconds. Resizes and mouse
  # events are not key presses; they don't extend the wait. A read that
  # times out or fails (nil) ends the wait, so a lost terminal cannot spin
  # here and an unattended client still exits.
  #
  # @param timeout [Numeric] seconds to wait for a key
  # @return [void]
  def wait_for_exit_key(timeout: EXIT_KEY_TIMEOUT)
    window = @cmd_buffer.window
    deadline = monotonic_now + timeout
    loop do
      remaining = deadline - monotonic_now
      break unless remaining.positive?

      window.timeout = (remaining * 1000).ceil
      ch = window.getch
      break unless [Curses::KEY_RESIZE, Curses::KEY_MOUSE].include?(ch)
    end
  end

  # @return [Float] seconds on the monotonic clock
  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # ---- Input loop ----

  # Poll all countdown windows and flush if any changed.
  # Called on every input loop iteration (~100ms) to replace the
  # per-countdown Thread.new pattern.
  #
  # @return [Boolean] true if any countdown display changed
  def tick_countdowns
    any_updated = false
    @window_mgr.countdown.each_value do |window|
      any_updated = true if window.tick
    end
    @cmd_buffer.window&.noutrefresh if any_updated
    any_updated
  end

  def input_loop
    key_combo = nil
    @cmd_buffer.window.nodelay = true

    loop do
      IO.select([$stdin], nil, nil, 0.1)
      end_session(@connection.take_outcome) if @connection.ended?

      CursesRenderer.synchronize do
        # Tick countdowns on every iteration (~100ms), regardless of input
        countdown_updated = tick_countdowns
        # Drag held at a window edge keeps scrolling once per tick
        drag_scrolled = @mouse_controller.tick_drag_auto_scroll

        ch = read_key
        if ch.nil?
          Curses.doupdate if countdown_updated || drag_scrolled
          next
        end

        key_combo = handle_key(ch, key_combo)
      end # CursesRenderer.synchronize
    end
  rescue Interrupt
    # Ctrl+C: exit cleanly without dumping a backtrace. Interrupt is not a
    # StandardError, so it bypasses the rescue below; catch it explicitly and
    # let the ensure block below restore the terminal.
    nil
  rescue StandardError => e
    # Anything else (a key handler's own errors are rescued in handle_key)
    # ends the session like a server thread crash.
    ProfanityLog.write('main', e.to_s, backtrace: e.backtrace)
    fatal_error("ProfanityFE stopped: error in the input loop (#{e.class}: #{e.message}). See the log file for details.")
  ensure
    @connection.close
    Curses.close_screen
  end

  # Dispatch one key press: a mouse event, a step through a key combo, a
  # bound key action, or a character typed into the command line.
  #
  # A terminal resize (KEY_RESIZE) runs the +resize+ action unless the
  # settings file binds the resize key to something else, so the layout
  # follows the terminal without a binding in the file.
  #
  # An error raised by the action is logged and the key dropped, so one
  # broken key action or mouse handler cannot end the session. Connection
  # errors propagate to {#input_loop}, which ends it.
  #
  # @param ch [Integer, String] the key code or character from {#read_key}
  # @param key_combo [Hash, nil] the pending key-combo map from earlier keys
  # @return [Hash, nil] the key-combo map to use for the next key
  def handle_key(ch, key_combo)
    if ch == Curses::KEY_MOUSE
      @mouse_controller.handle_event
      return key_combo
    end

    # Checked before the combo so a pending combo (e.g. a lone Escape, which
    # starts the alt+N combos) doesn't swallow the resize.
    if ch == Curses::KEY_RESIZE && !@key_binding.key?(ch)
      @key_action['resize'].call
      return key_combo
    end

    if key_combo
      if key_combo[ch].instance_of?(Proc)
        key_combo[ch].call
        nil
      elsif key_combo[ch].instance_of?(Hash)
        key_combo[ch]
      end
    elsif @key_binding[ch].instance_of?(Proc)
      @key_binding[ch].call
      nil
    elsif @key_binding[ch].instance_of?(Hash)
      @key_binding[ch]
    elsif ch.instance_of?(String)
      @cmd_buffer.put_ch(ch)
      @cmd_buffer.refresh
      CursesRenderer.doupdate
      nil
    end
  rescue IOError, SystemCallError
    raise
  rescue StandardError => e
    ProfanityLog.write('main', "input handler failed: #{e.message}", backtrace: e.backtrace)
    nil
  end
end
