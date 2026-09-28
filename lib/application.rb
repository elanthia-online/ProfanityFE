# frozen_string_literal: true

# Default BOOT_PROFILE to false when loaded outside profanity.rb (e.g. specs)
BOOT_PROFILE = false unless defined?(BOOT_PROFILE)

# Core application class for ProfanityFE.
#
# Owns all runtime state that was previously captured by closures in
# profanity.rb: the command buffer, window manager, shared state,
# key bindings, mouse scroll handler, and game server connection.
#
# Converts closure-captured local variables to instance variables and
# the 30+ proc definitions to named methods. The key_action hash still
# contains Proc objects (SettingsLoader requires this), but each proc
# now delegates to an instance method rather than closing over 10+
# local variables.
#
# @example
#   app = Application.new(cli_options)
#   app.run
class Application
  attr_reader :key_binding, :key_action, :cmd_buffer, :window_mgr,
              :shared_state, :mouse_scroll

  DOT_COMMAND_HELP = [
    '.quit              Exit Profanity immediately',
    '.key               Show raw keycode of next key press',
    '.fixcolor          Reinitialize custom Curses colors',
    '.resync            Reset server time offset for timers',
    '.reload            Hot-reload settings XML file',
    '.layout <name>     Switch to a named window layout',
    '.resize            Recalculate window sizes for terminal',
    '.tab               List tabs (active marked with *)',
    '.tab <N|name>      Switch tab by number or name',
    '.arrow             Cycle arrow keys: history/page/line',
    '.links             Toggle in-game link highlighting',
    '.select            Toggle drag-to-select without links',
    '.draghl            Toggle live highlight while dragging',
    '.scrollcfg         Configure mouse scroll wheel',
    '.highlight <text>   Add cyan highlight for text (session only)',
    '.unhighlight <text> Remove an inline highlight',
    '.highlight          List active inline highlights',
    '.help              Show this help'
  ].freeze

  # How long .key waits for a key press before giving up, in milliseconds.
  DOT_KEY_TIMEOUT_MS = 5000

  # Seconds to wait for the TCP connection to the game server before giving
  # up, so an unreachable --host fails instead of hanging.
  CONNECT_TIMEOUT = 10

  # Create a new application instance with the given CLI options.
  #
  # @param cli_options [Hash] parsed CLI options from OptionParser
  INLINE_HIGHLIGHT_COLOR = '00ffff'

  def initialize(cli_options)
    @cli_options = cli_options
    @server = nil
    # Receives the server thread's outcome (see #start_server_thread)
    @session_end = Queue.new

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
    @window_mgr = WindowManager.new
    @key_binding = {}
    @key_action = {}
    @selection_enabled = false

    setup_key_actions

    @mouse_scroll = MouseScroll.new(@key_action, method(:write_to_client))
    @mouse_scroll.enable_click_events if cli_options[:links]
    boot_mark('Application.new') if BOOT_PROFILE
  end

  # Load settings, connect to the game server, and run the input loop.
  # This is the main entry point -- blocks until the connection closes
  # or the user quits.
  #
  # @return [void] never returns normally; calls +exit+ on disconnect
  def run
    load_settings_and_layout
    boot_mark('settings + layout') if BOOT_PROFILE
    connect_server
    boot_mark('connect_server') if BOOT_PROFILE
    start_server_thread
    boot_mark('server thread started') if BOOT_PROFILE
    flush_boot_profile if BOOT_PROFILE
    input_loop
  end

  # Execute a dot-command or forward to the game server.
  #
  # Dot-commands (e.g. .quit, .key, .reload) are handled locally;
  # everything else is forwarded to the server with '.' replaced by ';'.
  # A dot-command matches case-insensitively and only as a whole word
  # (its name followed by whitespace or end of input), so Lich scripts
  # such as .arrows or .tabulate still reach the server.
  #
  # @param cmd [String] the command text to execute
  # @return [void]
  def execute_command(cmd)
    if cmd =~ /^\.quit(?=\s|\z)/i
      exit
    elsif cmd =~ /^\.key(?=\s|\z)/i
      handle_dot_key
    elsif cmd =~ /^\.fixcolor(?=\s|\z)/i
      ColorManager.reinitialize_colors
    elsif cmd =~ /^\.resync(?=\s|\z)/i
      @shared_state.skip_server_time_offset = false
    elsif cmd =~ /^\.reload(?=\s|\z)/i
      handle_dot_reload
    elsif (match = cmd.match(/^\.layout\s+(?<layout>.+)/i))
      @window_mgr.load_layout(match[:layout])
      @cmd_buffer.window = @window_mgr.command_window
      @key_action['resize'].call
    elsif cmd =~ /^\.resize(?=\s|\z)/i
      @key_action['resize'].call
    elsif (match = cmd.match(/^\.tab(?=\s|\z)(?:\s+(?<arg>.+))?/i))
      handle_dot_tab(match[:arg]&.strip)
    elsif cmd =~ /^\.arrow(?=\s|\z)/i
      handle_dot_arrow
    elsif cmd =~ /^\.links(?=\s|\z)/i
      handle_dot_links
    elsif cmd =~ /^\.select(?=\s|\z)/i
      handle_dot_select
    elsif cmd =~ /^\.draghl(?=\s|\z)/i
      handle_dot_draghl
    elsif cmd =~ /^\.scrollcfg(?=\s|\z)/i
      @mouse_scroll.start_configuration
    elsif (match = cmd.match(/^\.unhighlight\s+(?<pattern>.+)/i))
      handle_dot_unhighlight(match[:pattern])
    elsif (match = cmd.match(/^\.highlight(?=\s|\z)(?:\s+(?<pattern>.+))?/i))
      handle_dot_highlight(match[:pattern]&.strip)
    elsif cmd =~ /^\.help(?=\s|\z)/i
      handle_dot_help
    else
      send_to_server(cmd.sub(/^\./, ';'))
    end
  end

  # Interpret and execute a macro string.
  #
  # Inserts characters into the command buffer while handling escape
  # sequences: \\ (literal backslash), \x (clear buffer), \r (send
  # command), \@ (literal @), \? (backfill cursor position). A bare @
  # marks the final cursor position.
  #
  # @param macro [String] the macro string to execute
  # @return [void]
  def do_macro(macro)
    backslash = false
    at_pos = nil
    backfill = nil
    macro.split('').each_with_index do |ch, i|
      if backslash
        case ch
        when '\\'
          @cmd_buffer.put_ch('\\')
        when 'x'
          @cmd_buffer.text.clear
          @cmd_buffer.clear_and_get
        when 'r'
          at_pos = nil
          send_command
        when '@'
          @cmd_buffer.put_ch('@')
        when '?'
          backfill = i - 3
        end
        backslash = false
      elsif ch == '\\'
        backslash = true
      elsif ch == '@'
        at_pos = @cmd_buffer.pos
      else
        @cmd_buffer.put_ch(ch)
      end
    end
    if at_pos
      @cmd_buffer.cursor_left while at_pos < @cmd_buffer.pos
      @cmd_buffer.cursor_right while at_pos > @cmd_buffer.pos
    end
    @cmd_buffer.refresh
    if backfill
      @cmd_buffer.window.setpos(0, backfill)
      backfill = nil
    end
    CursesRenderer.doupdate
  end

  private

  # ---- Feedback helpers ----

  def flush_boot_profile
    prev = 0.0
    lines = BOOT_TIMINGS.map do |label, ms|
      delta = (ms - prev).round(1)
      prev = ms
      format('  %7.1fms (+%6.1fms)  %s', ms, delta, label)
    end
    ProfanityLog.write('boot-profile', "Startup timing:\n#{lines.join("\n")}")
  end

  def feedback_colors(text)
    [{ start: 0, end: text.length, fg: FEEDBACK_COLOR, bg: nil, ul: nil }]
  end

  def write_to_client(text)
    if (window = @window_mgr.stream[MAIN_STREAM])
      window.add_string(text, feedback_colors(text))
      @cmd_buffer.refresh
      CursesRenderer.doupdate
    end
  end

  # ---- Dot-command handlers ----

  def handle_dot_key
    if (window = @window_mgr.stream[MAIN_STREAM])
      msg = '* Waiting for key press...'
      window.add_string('* ', feedback_colors('* '))
      window.add_string(msg, feedback_colors(msg))
      @cmd_buffer.refresh
      CursesRenderer.doupdate
      ch = wait_for_key
      msg = if ch.nil?
              "* No key pressed within #{DOT_KEY_TIMEOUT_MS / 1000} seconds"
            else
              "* Detected keycode: #{ch}"
            end
      window.add_string(msg, feedback_colors(msg))
      window.add_string('* ', feedback_colors('* '))
      CursesRenderer.doupdate
    end
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
      msg = '* No tabbed windows configured'
      @window_mgr.stream[MAIN_STREAM]&.add_string(msg, feedback_colors(msg))
    elsif arg.nil? || arg.empty?
      TabbedTextWindow.list.each do |win|
        tabs_info = win.tabs.keys.each_with_index.map do |name, i|
          "#{i + 1}:#{name}#{name == win.active_tab ? '*' : ''}"
        end.join(' ')
        msg = "* Tabs: #{tabs_info}"
        @window_mgr.stream[MAIN_STREAM]&.add_string(msg, feedback_colors(msg))
      end
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
    if (window = @window_mgr.stream[MAIN_STREAM])
      mode = if @key_binding[Curses::KEY_UP] == @key_action['previous_command']
               'history'
             elsif @key_binding[Curses::KEY_UP] == @key_action['scroll_current_window_up_page']
               'page scroll'
             else
               'line scroll'
             end
      msg = "* Arrow mode: #{mode}"
      window.add_string(msg, feedback_colors(msg))
      CursesRenderer.doupdate
    end
  end

  def handle_dot_links
    @shared_state.blue_links = !@shared_state.blue_links
    if @shared_state.blue_links
      @mouse_scroll.enable_click_events
    elsif !@selection_enabled
      # Keep mouse capture when .select is still on
      @mouse_scroll.disable_click_events
    end
    if (room_win = @window_mgr.room['room'])
      room_win.links_enabled = @shared_state.blue_links
      room_win.render
    end
    if (window = @window_mgr.stream[MAIN_STREAM])
      msg = if @shared_state.blue_links
              '* Links: ON (clickable links + drag-to-select; Shift+drag for native selection)'
            elsif @selection_enabled
              '* Links: OFF (drag-to-select still on via .select)'
            else
              '* Links: OFF (native terminal selection)'
            end
      window.add_string(msg, feedback_colors(msg))
      CursesRenderer.doupdate
    end
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
    error = SettingsLoader.load(SETTINGS_FILENAME, @key_binding, @key_action, method(:do_macro),
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
    window = @window_mgr.stream[MAIN_STREAM]
    return unless window

    if pattern.nil? || pattern.empty?
      @inline_highlights ||= {}
      if @inline_highlights.empty?
        msg = '* No inline highlights active'
        window.add_string(msg, feedback_colors(msg))
      else
        window.add_string('* ', feedback_colors('* '))
        @inline_highlights.each do |regex, _|
          msg = "*   #{regex.source}"
          window.add_string(msg, [{ start: 0, end: msg.length, fg: INLINE_HIGHLIGHT_COLOR, bg: nil, ul: nil }])
        end
        window.add_string('* ', feedback_colors('* '))
      end
      CursesRenderer.doupdate
      return
    end

    @inline_highlights ||= {}
    pattern = pattern.sub(/^"(.*)"$/, '\1')
    begin
      regex = Regexp.new(Regexp.escape(pattern), Regexp::IGNORECASE)
    rescue RegexpError => e
      msg = "* Invalid pattern: #{e.message}"
      window.add_string(msg, feedback_colors(msg))
      CursesRenderer.doupdate
      return
    end

    colors = [INLINE_HIGHLIGHT_COLOR, nil, nil]
    SETTINGS_LOCK.synchronize do
      HIGHLIGHT[regex] = colors
    end
    @inline_highlights[regex] = colors

    msg = "* Highlight added: #{pattern}"
    window.add_string(msg, [{ start: 0, end: msg.length, fg: INLINE_HIGHLIGHT_COLOR, bg: nil, ul: nil }])
    CursesRenderer.doupdate
  end

  def handle_dot_unhighlight(pattern)
    window = @window_mgr.stream[MAIN_STREAM]
    return unless window

    @inline_highlights ||= {}
    pattern = pattern.sub(/^"(.*)"$/, '\1')
    target = @inline_highlights.keys.find { |r| r.source == Regexp.escape(pattern) }
    unless target
      msg = "* No inline highlight found for: #{pattern}"
      window.add_string(msg, feedback_colors(msg))
      CursesRenderer.doupdate
      return
    end

    SETTINGS_LOCK.synchronize do
      HIGHLIGHT.delete(target)
    end
    @inline_highlights.delete(target)

    msg = "* Highlight removed: #{pattern}"
    window.add_string(msg, feedback_colors(msg))
    CursesRenderer.doupdate
  end

  def handle_dot_help
    if (window = @window_mgr.stream[MAIN_STREAM])
      window.add_string('* ', feedback_colors('* '))
      DOT_COMMAND_HELP.each { |line| msg = "*   #{line}"; window.add_string(msg, feedback_colors(msg)) }
      window.add_string('* ', feedback_colors('* '))
      CursesRenderer.doupdate
    end
  end

  # ---- Command sending ----

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

  # Write one line to the game server, never while holding the render lock.
  #
  # Key handlers run inside {CursesRenderer.synchronize}. If the server
  # stops reading and the socket's send buffer fills, the write blocks; with
  # the lock held that would also stop the server thread from drawing. So
  # the write waits until the lock is released (see
  # {CursesRenderer.outside_lock}); lines keep the order they were sent in.
  #
  # @param line [String] the command to send
  # @return [void]
  def send_to_server(line)
    CursesRenderer.outside_lock { @server.puts line }
  end

  def send_history_command(index)
    if (cmd = @cmd_buffer.history[index])
      if (window = @window_mgr.stream[MAIN_STREAM])
        @window_mgr.add_prompt(window, @shared_state.prompt_text, cmd)
        @cmd_buffer.refresh
        CursesRenderer.doupdate
      end
      execute_command(cmd)
    end
  end

  # ---- Key action setup ----

  # Register every named key action as a {Proc} in {#key_action}.
  #
  # Each cursor/edit action delegates to {CommandBuffer}, which only stages
  # its changes to the curses virtual screen via +noutrefresh+. The physical
  # terminal is not repainted until +doupdate+ is called, so *every* action
  # that mutates the visible command line must end with
  # {CursesRenderer.doupdate}. Omitting it leaves the edit invisible until
  # the next keystroke happens to trigger a flush -- the class of bug that
  # previously affected +cursor_backspace_word+, +cursor_delete_word+, and
  # +cursor_yank+.
  #
  # @return [void]
  # @see CommandBuffer#backspace_word
  # @see CursesRenderer.doupdate
  def setup_key_actions
    @key_action['resize'] = proc {
      @window_mgr.resize(@cmd_buffer)
      CursesRenderer.doupdate
    }

    @key_action['cursor_left']           = proc { @cmd_buffer.cursor_left; CursesRenderer.doupdate }
    @key_action['cursor_right']          = proc { @cmd_buffer.cursor_right; CursesRenderer.doupdate }
    @key_action['cursor_word_left']      = proc { @cmd_buffer.cursor_word_left; CursesRenderer.doupdate }
    @key_action['cursor_word_right']     = proc { @cmd_buffer.cursor_word_right; CursesRenderer.doupdate }
    @key_action['cursor_home']           = proc { @cmd_buffer.cursor_home; CursesRenderer.doupdate }
    @key_action['cursor_end']            = proc { @cmd_buffer.cursor_end; CursesRenderer.doupdate }
    @key_action['cursor_backspace']      = proc { @cmd_buffer.backspace; CursesRenderer.doupdate }
    @key_action['cursor_delete']         = proc { @cmd_buffer.delete_char; CursesRenderer.doupdate }
    @key_action['cursor_backspace_word'] = proc { @cmd_buffer.backspace_word; CursesRenderer.doupdate }
    @key_action['cursor_delete_word']    = proc { @cmd_buffer.delete_word; CursesRenderer.doupdate }
    @key_action['cursor_kill_forward']   = proc { @cmd_buffer.kill_forward; CursesRenderer.doupdate }
    @key_action['cursor_kill_line']      = proc { @cmd_buffer.kill_line; CursesRenderer.doupdate }
    @key_action['cursor_yank']           = proc { @cmd_buffer.yank; CursesRenderer.doupdate }

    @key_action['switch_current_window'] = proc {
      SCROLL_WINDOW[0]&.set_active(false)
      SCROLL_WINDOW.push(SCROLL_WINDOW.shift)
      SCROLL_WINDOW[0]&.set_active(true)
      @cmd_buffer.refresh
      CursesRenderer.doupdate
    }

    @key_action['next_tab'] = proc {
      TabbedTextWindow.list.each(&:next_tab)
      @cmd_buffer.refresh
      CursesRenderer.doupdate
    }
    @key_action['switch_tab'] = @key_action['next_tab']

    @key_action['prev_tab'] = proc {
      TabbedTextWindow.list.each(&:prev_tab)
      @cmd_buffer.refresh
      CursesRenderer.doupdate
    }
    @key_action['switch_tab_reverse'] = @key_action['prev_tab']

    (1..5).each do |n|
      @key_action["switch_tab_#{n}"] = proc {
        TabbedTextWindow.list.each { |w| w.switch_tab_by_index(n) }
        @cmd_buffer.refresh
        CursesRenderer.doupdate
      }
    end

    @key_action['scroll_current_window_up_one'] = proc {
      SCROLL_WINDOW[0]&.scroll(-1)
      @cmd_buffer.refresh
      CursesRenderer.doupdate
    }

    @key_action['scroll_current_window_down_one'] = proc {
      SCROLL_WINDOW[0]&.scroll(1)
      @cmd_buffer.refresh
      CursesRenderer.doupdate
    }

    @key_action['scroll_current_window_up_page'] = proc {
      if (w = SCROLL_WINDOW[0])
        w.scroll(0 - w.maxy + 1)
      end
      @cmd_buffer.refresh
      CursesRenderer.doupdate
    }

    @key_action['scroll_current_window_down_page'] = proc {
      if (w = SCROLL_WINDOW[0])
        w.scroll(w.maxy - 1)
      end
      @cmd_buffer.refresh
      CursesRenderer.doupdate
    }

    @key_action['scroll_current_window_bottom'] = proc {
      SCROLL_WINDOW[0]&.scroll(SCROLL_WINDOW[0]&.max_buffer_size)
      @cmd_buffer.refresh
      CursesRenderer.doupdate
    }

    @key_action['previous_command'] = proc { @cmd_buffer.previous_command; CursesRenderer.doupdate }
    @key_action['next_command']     = proc { @cmd_buffer.next_command; CursesRenderer.doupdate }

    @key_action['switch_arrow_mode'] = proc {
      if @key_binding[Curses::KEY_UP] == @key_action['previous_command']
        @key_binding[Curses::KEY_UP] = @key_action['scroll_current_window_up_page']
        @key_binding[Curses::KEY_DOWN] = @key_action['scroll_current_window_down_page']
      elsif @key_binding[Curses::KEY_UP] == @key_action['scroll_current_window_up_page']
        @key_binding[Curses::KEY_UP] = @key_action['scroll_current_window_up_one']
        @key_binding[Curses::KEY_DOWN] = @key_action['scroll_current_window_down_one']
      else
        @key_binding[Curses::KEY_UP] = @key_action['previous_command']
        @key_binding[Curses::KEY_DOWN] = @key_action['next_command']
      end
    }

    @key_action['send_command']             = proc { send_command }
    @key_action['send_last_command']        = proc { send_history_command(1) }
    @key_action['send_second_last_command'] = proc { send_history_command(2) }
    @key_action['autocomplete']             = proc { Autocomplete.complete(@cmd_buffer, @window_mgr.stream[MAIN_STREAM]) }
  end

  # ---- Initialization ----

  def load_settings_and_layout
    SettingsLoader.load(SETTINGS_FILENAME, @key_binding, @key_action, method(:do_macro))

    if LAYOUT.empty?
      fatal_error("ERROR: No layouts found in #{SETTINGS_FILENAME}.",
                  'The XML file may be malformed. Check for unclosed tags or encoding errors.')
    end

    @window_mgr.load_layout('default')
    @cmd_buffer.window = @window_mgr.command_window
    @window_mgr.room['room']&.links_enabled = @cli_options[:links]

    unless @cmd_buffer.window
      fatal_error("ERROR: Layout has no command window. Add <window class='command'/> to your layout.")
    end

    TextWindow.list.each { |w| w.maxy.times { w.add_string "\n".dup } }
  end

  def connect_server
    @server = Socket.tcp(HOST, PORT, connect_timeout: CONNECT_TIMEOUT)
    @server.puts "SET_FRONTEND_PID #{Process.pid}"
    @server.flush

    @shared_state.server_time_offset = 0.0

    # Time sync thread
    Thread.new do
      sleep TIME_SYNC_DELAY
      @shared_state.skip_server_time_offset = false
    end
  # SystemCallError covers refused, unreachable, timed out, and bad
  # address; SocketError covers name lookup. IO::TimeoutError is what
  # TCPSocket's connect_timeout raises, should the socket class change.
  rescue SystemCallError, SocketError, IO::TimeoutError => e
    fatal_error("Failed to connect to game server at #{HOST}:#{PORT}: #{e.message}",
                'Is the game server running?')
  end

  # Print an error and exit with status 1, closing the curses screen first.
  #
  # Until +close_screen+, curses owns the terminal's alternate screen, which
  # is discarded when the program exits, so an error printed earlier is
  # never seen.
  #
  # @param lines [Array<String>] lines to print to stderr
  # @return [void] never returns
  def fatal_error(*lines)
    Curses.close_screen
    lines.each { |line| warn line }
    exit 1
  end

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
      event_bus: @event_bus
    )
    # The server thread only reports how the connection ended; the input
    # loop picks that up and ends the session on the main thread.
    Thread.new do
      outcome = :crashed
      outcome = @processor.run(@server)
    ensure
      @session_end << outcome
    end
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

  # Block until a key is pressed. Resizes and mouse events are not key
  # presses. A read error (nil) also ends the wait, so a lost terminal
  # cannot spin here.
  #
  # @return [void]
  def wait_for_exit_key
    window = @cmd_buffer.window
    window.nodelay = false
    loop do
      ch = window.getch
      break unless [Curses::KEY_RESIZE, Curses::KEY_MOUSE].include?(ch)
    end
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
      any_updated = true if window.update
    end
    @cmd_buffer.window&.noutrefresh if any_updated
    any_updated
  end

  def input_loop
    key_combo = nil
    @cmd_buffer.window.nodelay = true

    loop do
      IO.select([$stdin], nil, nil, 0.1)
      end_session(@session_end.pop) unless @session_end.empty?

      CursesRenderer.synchronize do
        # Tick countdowns on every iteration (~100ms), regardless of input
        countdown_updated = tick_countdowns
        # Drag held at a window edge keeps scrolling once per tick
        drag_scrolled = tick_drag_auto_scroll

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
    ProfanityLog.write('main', e.to_s, backtrace: e.backtrace)
  ensure
    begin
      @server&.close
    rescue StandardError
      # ignore
    end
    Curses.close_screen
  end

  # Dispatch one key press: a mouse event, a step through a key combo, a
  # bound key action, or a character typed into the command line.
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
      handle_mouse_event
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

  # ---- Mouse event handling ----

  def handle_mouse_event
    mouse = Curses.getmouse
    return unless mouse

    if @mouse_scroll.configuring?
      @mouse_scroll.process(mouse)
      return
    end
    @mouse_scroll.process(mouse)

    screen_y = mouse.y
    screen_x = mouse.x
    bstate = mouse.bstate

    if (bstate & Curses::BUTTON1_PRESSED) != 0
      handle_mouse_press(screen_y, screen_x)
    elsif (bstate & Curses::BUTTON1_RELEASED) != 0
      handle_mouse_release(screen_y, screen_x)
    elsif defined?(Curses::BUTTON1_CLICKED) && (bstate & Curses::BUTTON1_CLICKED) != 0
      SelectionManager.clear_selection
      window = BaseWindow.find_window_at(screen_y, screen_x)
      if window
        rel_y = screen_y - window.begy
        rel_x = screen_x - window.begx
        dispatch_link(window, rel_y, rel_x)
      end
    elsif MouseScroll::MOTION_EVENTS.nonzero? && (bstate & MouseScroll::MOTION_EVENTS) != 0
      handle_mouse_drag(screen_y, screen_x)
    end
  end

  def handle_mouse_press(screen_y, screen_x)
    window = BaseWindow.find_window_at(screen_y, screen_x)
    unless window
      SelectionManager.clear_selection
      return
    end

    rel_y = screen_y - window.begy
    rel_x = screen_x - window.begx
    multi_click = SelectionManager.start_selection(window, rel_y, rel_x)
    # Motion reporting only while the button is held — a permanent
    # motion stream corrupts the display
    @mouse_scroll.begin_drag_capture
    CursesRenderer.doupdate if multi_click
  end

  # Live highlight update from a motion report while button 1 is held.
  # SelectionManager throttles redraws so a motion flood coalesces.
  def handle_mouse_drag(screen_y, screen_x)
    window = SelectionManager.active_window
    return unless window && SelectionManager.selecting

    rel_y = screen_y - window.begy
    rel_x = screen_x - window.begx
    CursesRenderer.doupdate if SelectionManager.drag_update(rel_y, rel_x)
  end

  def handle_mouse_release(screen_y, screen_x)
    @mouse_scroll.end_drag_capture
    return unless SelectionManager.selecting

    window = SelectionManager.active_window
    unless window
      SelectionManager.clear_selection
      return
    end

    rel_y = screen_y - window.begy
    rel_x = screen_x - window.begx
    start_pos = SelectionManager.start_pos

    if start_pos && start_pos[0] == rel_y && (start_pos[1] - rel_x).abs <= 3
      if SelectionManager.multi_click_selected?
        # Double/triple click: copy the expanded word/line selection
        finalize_selection
      else
        # Single click (no drag): check for link, skip selection
        dispatch_link(window, rel_y, rel_x)
        SelectionManager.clear_selection
      end
    else
      # Actual drag: finalize selection and copy to clipboard
      SelectionManager.update_selection(rel_y, rel_x)
      finalize_selection
    end
  end

  # Copy the finished selection and show brief feedback in the main window.
  def finalize_selection
    chars = SelectionManager.end_selection
    write_to_client("* [copied #{chars} chars]") if chars&.positive?
    CursesRenderer.doupdate
  end

  # While a drag is held at a window's top or bottom edge, keep scrolling
  # one line per input-loop tick (~100ms) and extend the selection.
  # Motion events stop when the pointer stops moving, so the tick drives
  # the repeat. Returns true if the screen needs a refresh.
  def tick_drag_auto_scroll
    return false unless SelectionManager.selecting

    window = SelectionManager.active_window
    pos = SelectionManager.last_drag_pos
    return false unless window && pos

    scrolled = window.drag_auto_scroll(pos[0])
    SelectionManager.update_selection(pos[0], pos[1]) if scrolled
    scrolled
  end

  def dispatch_link(window, rel_y, rel_x)
    # Links may be toggled off while selection capture (.select) stays on;
    # lines rendered earlier can still carry cmd runs that must not fire
    return unless @shared_state.blue_links

    if (link_cmd = window.link_cmd_at(rel_y, rel_x))
      if (main = @window_mgr.stream[MAIN_STREAM])
        @window_mgr.add_prompt(main, @shared_state.prompt_text, link_cmd)
        CursesRenderer.doupdate
      end
      @cmd_buffer.add_to_history(link_cmd)
      send_to_server(link_cmd)
      true
    end
  end
end
