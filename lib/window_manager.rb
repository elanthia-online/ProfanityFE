# frozen_string_literal: true

# Manages Curses window creation, layout loading, and handler hash access
# for the profanity terminal UI.

# Manages window creation, layout loading, and handler hash access.
#
# Owns the five handler hashes (stream, indicator, progress, countdown,
# room) that map string keys to their corresponding window objects, plus
# the command input window. Provides mutex-protected layout reloading so
# the server read thread can safely read handler hashes while a layout
# reload replaces them.
#
# @example
#   wm = WindowManager.new
#   wm.load_layout('default')
#   wm.stream['main'].add_string("Hello")
class WindowManager
  attr_reader :command_window, :command_window_layout

  # Previous-layout hashes exposed for builder procs during {#load_layout}.
  # These are only meaningful inside a layout reload; outside that context
  # they are empty hashes.
  #
  # @return [Hash] previous indicator windows keyed by value
  # @api private
  attr_reader :previous_indicator

  # @return [Hash] previous stream windows keyed by stream name
  # @api private
  attr_reader :previous_stream

  # @return [Hash] previous progress windows keyed by value
  # @api private
  attr_reader :previous_progress

  # @return [Hash] previous countdown windows keyed by value
  # @api private
  attr_reader :previous_countdown

  # Windows from the previous layout that have not been reused.
  # Builder procs delete reused windows from this set; remaining
  # windows are closed after the layout loop.
  #
  # @return [Array<BaseWindow>]
  # @api private
  attr_reader :old_windows

  # Create a new window manager with empty handler hashes.
  #
  # @return [WindowManager]
  def initialize
    @stream = {}
    @indicator = {}
    @progress = {}
    @countdown = {}
    @room = {}
    @command_window = nil
    @command_window_layout = nil
    @handler_mutex = Mutex.new
    @previous_indicator = {}
    @previous_stream = {}
    @previous_progress = {}
    @previous_countdown = {}
    @old_windows = []
  end

  # Returns the live stream handler hash mapping stream names to window objects.
  #
  # @return [Hash<String, TextWindow>] the stream handler hash (not a copy)
  # @note Returns the live hash, not a copy. Mutations affect routing.
  attr_reader :stream

  # Returns the live indicator handler hash.
  #
  # @return [Hash<String, IndicatorWindow>] the indicator handler hash (not a copy)
  # @note Returns the live hash, not a copy. Mutations affect indicator display.
  attr_reader :indicator

  # Returns the live progress handler hash.
  #
  # @return [Hash<String, ProgressWindow>] the progress handler hash (not a copy)
  # @note Returns the live hash, not a copy. Mutations affect progress display.
  attr_reader :progress

  # Returns the live countdown handler hash.
  #
  # @return [Hash<String, CountdownWindow>] the countdown handler hash (not a copy)
  # @note Returns the live hash, not a copy. Mutations affect countdown display.
  attr_reader :countdown

  # Returns the live room handler hash.
  #
  # @return [Hash<String, RoomWindow>] the room handler hash (not a copy)
  # @note Returns the live hash, not a copy. Mutations affect room display.
  attr_reader :room

  # Display a prompt in a stream window, with optional command text.
  # Deduplicates consecutive identical prompts via the window's
  # +duplicate_prompt?+ method if available.
  #
  # @param window [BaseWindow] the target stream window
  # @param prompt_text [String] the prompt string (e.g., "H>")
  # @param cmd [String] optional command text appended after the prompt
  # @return [void]
  def add_prompt(window, prompt_text, cmd = '')
    return if cmd.empty? && window.respond_to?(:duplicate_prompt?) && window.duplicate_prompt?(prompt_text)

    prompt_colors = [{ start: 0, end: (prompt_text.length + cmd.length), fg: '555555' }]
    window.route_string("#{prompt_text}#{cmd}", prompt_colors, MAIN_STREAM)
  end

  # Subscribe to events from the parser's EventBus.
  #
  # Bridges typed events to the appropriate window objects: routes text
  # to stream windows, updates indicator/progress/countdown displays,
  # dispatches room data to the RoomWindow, and handles prompt resize.
  #
  # @param event_bus [EventBus] the event bus to subscribe to
  # @return [void]
  def subscribe_to_events(event_bus)
    # ---- Text display events ----

    event_bus.on(:stream_text) do |data|
      window = @stream[data[:stream]]
      next unless window

      window.route_string(data[:text], data[:colors], data[:stream], indent: data[:indent])
    end

    event_bus.on(:add_prompt) do |data|
      window = @stream[data[:stream] || MAIN_STREAM]
      next unless window
      args = [window, data[:text]]
      args << data[:command] if data[:command]
      add_prompt(*args)
    end

    # ---- Indicator events ----

    event_bus.on(:indicator_update) do |data|
      window = @indicator[data[:id]]
      next unless window

      # Set all attributes before redrawing so redraw sees consistent state.
      # Previously label= triggered an immediate redraw with stale label_colors.
      changed = false
      if data.key?(:label) && window.label != data[:label]
        window.instance_variable_set(:@label, data[:label])
        changed = true
      end
      if data.key?(:label_colors)
        window.label_colors = data[:label_colors]
        changed = true
      end
      if data.key?(:value) && data[:value] != window.value
        window.instance_variable_set(:@value, data[:value])
        changed = true
      end
      window.redraw if changed
    end

    event_bus.on(:compass_update) do |data|
      dirs = data[:dirs]
      %w[up down out n ne e se s sw w nw].each do |dir|
        window = @indicator["compass:#{dir}"]
        window&.update(dirs.include?(dir))
      end
    end

    # ---- Progress bar events ----

    event_bus.on(:progress_update) do |data|
      window = @progress[data[:id]]
      next unless window

      window.label = data[:label] if data.key?(:label)
      window.fg = data[:fg] if data.key?(:fg)
      window.bg = data[:bg] if data.key?(:bg)
      window.update(data[:value], data[:max])
    end

    # ---- Countdown events ----

    event_bus.on(:countdown_update) do |data|
      window = @countdown[data[:id]]
      next unless window

      window.end_time = data[:end_time] if data.key?(:end_time)
      window.secondary_end_time = data[:secondary_end_time] if data.key?(:secondary_end_time)
      window.update
    end

    event_bus.on(:countdown_active) do |data|
      window = @countdown[data[:id]]
      next unless window

      window.active = data[:active]
      window.update
    end

    event_bus.on(:stun) do |data|
      window = @countdown['stunned']
      next unless window

      window.end_time = Time.now.to_f - $server_time_offset.to_f + data[:seconds].to_f
      window.update
    end

    # ---- Prompt resize ----

    event_bus.on(:prompt_changed) do |data|
      text = data[:text]
      prompt_window = @indicator['prompt']
      next unless prompt_window

      init_h = fix_layout_number(prompt_window.layout[0])
      init_w = fix_layout_number(prompt_window.layout[1])
      new_w = text.length
      prompt_window.resize(init_h, new_w)
      diff = new_w - init_w
      if @command_window
        @command_window.resize(fix_layout_number(@command_window_layout[0]),
                               fix_layout_number(@command_window_layout[1]) - diff)
        ctop = fix_layout_number(@command_window_layout[2])
        cleft = fix_layout_number(@command_window_layout[3]) + diff
        @command_window.move(ctop, cleft)
      end
      prompt_window.label = text
    end

    # ---- Room events ----

    event_bus.on(:room_title) do |data|
      @room['room']&.update_title(data[:text])
    end

    event_bus.on(:room_desc) do |data|
      @room['room']&.update_desc(data[:text], links: data[:links] || [])
    end

    event_bus.on(:room_objects) do |data|
      @room['room']&.update_objects(data[:text], links: data[:links] || [], creatures: data[:creatures] || [])
    end

    event_bus.on(:room_players) do |data|
      @room['room']&.update_players(data[:text], links: data[:links] || [])
    end

    event_bus.on(:room_exits) do |data|
      @room['room']&.update_exits(data[:text], links: data[:links] || [])
    end

    event_bus.on(:room_lich_exits) do |data|
      @room['room']&.update_lich_exits(data[:text])
    end

    event_bus.on(:room_number) do |data|
      @room['room']&.update_room_number(data[:text])
    end

    event_bus.on(:room_stringprocs) do |data|
      @room['room']&.update_stringprocs(data[:text])
    end

    event_bus.on(:room_supplemental_clear) do |_data|
      @room['room']&.clear_supplemental
    end

    event_bus.on(:room_render) do |_data|
      @room['room']&.render
    end

    # ---- Stream management events ----

    event_bus.on(:exp_set_current) do |data|
      @stream['exp']&.set_current(data[:skill])
    end

    event_bus.on(:exp_delete_skill) do |_data|
      @stream['exp']&.delete_skill
    end

    event_bus.on(:clear_spells) do |_data|
      @stream['percWindow']&.clear_spells
    end

    # ---- Special events ----

    event_bus.on(:launch_url) do |data|
      window = @stream[MAIN_STREAM]
      next unless window

      if data[:remote]
        # --remote-url: display URL on screen for copy/paste (SSH/remote sessions)
        window.add_string(' *'.dup)
        window.add_string(" * LaunchURL: #{data[:url]}")
        window.add_string(' *'.dup)
      else
        # Default: open URL in system browser
        quoted = "\"#{data[:url]}\""
        case RbConfig::CONFIG['host_os']
        when /darwin/       then system("open #{quoted} >/dev/null 2>&1 &")
        when /linux|bsd/    then system("xdg-open #{quoted} >/dev/null 2>&1 &")
        when /mswin|mingw|cygwin/ then system("start #{quoted} >/dev/null 2>&1 &")
        end
      end
    end

    event_bus.on(:disconnect) do |_data|
      window = @stream[MAIN_STREAM]
      next unless window

      ['* ', '* Connection closed', '* Press any key to exit...', '* '].each do |msg|
        window.add_string(msg, [{ start: 0, end: msg.length, fg: FEEDBACK_COLOR, bg: nil, ul: nil }])
      end
    end
  end

  # Evaluate a layout dimension string to an integer, substituting
  # Curses terminal dimensions for the tokens "lines" and "cols".
  #
  # @param str [String] dimension expression (e.g. "lines-2", "cols/3")
  # @return [Integer] computed pixel/cell dimension value
  def fix_layout_number(str)
    str = str.gsub('lines', Curses.lines.to_s).gsub('cols', Curses.cols.to_s)
    safe_eval_arithmetic(str)
  end

  # Load a layout by ID from the LAYOUT constant and rebuild all windows.
  #
  # Synchronized with +@handler_mutex+ to prevent races with the server
  # read thread that constantly reads the handler hashes. Existing windows
  # whose keys appear in the new layout are reused (moved/resized) rather
  # than recreated, preserving their content buffers. Windows from the
  # previous layout that are not present in the new one are closed.
  #
  # @param layout_id [String] key into the global LAYOUT hash
  # @return [void]
  def load_layout(layout_id)
    xml = LAYOUT[layout_id]
    unless xml
      warn "Warning: layout '#{layout_id}' not found in LAYOUT (available: #{LAYOUT.keys.join(', ')})"
      return
    end

    @handler_mutex.synchronize do
      @old_windows = IndicatorWindow.list | TextWindow.list | CountdownWindow.list | ProgressWindow.list

      @previous_indicator = @indicator
      @indicator = {}

      @previous_stream = @stream
      @stream = {}

      @previous_progress = @progress
      @progress = {}

      @previous_countdown = @countdown
      @countdown = {}
      @room = {}

      xml.elements.each do |e|
        next unless e.name == 'window'

        if e.attributes['class'] == 'sink'
          sink = SinkWindow.new
          e.attributes['value']&.split(',')&.each do |str|
            @stream[str.strip] = sink
          end
          next
        end

        height = fix_layout_number(e.attributes['height'])
        width = fix_layout_number(e.attributes['width'])
        top = fix_layout_number(e.attributes['top'])
        left = fix_layout_number(e.attributes['left'])

        next unless (height > 0) && (width > 0) && (top >= 0) && (left >= 0) &&
                    (top < Curses.lines) && (left < Curses.cols)

        builder = BaseWindow.type_registry[e.attributes['class']]
        builder&.call(height, width, top, left, e, self)
      end

      if (current_scroll_window = SCROLL_WINDOW[0])
        current_scroll_window.set_active(true)
      end

      @old_windows.each do |window|
        IndicatorWindow.list.delete(window)
        TextWindow.list.delete(window)
        TabbedTextWindow.list.delete(window)
        CountdownWindow.list.delete(window)
        ProgressWindow.list.delete(window)
        SCROLL_WINDOW.delete(window)
        window.scrollbar.close if window.respond_to?(:scrollbar) && window.scrollbar
        window.close
      end

      CursesRenderer.doupdate
    end
  end

  # Resize all windows to match the current terminal dimensions.
  #
  # Iterates every managed window class (text, indicator, progress,
  # countdown, command) and recalculates positions and sizes from the
  # stored layout expressions. Triggers a full Curses screen update
  # afterward.
  #
  # @param _cmd_buffer [CommandBuffer] unused, retained for call-site compatibility
  # @return [void]
  def resize(_cmd_buffer)
    CursesRenderer.synchronize do
      window = Curses::Window.new(0, 0, 0, 0)
      window.refresh
      window.close

      # Skip resize when terminal is too small — ncurses segfaults on
      # invalid dimensions (negative/zero height or width, out-of-bounds
      # positions). The windows will be repositioned on the next resize
      # when the terminal is large enough.
      return if Curses.lines < 3 || Curses.cols < 10

      first_text_window = true
      TextWindow.list.to_a.each do |win|
        next unless safe_resize_move(win, fix_layout_number(win.layout[0]), fix_layout_number(win.layout[1]) - 1,
                                     fix_layout_number(win.layout[2]), fix_layout_number(win.layout[3]))
        win.scrollbar.resize([win.maxy, 1].max, 1)
        win.scrollbar.move(win.begy, win.begx + win.maxx)
        win.scroll(-win.maxy)
        win.scroll(win.maxy)
        win.clear_scrollbar
        if first_text_window
          win.update_scrollbar
          first_text_window = false
        end
        win.noutrefresh
      end

      TabbedTextWindow.list.to_a.each do |win|
        next unless safe_resize_move(win, fix_layout_number(win.layout[0]), fix_layout_number(win.layout[1]) - 1,
                                     fix_layout_number(win.layout[2]), fix_layout_number(win.layout[3]))
        if win.scrollbar
          win.scrollbar.resize([win.maxy, 1].max, 1)
          win.scrollbar.move(win.begy, win.begx + win.maxx)
        end
        win.scroll(-win.maxy)
        win.scroll(win.maxy)
        win.clear_scrollbar
        win.redraw
        win.noutrefresh
      end

      [ExpWindow, PercWindow, RoomWindow].each do |klass|
        klass.list.to_a.each do |win|
          next unless safe_reposition(win)
          win.redraw
          win.noutrefresh
        end
      end

      [IndicatorWindow, ProgressWindow, CountdownWindow].each do |klass|
        klass.list.to_a.each do |win|
          next unless safe_reposition(win)
          win.noutrefresh
        end
      end

      if @command_window && @command_window_layout
        h = [fix_layout_number(@command_window_layout[0]), 1].max
        w = [fix_layout_number(@command_window_layout[1]), 1].max
        t = [fix_layout_number(@command_window_layout[2]), 0].max
        l = [fix_layout_number(@command_window_layout[3]), 0].max
        if t < Curses.lines && l < Curses.cols
          @command_window.resize(h, w)
          @command_window.move(t, l)
          @command_window.noutrefresh
        end
      end

      Curses.doupdate
    end # CursesRenderer.synchronize
  end

  private

  # Safely resize and move a window, clamping dimensions to valid ranges.
  # ncurses segfaults on negative/zero dimensions or out-of-bounds positions.
  #
  # @param win [BaseWindow, Curses::Window] the window to resize and move
  # @param height [Integer] desired height
  # @param width [Integer] desired width
  # @param top [Integer] desired top position
  # @param left [Integer] desired left position
  # @return [Boolean] true if the window was resized, false if skipped
  def safe_resize_move(win, height, width, top, left)
    height = [height, 1].max
    width = [width, 1].max
    top = [top, 0].max
    left = [left, 0].max
    return false unless top < Curses.lines && left < Curses.cols

    win.resize(height, width)
    win.move(top, left)
    true
  end

  # Safely reposition a window using its stored layout expressions.
  #
  # @param win [BaseWindow] the window to reposition
  # @return [Boolean] true if repositioned, false if skipped
  def safe_reposition(win)
    safe_resize_move(win, fix_layout_number(win.layout[0]), fix_layout_number(win.layout[1]),
                     fix_layout_number(win.layout[2]), fix_layout_number(win.layout[3]))
  end

  # Resize and reposition a window according to its stored layout.
  #
  # @param win [BaseWindow] the window to reposition
  # @return [void]
  def reposition(win)
    win.resize(fix_layout_number(win.layout[0]), fix_layout_number(win.layout[1]))
    win.move(fix_layout_number(win.layout[2]), fix_layout_number(win.layout[3]))
  end
end

# Register the command window type. This is a plain Curses::Window (not a
# BaseWindow subclass), so it lives here rather than in a window file.
BaseWindow.register_type('command') do |height, width, top, left, element, wm|
  wm.instance_variable_set(:@command_window, Curses::Window.new(height, width, top, left)) unless wm.command_window
  wm.instance_variable_set(:@command_window_layout, [
                             element.attributes['height'], element.attributes['width'],
                             element.attributes['top'], element.attributes['left']
                           ])
  wm.command_window.scrollok(false)
  wm.command_window.keypad(true)
  wm.command_window
end
