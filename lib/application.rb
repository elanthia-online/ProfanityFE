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

  # @!attribute [r] key_binding
  #   @return [Hash{Integer, String => Proc, Hash}] the key binding map:
  #     key code or character => key action Proc, or the combo map
  #     (the same shape) for a key that starts a key combo
  # @!attribute [r] key_action
  #   @return [Hash{String => Proc}] the key actions by name, from
  #     {KeyActionRegistry}
  # @!attribute [r] cmd_buffer
  #   @return [CommandBuffer] the command line
  # @!attribute [r] window_mgr
  #   @return [WindowManager] the windows of the current layout
  # @!attribute [r] shared_state
  #   @return [SharedState] the state shared with the server thread
  # @!attribute [r] mouse_scroll
  #   @return [MouseScroll] the mouse wheel and click capture, from the
  #     {MouseController}

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
                   handler: proc { |layout| apply_layout(layout) }),
    DotCommand.new(name: 'resize',
                   help: ['.resize            Re-fit windows now (automatic on resize)'],
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

  # Seconds each pass of {#input_loop} waits for a key before it ticks the
  # countdowns again.
  INPUT_POLL_SECONDS = 0.1

  # Seconds with no further terminal resize (KEY_RESIZE) after which
  # {#input_loop} re-fits the layout. A terminal drag sends a burst of
  # resizes; the layout (and the re-wrap of every text window's lines)
  # follows once, at the final size, when the burst stops. One input poll
  # long ({INPUT_POLL_SECONDS}), so a single resize is fitted one to two
  # polls (0.1-0.2 s) after the terminal changed size, and a burst with no
  # key typed in it is not fitted more often than once per poll.
  RESIZE_QUIET_SECONDS = INPUT_POLL_SECONDS

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
    @window_mgr = WindowManager.new(clock: @clock, shared_state: @shared_state)
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
  # @return [void] returns only when the user presses Ctrl+C; the session
  #   otherwise ends through +exit+ (+.quit+, a disconnect or a fatal error)
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

  # Show feedback lines in the main window (see {Feedback.write}), then
  # flush the screen with the cursor on the command line
  # ({CommandBuffer#flush_screen}). With no main window nothing is drawn
  # and the screen is not flushed. Takes no lock of its own: it runs inside
  # the render lock only if the caller holds it.
  #
  # @param lines [Array<String>] the lines, oldest first
  # @param fg [String] hex foreground color of the lines
  # @param banner [Boolean] frame the lines with {Feedback::BANNER} rows
  # @return [Boolean] whether there was a main window
  def write_to_client(*lines, fg: FEEDBACK_COLOR, banner: false)
    return false unless Feedback.write(@window_mgr.stream[MAIN_STREAM], *lines, fg: fg, banner: banner)

    @cmd_buffer.flush_screen
    true
  end

  # ---- Dot-command handlers ----

  # +.key+: wait for one key press (see {#wait_for_key}) and show its key
  # code in the main window, or say that none came. Does nothing without a
  # main window.
  #
  # @return [void]
  def handle_dot_key
    return unless write_to_client(Feedback::BANNER, '* Waiting for key press...')

    ch = wait_for_key
    msg = if ch.nil?
            "* No key pressed within #{DOT_KEY_TIMEOUT_MS / 1000} seconds"
          else
            "* Detected keycode: #{ch}"
          end
    write_to_client(msg, Feedback::BANNER)
  end

  # Read one key from the command window, waiting up to DOT_KEY_TIMEOUT_MS.
  #
  # {#input_loop} keeps the window in nodelay mode, where a read returns nil
  # at once. This switches to a bounded wait for the read, then puts
  # nodelay back even if the read raises. The caller holds the curses monitor,
  # so the server thread cannot draw during the wait; the bound keeps that
  # pause short if no key comes.
  #
  # A terminal resize (KEY_RESIZE) is not a key press: it makes the resize
  # pending, as in {#read_key_after_resizes}, for {#input_loop} to fit once
  # this returns, and the wait goes on for what is left of the
  # DOT_KEY_TIMEOUT_MS.
  #
  # @return [Integer, String, nil] the key read (see {#read_key}), or nil
  #   if none arrived
  def wait_for_key
    deadline = monotonic_now + (DOT_KEY_TIMEOUT_MS / 1000.0)
    remaining_ms = DOT_KEY_TIMEOUT_MS
    loop do
      @cmd_buffer.window.timeout = remaining_ms
      ch = read_key
      return ch unless ch == Curses::KEY_RESIZE

      @resize_due = monotonic_now + RESIZE_QUIET_SECONDS
      remaining_ms = ((deadline - monotonic_now) * 1000).ceil
      return nil unless remaining_ms.positive?
    end
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

  # +.tab+: with no argument, list each tabbed window's tabs as
  # +N:name+, the active one marked with +*+; with a number, switch every
  # tabbed window to its Nth tab (from 1); with anything else, switch every
  # tabbed window that has a tab of that name to it. A window without the
  # tab (or with fewer tabs) stays as it is. Says so when the layout has no
  # tabbed window.
  #
  # @param arg [String, nil] the tab number or name, or nil for the list
  # @return [void]
  def handle_dot_tab(arg)
    if TabbedTextWindow.list.empty?
      write_to_client('* No tabbed windows configured')
    elsif arg.nil? || arg.empty?
      lines = TabbedTextWindow.list.map do |win|
        tabs_info = win.tab_names.each_with_index.map do |name, i|
          "#{i + 1}:#{name}#{name == win.active_tab ? '*' : ''}"
        end.join(' ')
        "* Tabs: #{tabs_info}"
      end
      write_to_client(*lines)
    elsif arg =~ /^\d+$/
      TabbedTextWindow.list.each { |w| w.switch_tab_by_index(arg.to_i) }
      @cmd_buffer.flush_screen
    else
      TabbedTextWindow.list.each { |w| w.switch_tab(arg) }
      @cmd_buffer.flush_screen
    end
  end

  # +.arrow+: run the +switch_arrow_mode+ key action, which moves the up
  # and down arrows on to the next of command history, page scroll and
  # line scroll, then show the mode the up arrow is now bound to.
  #
  # @return [void]
  def handle_dot_arrow
    @key_action['switch_arrow_mode'].call
    mode = if @key_binding[Curses::KEY_UP] == @key_action['previous_command']
             'history'
           elsif @key_binding[Curses::KEY_UP] == @key_action['scroll_current_window_up_page']
             'page scroll'
           else
             'line scroll'
           end
    write_to_client("* Arrow mode: #{mode}")
  end

  # +.links+: turn clickable links on or off. Turning them on captures the
  # mouse; turning them off releases it unless +.select+ is on. Redraws the
  # room window, whose links follow the setting, and shows the new state.
  #
  # @return [void]
  def handle_dot_links
    @shared_state.blue_links = !@shared_state.blue_links
    if @shared_state.blue_links
      @mouse_scroll.enable_click_events
    elsif !@selection_enabled
      # Keep mouse capture when .select is still on
      @mouse_scroll.disable_click_events
    end
    # The room window reads the setting from the shared state; draw it again
    @window_mgr.room[Streams::ROOM]&.render
    msg = if @shared_state.blue_links
            '* Links: ON (clickable links + drag-to-select; Shift+drag for native selection)'
          elsif @selection_enabled
            '* Links: OFF (drag-to-select still on via .select)'
          else
            '* Links: OFF (native terminal selection)'
          end
    write_to_client(msg)
  end

  # +.select+: turn drag-to-select on or off without links. Captures the
  # mouse while either this or +.links+ is on and releases it when both
  # are off, then shows the new state.
  #
  # @return [void]
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

  # +.draghl+: toggle whether the selection highlight follows the pointer
  # while dragging (on) or appears only on release (off), and show the new
  # state.
  #
  # @return [void]
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
        write_to_client('* No inline highlights active')
      else
        write_to_client(*@inline_highlights.keys.map { |regex| "*   #{regex.source}" },
                        fg: INLINE_HIGHLIGHT_COLOR, banner: true)
      end
      return
    end

    @inline_highlights ||= {}
    pattern = pattern.sub(/^"(.*)"$/, '\1')
    begin
      regex = Regexp.new(Regexp.escape(pattern), Regexp::IGNORECASE)
    rescue RegexpError => e
      write_to_client("* Invalid pattern: #{e.message}")
      return
    end

    colors = [INLINE_HIGHLIGHT_COLOR, nil, nil]
    SETTINGS_LOCK.synchronize do
      HIGHLIGHT[regex] = colors
    end
    @inline_highlights[regex] = colors

    write_to_client("* Highlight added: #{pattern}", fg: INLINE_HIGHLIGHT_COLOR)
  end

  # +.unhighlight+: remove the inline highlight added by +.highlight+ for
  # the same text (optionally in double quotes), from HIGHLIGHT and
  # +@inline_highlights+, and say whether one was found. Does nothing
  # without a main window. Highlights from the settings file are not
  # touched.
  #
  # @param pattern [String] the text given to +.highlight+
  # @return [void]
  def handle_dot_unhighlight(pattern)
    return unless @window_mgr.stream[MAIN_STREAM]

    @inline_highlights ||= {}
    pattern = pattern.sub(/^"(.*)"$/, '\1')
    target = @inline_highlights.keys.find { |r| r.source == Regexp.escape(pattern) }
    unless target
      write_to_client("* No inline highlight found for: #{pattern}")
      return
    end

    SETTINGS_LOCK.synchronize do
      HIGHLIGHT.delete(target)
    end
    @inline_highlights.delete(target)

    write_to_client("* Highlight removed: #{pattern}")
  end

  # +.help+: show every dot-command's help lines, in {DOT_COMMANDS} order,
  # between banner rows in the main window.
  #
  # @return [void]
  def handle_dot_help
    write_to_client(*DOT_COMMANDS.flat_map(&:help).map { |line| "*   #{line}" }, banner: true)
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
    @cmd_buffer.flush_screen
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
        @cmd_buffer.flush_screen
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

    apply_layout('default')
    return if @cmd_buffer.window

    fatal_error("ERROR: Layout has no command window. Add <window class='command'/> to your layout.")
  end

  # Switch to a layout and show it: the one sequence for the default
  # layout at startup and for +.layout+. Builds the layout's windows
  # (reusing the previous layout's where it can, see
  # {WindowManager#load_layout}), moves the command line to the layout's
  # command window, fills each text window the layout added with blank
  # lines, so that its text starts on its bottom row, and fits every
  # window to the terminal. It flushes with {CommandBuffer#flush_screen},
  # so the cursor ends on the command line.
  #
  # @param layout_id [String] key into the global LAYOUT hash
  # @return [void]
  def apply_layout(layout_id)
    kept = TextWindow.list.dup
    @window_mgr.load_layout(layout_id)
    @cmd_buffer.window = @window_mgr.command_window
    TextWindow.list.each do |window|
      window.fill_with_blank_lines unless kept.any? { |old| old.equal?(window) }
    end
    @window_mgr.resize(@cmd_buffer)
    @cmd_buffer.flush_screen
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

  # Poll all countdown windows; the input loop flushes if any changed.
  # Called on every input loop iteration (~100ms) to replace the
  # per-countdown Thread.new pattern.
  #
  # @return [Boolean] true if any countdown display changed
  def tick_countdowns
    any_updated = false
    @window_mgr.countdown.each_value do |window|
      any_updated = true if window.tick
    end
    any_updated
  end

  # Read and dispatch keys until the session ends. Each pass waits up to
  # {INPUT_POLL_SECONDS} for input, ends the session (see {#end_session})
  # once the server thread reports the connection over, and then, holding
  # the render lock, ticks the countdown windows and the drag auto-scroll
  # and hands one key to {#handle_key}, then any keys curses already holds
  # (see {#handle_queued_keys}). Ctrl+C (Interrupt) returns quietly;
  # any other error is logged and ends the session through {#fatal_error}.
  # Either way the connection and the curses screen are closed on the way
  # out.
  #
  # Terminal resizes (KEY_RESIZE) are handled once per burst: every resize
  # already queued is read at once, and the resize key is handled when
  # {RESIZE_QUIET_SECONDS} pass with no further resize, or at once when
  # another key or mouse event comes first (before it, so input keeps its
  # order), or when the session ends.
  #
  # @return [nil] only after Ctrl+C; otherwise it leaves through +exit+
  def input_loop
    key_combo = nil
    @resize_due = nil
    @cmd_buffer.window.nodelay = true

    loop do
      IO.select([$stdin], nil, nil, input_poll_seconds)
      if @connection.ended?
        CursesRenderer.synchronize { handle_pending_resize(key_combo) } if @resize_due
        end_session(@connection.take_outcome)
      end

      CursesRenderer.synchronize do
        # Tick countdowns on every iteration (~100ms), regardless of input
        countdown_updated = tick_countdowns
        # Drag held at a window edge keeps scrolling once per tick
        drag_scrolled = @mouse_controller.tick_drag_auto_scroll

        ch, key_combo = handle_next_key(key_combo)
        if ch.nil?
          @cmd_buffer.flush_screen if countdown_updated || drag_scrolled
          next
        end

        key_combo = handle_queued_keys(key_combo)
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

  # How long this pass of {#input_loop} waits for a key: {INPUT_POLL_SECONDS},
  # or less when a pending terminal resize is due sooner.
  #
  # @return [Numeric] seconds, 0 when the resize is already due
  def input_poll_seconds
    return INPUT_POLL_SECONDS unless @resize_due

    (@resize_due - monotonic_now).clamp(0, INPUT_POLL_SECONDS)
  end

  # Read the next key (see {#read_key_after_resizes}) and hand it to
  # {#handle_key}, first handling the pending terminal resize if a key came
  # or the resize is due.
  #
  # @param key_combo [Hash, nil] the pending key-combo map
  # @return [Array] +[key, key_combo]+: the key handled (Integer or
  #   String), or nil when no key was waiting, and the key-combo map
  #   (Hash or nil) to use for the next key
  def handle_next_key(key_combo)
    ch, key_combo = read_key_after_resizes(key_combo)
    key_combo = handle_pending_resize(key_combo) if @resize_due && (ch || monotonic_now >= @resize_due)
    key_combo = handle_key(ch, key_combo) if ch
    [ch, key_combo]
  end

  # After a key has been handled, hand {#handle_key} each further key that
  # curses already holds, in order, until it holds none (see
  # {#handle_next_key}). Waiting on stdin first would cost a whole
  # {INPUT_POLL_SECONDS} for each such key: curses reads an alt+N's Escape
  # and digit together (to tell an alt key from a lone Escape) and keeps
  # the digit, so stdin has nothing left to wait for.
  #
  # Stops while stdin has input waiting, so keys still on stdin go one per
  # pass of {#input_loop}, as before (with the countdowns and the drag
  # auto-scroll ticked and the render lock released between them), and
  # once the server thread reports the connection over, so the session
  # ends before any later key is handled, as before.
  #
  # @param key_combo [Hash, nil] the pending key-combo map
  # @return [Hash, nil] the key-combo map to use for the next key
  def handle_queued_keys(key_combo)
    until @connection.ended? || IO.select([$stdin], nil, nil, 0)
      ch, key_combo = handle_next_key(key_combo)
      break if ch.nil?
    end
    key_combo
  end

  # Read the next key that is not a terminal resize (see {#read_key}).
  # Each KEY_RESIZE read on the way (a terminal drag queues several) makes
  # the resize pending, due {RESIZE_QUIET_SECONDS} from now. The exception
  # is a KEY_RESIZE read while a key combo is pending and the settings file
  # binds the resize key: it goes to {#handle_key} at once, where the combo
  # takes it (and ends), as every such KEY_RESIZE did before bursts were
  # coalesced; the resizes after it make the resize pending.
  #
  # @param key_combo [Hash, nil] the pending key-combo map
  # @return [Array] +[key, key_combo]+: the key (Integer or String), or nil
  #   when no other key is waiting, and the key-combo map (Hash or nil) to
  #   use for it
  def read_key_after_resizes(key_combo)
    loop do
      ch = read_key
      return [ch, key_combo] unless ch == Curses::KEY_RESIZE

      if key_combo && @key_binding.key?(ch)
        key_combo = handle_key(ch, key_combo)
      else
        @resize_due = monotonic_now + RESIZE_QUIET_SECONDS
      end
    end
  end

  # Handle the pending terminal resize once: the resize key goes to
  # {#handle_key}, which fits the layout to the terminal's current size (or
  # runs the settings file's binding for the key).
  #
  # @param key_combo [Hash, nil] the pending key-combo map
  # @return [Hash, nil] the key-combo map to use for the next key
  def handle_pending_resize(key_combo)
    @resize_due = nil
    handle_key(Curses::KEY_RESIZE, key_combo)
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
  # @raise [IOError, SystemCallError] a connection error raised by the
  #   action, passed on so that {#input_loop} ends the session
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
      @cmd_buffer.flush_screen
      nil
    end
  rescue IOError, SystemCallError
    raise
  rescue StandardError => e
    ProfanityLog.write('main', "input handler failed: #{e.message}", backtrace: e.backtrace)
    nil
  end
end
