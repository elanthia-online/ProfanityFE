# frozen_string_literal: true

require_relative 'safe_arithmetic'
require_relative 'streams'
require_relative 'feedback'

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
    @previous_indicator = {}
    @previous_stream = {}
    @previous_progress = {}
    @previous_countdown = {}
    @old_windows = []
    @prompt_text = nil
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
      @prompt_text = data[:text]
      fit_prompt
    end

    # ---- Room events ----

    event_bus.on(:room_title) do |data|
      @room[Streams::ROOM]&.update_title(data[:text])
    end

    event_bus.on(:room_desc) do |data|
      @room[Streams::ROOM]&.update_desc(data[:text], links: data[:links] || [])
    end

    event_bus.on(:room_objects) do |data|
      @room[Streams::ROOM]&.update_objects(data[:text], links: data[:links] || [], creatures: data[:creatures] || [])
    end

    event_bus.on(:room_players) do |data|
      @room[Streams::ROOM]&.update_players(data[:text], links: data[:links] || [])
    end

    event_bus.on(:room_exits) do |data|
      @room[Streams::ROOM]&.update_exits(data[:text], links: data[:links] || [])
    end

    event_bus.on(:room_lich_exits) do |data|
      @room[Streams::ROOM]&.update_lich_exits(data[:text])
    end

    event_bus.on(:room_number) do |data|
      @room[Streams::ROOM]&.update_room_number(data[:text])
    end

    event_bus.on(:room_stringprocs) do |data|
      @room[Streams::ROOM]&.update_stringprocs(data[:text])
    end

    event_bus.on(:room_supplemental_clear) do |_data|
      @room[Streams::ROOM]&.clear_supplemental
    end

    event_bus.on(:room_render) do |_data|
      @room[Streams::ROOM]&.render
    end

    # ---- Stream management events ----

    event_bus.on(:exp_set_current) do |data|
      @stream[Streams::EXP]&.set_current(data[:skill])
    end

    event_bus.on(:exp_delete_skill) do |_data|
      @stream[Streams::EXP]&.delete_skill
    end

    event_bus.on(:clear_spells) do |_data|
      @stream[Streams::PERC]&.clear_spells
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
        open_in_browser(data[:url])
      end
    end

    event_bus.on(:disconnect) do |_data|
      Feedback.write(@stream[MAIN_STREAM], '* Connection closed', '* Press any key to exit...', banner: true)
    end
  end

  # Evaluate a layout dimension string to an integer, substituting
  # Curses terminal dimensions for the tokens "lines" and "cols".
  #
  # @param str [String] dimension expression (e.g. "lines-2", "cols/3")
  # @return [Integer] computed pixel/cell dimension value
  def fix_layout_number(str)
    str = str.gsub('lines', Curses.lines.to_s).gsub('cols', Curses.cols.to_s)
    SafeArithmetic.evaluate(str)
  end

  # Load a layout by ID from the LAYOUT constant and rebuild all windows.
  #
  # The server read thread reads the handler hashes, so call this before
  # that thread starts or inside {CursesRenderer.synchronize}, which the
  # server thread holds while it processes a line. Text, indicator,
  # progress, and countdown windows whose keys appear in the new layout are
  # reused rather than recreated, preserving their content buffers. Every
  # other window from the previous layout, of any window class, is closed
  # and removed from its class list and from SCROLL_WINDOW.
  #
  # @param layout_id [String] key into the global LAYOUT hash
  # @return [void]
  def load_layout(layout_id)
    xml = LAYOUT[layout_id]
    unless xml
      warn "Warning: layout '#{layout_id}' not found in LAYOUT (available: #{LAYOUT.keys.join(', ')})"
      return
    end

    @old_windows = BaseWindow.all_windows

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

    @old_windows.each { |window| close_window(window) }
    forget_previous_layout

    SCROLL_WINDOW[0]&.set_active(true)

    CursesRenderer.doupdate
  end

  # Resize all windows to match the current terminal dimensions.
  #
  # Iterates every managed window class (text, indicator, progress,
  # countdown, command) and recalculates positions and sizes from the
  # stored layout expressions. Triggers a full Curses screen update
  # afterward.
  #
  # Text and tabbed windows re-wrap their stored lines, every tab's, to
  # the new width and repaint (see {LineBuffered#rewrap}).
  #
  # After the command window is resized, +cmd_buffer+ is redrawn so its
  # cursor and horizontal scroll offset match the new width.
  #
  # @param cmd_buffer [CommandBuffer, nil] the command-line buffer shown in
  #   the command window; redrawn after the resize when given
  # @return [void]
  def resize(cmd_buffer)
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
        win.rewrap
        win.repaint
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
        win.rewrap
        win.clear_scrollbar
        win.redraw
        win.noutrefresh
      end

      # The exp and spell builders leave the layout's last column unused;
      # keep that margin so these windows don't widen on resize.
      { ExpWindow => 1, PercWindow => 1, RoomWindow => 0 }.each do |klass, right_margin|
        klass.list.to_a.each do |win|
          next unless safe_reposition(win, right_margin: right_margin)
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

      # The layout sizes above are for the layout's own prompt label;
      # widen the prompt again for the last prompt the game sent.
      @command_window&.noutrefresh if fit_prompt
      # Refit the typed command to the command line's final width.
      cmd_buffer&.redraw

      Curses.doupdate
    end # CursesRenderer.synchronize
  end

  private

  # Size the prompt indicator to the last prompt the game sent and shift
  # the command window over by the width it gained or lost, relative to
  # their layout sizes. Does nothing until a +:prompt_changed+ event has
  # arrived or when the layout has no prompt indicator.
  #
  # @return [Boolean] true if the prompt was fitted
  def fit_prompt
    prompt_window = @indicator['prompt']
    return false unless prompt_window && @prompt_text

    init_h = fix_layout_number(prompt_window.layout[0])
    init_w = fix_layout_number(prompt_window.layout[1])
    # Neither window may shrink below one column (an empty prompt, or one
    # wider than the command line); curses rejects such sizes.
    new_w = [@prompt_text.length, 1].max
    prompt_window.resize(init_h, new_w)
    diff = new_w - init_w
    if @command_window
      @command_window.resize(fix_layout_number(@command_window_layout[0]),
                             [fix_layout_number(@command_window_layout[1]) - diff, 1].max)
      ctop = fix_layout_number(@command_window_layout[2])
      cleft = fix_layout_number(@command_window_layout[3]) + diff
      @command_window.move(ctop, cleft)
    end
    prompt_window.label = @prompt_text
    true
  end

  # Close a window the new layout did not reuse, and remove it from every
  # list that could still hit-test, repaint, or scroll it.
  #
  # @param window [BaseWindow] a window from the previous layout
  # @return [void]
  def close_window(window)
    window.class.unregister_instance(window)
    SCROLL_WINDOW.delete(window)
    window.scrollbar&.close
    window.close
  end

  # Drop the previous-layout references the builders used during
  # {#load_layout}, so closed windows are not kept reachable.
  #
  # @return [void]
  def forget_previous_layout
    @old_windows = []
    @previous_indicator = {}
    @previous_stream = {}
    @previous_progress = {}
    @previous_countdown = {}
  end

  # Open a URL in the system browser without blocking the caller.
  #
  # The command is spawned as an argument list, so the URL is never parsed
  # by a shell: characters such as +$(...)+ or backticks in a server-supplied
  # URL stay literal.
  #
  # @param url [String] the URL to open
  # @return [void]
  def open_in_browser(url)
    command = case RbConfig::CONFIG['host_os']
              when /darwin/ then ['open', url]
              when /linux|bsd/ then ['xdg-open', url]
              when /mswin|mingw|cygwin/ then ['rundll32', 'url.dll,FileProtocolHandler', url]
              end
    return unless command

    Process.detach(Process.spawn(*command, out: File::NULL, err: File::NULL))
  rescue SystemCallError => e
    ProfanityLog.write('launch_url', "could not open #{url}: #{e.message}")
  end

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
  # @param right_margin [Integer] columns of the layout width to leave unused
  # @return [Boolean] true if repositioned, false if skipped
  def safe_reposition(win, right_margin: 0)
    safe_resize_move(win, fix_layout_number(win.layout[0]), fix_layout_number(win.layout[1]) - right_margin,
                     fix_layout_number(win.layout[2]), fix_layout_number(win.layout[3]))
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
