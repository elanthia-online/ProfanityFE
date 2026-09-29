# frozen_string_literal: true

require_relative 'window_layout'
require_relative 'layout_loader'
require_relative 'event_bridge'
require_relative 'clock'

# Manages Curses window creation, layout loading, and handler hash access
# for the profanity terminal UI.

# Manages window creation, layout loading, and handler hash access.
#
# Owns the five handler hashes (stream, indicator, progress, countdown,
# room) that map string keys to their corresponding window objects, plus
# the command input window. Provides mutex-protected layout reloading so
# the server read thread can safely read handler hashes while a layout
# reload replaces them. {LayoutLoader} builds the windows of a layout,
# and {EventBridge} shows the parser's events in them.
#
# @example
#   wm = WindowManager.new
#   wm.load_layout('default')
#   wm.stream['main'].add_string("Hello")
class WindowManager
  attr_reader :command_window, :command_window_layout

  # The clock read by the windows this manager builds and by stun
  # countdowns.
  #
  # @return [Clock]
  attr_reader :clock

  # Create a new window manager with empty handler hashes.
  #
  # @param clock [Clock] handed to the windows the layout builds
  # @return [WindowManager]
  def initialize(clock: Clock.new)
    @clock = clock
    @stream = {}
    @indicator = {}
    @progress = {}
    @countdown = {}
    @room = {}
    @command_window = nil
    @command_window_layout = nil
    @prompt_text = nil
    @layout_loader = LayoutLoader.new(self)
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
  # +duplicate_prompt?+ method ({StreamWindow#duplicate_prompt?}) if it has
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
  # Bridges typed events to the appropriate window objects through an
  # {EventBridge}: routes text to stream windows, updates
  # indicator/progress/countdown displays, dispatches room data to the
  # RoomWindow, and handles prompt resize.
  #
  # @param event_bus [EventBus] the event bus to subscribe to
  # @return [void]
  def subscribe_to_events(event_bus)
    EventBridge.new(self).subscribe(event_bus)
  end

  # Load a layout by ID from the LAYOUT constant and rebuild all windows.
  #
  # The server read thread reads the handler hashes, so call this before
  # that thread starts or inside {CursesRenderer.synchronize}, which the
  # server thread holds while it processes a line. Text, indicator,
  # progress, and countdown windows whose keys appear in the new layout are
  # reused rather than recreated, preserving their content buffers. A
  # reused indicator, progress bar or countdown is placed where the new
  # layout puts it and drawn again there at once; a reused text window
  # keeps its place until the next {#resize}. Every other window from the
  # previous layout, of any window class, is closed and removed from its
  # class list and from SCROLL_WINDOW.
  #
  # Each window built from a BaseWindow subclass gets the element's
  # {WindowLayout} as its +layout+, which {#resize} places it by.
  #
  # @param layout_id [String] key into the global LAYOUT hash
  # @return [void]
  def load_layout(layout_id)
    @layout_loader.load(layout_id)
  end

  # Point each handler hash (stream, indicator, progress, countdown, room)
  # at a new, empty hash. The old hashes are left as they were, so the
  # layout loader can still read the previous layout's windows from them.
  #
  # @return [void]
  # @api private
  def reset_registries
    @stream = {}
    @indicator = {}
    @progress = {}
    @countdown = {}
    @room = {}
  end

  # The previous layout's indicator windows keyed by value, for builder
  # procs during {#load_layout}; empty outside a layout reload.
  #
  # @return [Hash]
  # @api private
  def previous_indicator = @layout_loader.previous_indicator

  # The previous layout's stream windows keyed by stream name, for builder
  # procs during {#load_layout}; empty outside a layout reload.
  #
  # @return [Hash]
  # @api private
  def previous_stream = @layout_loader.previous_stream

  # The previous layout's progress windows keyed by value, for builder
  # procs during {#load_layout}; empty outside a layout reload.
  #
  # @return [Hash]
  # @api private
  def previous_progress = @layout_loader.previous_progress

  # The previous layout's countdown windows keyed by value, for builder
  # procs during {#load_layout}; empty outside a layout reload.
  #
  # @return [Hash]
  # @api private
  def previous_countdown = @layout_loader.previous_countdown

  # Windows from the previous layout that have not been reused. Builder
  # procs delete reused windows from this list; the layout loader closes
  # the rest after the layout loop.
  #
  # @return [Array<BaseWindow>]
  # @api private
  def old_windows = @layout_loader.old_windows

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

  # Remember the prompt the game sent last and fit the prompt indicator
  # and command window to it (see +fit_prompt+). Called on every
  # +:prompt_changed+ event.
  #
  # @param prompt_text [String] the prompt text (e.g. "H>")
  # @return [void]
  def fit_prompt_to(prompt_text)
    @prompt_text = prompt_text
    fit_prompt
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
