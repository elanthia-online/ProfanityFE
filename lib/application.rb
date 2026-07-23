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

  # Create a new application instance with the given CLI options.
  #
  # @param cli_options [Hash] parsed CLI options from OptionParser
  INLINE_HIGHLIGHT_COLOR = '00ffff'

  def initialize(cli_options)
    @cli_options = cli_options
    @server = nil

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
  #
  # @param cmd [String] the command text to execute
  # @return [void]
  def execute_command(cmd)
    if cmd =~ /^\.quit/i
      exit
    elsif cmd =~ /^\.key/i
      handle_dot_key
    elsif cmd =~ /^\.fixcolor/i
      ColorManager.reinitialize_colors
    elsif cmd =~ /^\.resync/i
      @shared_state.skip_server_time_offset = false
    elsif cmd =~ /^\.reload/i
      SettingsLoader.load(SETTINGS_FILENAME, @key_binding, @key_action, method(:do_macro), reload: true)
    elsif (match = cmd.match(/^\.layout\s+(?<layout>.+)/))
      @window_mgr.load_layout(match[:layout])
      @cmd_buffer.window = @window_mgr.command_window
      @key_action['resize'].call
    elsif cmd =~ /^\.resize/i
      @key_action['resize'].call
    elsif (match = cmd.match(/^\.tab(?:\s+(?<arg>.+))?/i))
      handle_dot_tab(match[:arg]&.strip)
    elsif cmd =~ /^\.arrow/i
      handle_dot_arrow
    elsif cmd =~ /^\.links/i
      handle_dot_links
    elsif cmd =~ /^\.select/i
      handle_dot_select
    elsif cmd =~ /^\.draghl/i
      handle_dot_draghl
    elsif cmd =~ /^\.scrollcfg/i
      @mouse_scroll.start_configuration
    elsif (match = cmd.match(/^\.unhighlight\s+(?<pattern>.+)/i))
      handle_dot_unhighlight(match[:pattern])
    elsif (match = cmd.match(/^\.highlight(?:\s+(?<pattern>.+))?/i))
      handle_dot_highlight(match[:pattern]&.strip)
    elsif cmd =~ /^\.help/i
      handle_dot_help
    else
      @server.puts cmd.sub(/^\./, ';')
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
      msg = "* Detected keycode: #{@cmd_buffer.window.getch}"
      window.add_string(msg, feedback_colors(msg))
      window.add_string('* ', feedback_colors('* '))
      CursesRenderer.doupdate
    end
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

    SETTINGS_LOCK.synchronize do
      HIGHLIGHT[regex] = [INLINE_HIGHLIGHT_COLOR, nil, nil]
    end
    @inline_highlights[regex] = true

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
    @key_action['cursor_backspace_word'] = proc { @cmd_buffer.backspace_word }
    @key_action['cursor_delete_word']    = proc { @cmd_buffer.delete_word }
    @key_action['cursor_kill_forward']   = proc { @cmd_buffer.kill_forward; CursesRenderer.doupdate }
    @key_action['cursor_kill_line']      = proc { @cmd_buffer.kill_line; CursesRenderer.doupdate }
    @key_action['cursor_yank']           = proc { @cmd_buffer.yank }

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
      $stderr.puts "ERROR: No layouts found in #{SETTINGS_FILENAME}."
      $stderr.puts "The XML file may be malformed. Check for unclosed tags or encoding errors."
      exit 1
    end

    @window_mgr.load_layout('default')
    @cmd_buffer.window = @window_mgr.command_window
    @window_mgr.room['room']&.links_enabled = @cli_options[:links]

    unless @cmd_buffer.window
      $stderr.puts "ERROR: Layout has no command window. Add <window class='command'/> to your layout."
      exit 1
    end

    TextWindow.list.each { |w| w.maxy.times { w.add_string "\n".dup } }
  end

  def connect_server
    @server = TCPSocket.open(HOST, PORT)
    @server.puts "SET_FRONTEND_PID #{Process.pid}"
    @server.flush

    @shared_state.server_time_offset = 0.0

    # Time sync thread
    Thread.new do
      sleep TIME_SYNC_DELAY
      @shared_state.skip_server_time_offset = false
    end
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError => e
    warn "Failed to connect to game server on port #{PORT}: #{e.message}"
    warn 'Is the game server running?'
    exit 1
  end

  def start_server_thread
    @event_bus = EventBus.new
    @window_mgr.subscribe_to_events(@event_bus)

    processor = GameTextProcessor.new(
      window_mgr: @window_mgr,
      shared_state: @shared_state,
      cmd_buffer: @cmd_buffer,
      xml_escapes: @xml_escapes,
      event_bus: @event_bus
    )
    Thread.new { processor.run(@server) }
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

      CursesRenderer.synchronize do
        # Tick countdowns on every iteration (~100ms), regardless of input
        countdown_updated = tick_countdowns
        # Drag held at a window edge keeps scrolling once per tick
        drag_scrolled = tick_drag_auto_scroll

        ch = @cmd_buffer.window.getch
        if ch.nil?
          Curses.doupdate if countdown_updated || drag_scrolled
          next
        end

        if ch == Curses::KEY_MOUSE
          handle_mouse_event
          next
        end

        if key_combo
          if key_combo[ch].instance_of?(Proc)
            key_combo[ch].call
            key_combo = nil
          elsif key_combo[ch].instance_of?(Hash)
            key_combo = key_combo[ch]
          else
            key_combo = nil
          end
        elsif @key_binding[ch].instance_of?(Proc)
          @key_binding[ch].call
        elsif @key_binding[ch].instance_of?(Hash)
          key_combo = @key_binding[ch]
        elsif ch.instance_of?(String)
          @cmd_buffer.put_ch(ch)
          @cmd_buffer.refresh
          CursesRenderer.doupdate
        end
      end # CursesRenderer.synchronize
    end
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
      @server.puts link_cmd
      true
    end
  end
end
