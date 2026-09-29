# frozen_string_literal: true

require_relative 'streams'
require_relative 'feedback'
require_relative 'window_layout'
require_relative 'platform'

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
  # +duplicate_prompt?+ method ({BaseWindow#duplicate_prompt?}) if it has
  # one; a {SinkWindow} doesn't, and discards the prompt.
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

      # One redraw after all attributes are set (label= would redraw with
      # stale label_colors).
      window.apply_changes(data.slice(:label, :label_colors, :value))
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
  # Each window built from a BaseWindow subclass gets the element's
  # {WindowLayout} as its +layout+, which {#resize} places it by.
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

      layout = WindowLayout.from_element(e)
      size = layout.geometry

      next unless (size.height > 0) && (size.width > 0) && (size.top >= 0) && (size.left >= 0) &&
                  (size.top < Curses.lines) && (size.left < Curses.cols)

      builder = BaseWindow.type_registry[e.attributes['class']]
      window = builder&.call(size.height, size.width, size.top, size.left, e, self)
      window.layout = layout if window.is_a?(BaseWindow)
    end

    @old_windows.each { |window| close_window(window) }
    forget_previous_layout

    SCROLL_WINDOW[0]&.set_active(true)

    CursesRenderer.doupdate
  end

  # Take the command window a layout asks for. The first layout creates
  # it with the block; later layouts keep that window, which the command
  # buffer draws into, and only replace its layout.
  #
  # @param layout [WindowLayout] where the layout puts the command line
  # @yieldreturn [Curses::Window] a new command window, called only when
  #   there isn't one yet
  # @return [Curses::Window] the command window
  # @api private
  def install_command_window(layout)
    @command_window ||= yield
    @command_window_layout = layout
    @command_window
  end

  # Resize all windows to match the current terminal dimensions.
  #
  # Every registered window class ({BaseWindow.window_classes}), in
  # {BaseWindow.window_classes_in_resize_order}, resizes its own windows
  # ({BaseWindow.resize_all}): each is placed from its stored layout
  # expressions and redrawn as its class needs. Then the command window
  # is placed from its layout. Triggers a full Curses screen update
  # afterward. Nothing is resized while the terminal is under 3 lines or
  # 10 columns.
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

      # Each window class moves and redraws its own windows (see
      # BaseWindow.resize_all), in a fixed order: where windows overlap,
      # the one resized last shows.
      BaseWindow.window_classes_in_resize_order.each(&:resize_all)

      if @command_window && @command_window_layout && @command_window_layout.place(@command_window)
        @command_window.noutrefresh
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

    init_h = WindowLayout.evaluate(prompt_window.layout.height)
    init_w = WindowLayout.evaluate(prompt_window.layout.width)
    # Neither window may shrink below one column (an empty prompt, or one
    # wider than the command line); curses rejects such sizes.
    new_w = [@prompt_text.length, 1].max
    prompt_window.resize(init_h, new_w)
    diff = new_w - init_w
    if @command_window
      command = @command_window_layout.geometry
      @command_window.resize(command.height, [command.width - diff, 1].max)
      @command_window.move(command.top, command.left + diff)
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
    command = case Platform.os
              when :macos then ['open', url]
              when :unix then ['xdg-open', url]
              when :windows then ['rundll32', 'url.dll,FileProtocolHandler', url]
              end
    return unless command

    Process.detach(Process.spawn(*command, out: File::NULL, err: File::NULL))
  rescue SystemCallError => e
    ProfanityLog.write('launch_url', "could not open #{url}: #{e.message}")
  end
end

# Register the command window type. This is a plain Curses::Window (not a
# BaseWindow subclass), so it lives here rather than in a window file.
BaseWindow.register_type('command') do |height, width, top, left, element, wm|
  window = wm.install_command_window(WindowLayout.from_element(element)) do
    Curses::Window.new(height, width, top, left)
  end
  window.scrollok(false)
  window.keypad(true)
  window
end
