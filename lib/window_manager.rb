# frozen_string_literal: true

require_relative 'window_layout'
require_relative 'layout_loader'
require_relative 'event_bridge'
require_relative 'clock'
require_relative 'shared_state'

# Manages Curses window creation, layout loading, and handler hash access
# for the profanity terminal UI.

# Manages window creation, layout loading, and handler hash access.
#
# Owns the six handler hashes (stream, indicator, progress, countdown,
# effects, room) that map string keys to their corresponding window objects, plus
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

  # @!attribute [r] command_window
  #   @return [Curses::Window, nil] the command-line window, created by the
  #     first layout that has one (see {#install_command_window}); nil
  #     until then
  # @!attribute [r] command_window_layout
  #   @return [WindowLayout, nil] where the current layout puts the command
  #     window; nil until a layout has one

  # The clock read by the windows this manager builds and by stun
  # countdowns.
  #
  # @return [Clock]
  attr_reader :clock

  # The state the windows this manager builds read their settings from:
  # the room window reads whether links are on ({RoomWindow#shared_state}).
  #
  # @return [SharedState]
  attr_reader :shared_state

  # Create a new window manager with empty handler hashes.
  #
  # @param clock [Clock] handed to the windows the layout builds
  # @param shared_state [SharedState] handed to the windows the layout
  #   builds that follow a setting of it
  # @return [WindowManager]
  def initialize(clock: Clock.new, shared_state: SharedState.new)
    @clock = clock
    @shared_state = shared_state
    @stream = {}
    @indicator = {}
    @progress = {}
    @countdown = {}
    @effects = {}
    @room = {}
    @command_window = nil
    @command_window_layout = nil
    @prompt_text = nil
    @layout_loader = LayoutLoader.new(self)
  end

  # Returns the live stream handler hash mapping stream names to window objects.
  #
  # @return [Hash{String => TextWindow, TabbedTextWindow, ExpWindow, PercWindow, SinkWindow}]
  #   the stream handler hash (not a copy): a {StreamWindow} per stream, or
  #   the {SinkWindow} that swallows it
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

  # Returns the live effects handler hash. {EventBridge} hands every
  # +:effects_update+ event to each window in it, and the application
  # ticks each one ({EffectsWindow#tick}) to run its countdowns.
  #
  # @return [Hash<String, EffectsWindow>] the effects handler hash (not a
  #   copy), keyed by the +value+ of the layout element (default "effects")
  # @note Returns the live hash, not a copy. Mutations affect effects display.
  attr_reader :effects

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
  # server thread holds while it processes a line. A window of the
  # previous layout is reused, with what it shows, by an element of its
  # class that serves one of its keys: a text window for any of its
  # streams, a tabbed window for any of its tabs (it keeps the lines of
  # the tabs the element still lists; see {TabbedTextWindow#keep_tabs}),
  # the exp, spell and room windows for their stream, and indicators,
  # progress bars and countdowns for their value. The element's other
  # attributes (buffer size, timestamps, label, colors, presets) are
  # applied to it. A reused window is placed where the new layout puts it
  # and drawn again there at once, except a text window, which keeps its
  # place until the next {#resize}. Every other window from the previous
  # layout, of any window class, is closed and removed from its class list
  # and from SCROLL_WINDOW.
  #
  # Each window built from a BaseWindow subclass gets the element's
  # {WindowLayout} as its +layout+, which {#resize} places it by. An
  # element whose window doesn't fit on the terminal now is not built;
  # {#resize} builds it once it fits.
  #
  # @param layout_id [String] key into the global LAYOUT hash
  # @return [void]
  def load_layout(layout_id)
    @layout_loader.load(layout_id)
  end

  # Make the next window of the switch-window cycle (SCROLL_WINDOW) the
  # current one, the +switch_current_window+ key action, and tell the
  # layout loader that the user chose the current window, so a window
  # built later doesn't take it over (see
  # {LayoutLoader#build_skipped_windows}). With no window in the cycle,
  # only the loader is told.
  #
  # @return [void]
  def switch_current_window
    SCROLL_WINDOW[0]&.set_active(false)
    SCROLL_WINDOW.rotate!
    SCROLL_WINDOW[0]&.set_active(true)
    @layout_loader.current_window_switched
  end

  # Point each handler hash (stream, indicator, progress, countdown, effects, room)
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
    @effects = {}
    @room = {}
  end

  # Take a window of the previous layout for a builder proc to reuse,
  # during {#load_layout} (see {LayoutLoader#claim}).
  #
  # @param registry [Symbol] the handler hash the window was in
  #   (+:stream+, +:indicator+, +:progress+, +:countdown+, +:effects+ or +:room+)
  # @param keys [String, Array<String>, nil] the keys the new window
  #   serves, in the order to try them
  # @param window_class [Class] the class the window must be
  # @return [BaseWindow, nil] the window to reuse, or nil to build one
  # @api private
  def claim_window(registry, keys, window_class)
    @layout_loader.claim(registry, keys, window_class)
  end

  # Take the command window a layout asks for. The first layout creates
  # it with the block; later layouts keep that window, which the command
  # buffer draws into, and only replace its layout. The window is kept on
  # top of any window that overlaps it (see {OnTopWindow}), and so is the
  # current layout's prompt indicator, the rest of the command line.
  #
  # @param layout [WindowLayout] where the layout puts the command line
  # @yield once, only when there is no command window yet
  # @yieldreturn [Curses::Window] a new command window, called only when
  #   there isn't one yet
  # @return [Curses::Window] the command window
  # @api private
  def install_command_window(layout)
    @command_window ||= yield.extend(OnTopWindow).keep_on_top_with { [@indicator['prompt']] }
    @command_window_layout = layout
    @command_window
  end

  # Resize all windows to match the current terminal dimensions.
  #
  # First, each window of the current layout that didn't fit on the
  # terminal when the layout loaded (off the screen, no rows or columns,
  # or a text or tabbed window one column wide) and fits now is built, as
  # the layout would have built it at load at this size (see
  # {LayoutLoader#build_skipped_windows}); a text window built this way
  # starts filled with blank lines, as a layout's new text windows do.
  # The others wait for a later resize. A window, once built, stays
  # built when the terminal shrinks again.
  #
  # Every registered window class ({BaseWindow.window_classes}), in
  # {BaseWindow.window_classes_in_resize_order}, resizes its own windows
  # ({BaseWindow.resize_all}): each is placed from its stored layout
  # expressions and redrawn as its class needs. Then the command window
  # is placed from its layout. Triggers a full Curses screen update
  # afterward. Nothing is resized while the terminal is under 3 lines or
  # 10 columns.
  #
  # Text and tabbed windows re-wrap their stored lines to the new width
  # and repaint (see {LineBuffered#rewrap}): a tabbed window re-wraps its
  # shown tab now and each hidden tab when it is next shown. The current
  # scroll window keeps its active scrollbar; every other text or tabbed
  # window's scrollbar is left blank.
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

      # Windows of the layout that didn't fit when it loaded and fit now
      # are built first, so they are placed and drawn with the rest.
      @layout_loader.build_skipped_windows.each do |built|
        built.fill_with_blank_lines if built.is_a?(TextWindow)
      end

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

# Keeps a window on top of the windows that overlap it: whatever the
# layout says, their text never shows in its cells. The command window is
# extended with it (see {WindowManager#install_command_window}).
#
# ncurses' wnoutrefresh copies to the screen only the lines a window
# changed since it was last refreshed. Every screen update refreshes the
# command window last, so that the cursor ends on the command line (see
# {CommandBuffer#flush_screen}), but an unchanged command window copied
# nothing: a window that wrote over the command line's cells earlier in
# the same update (main scrolling under it at 80x24, say) kept them on the
# screen until a resize redrew the command line. A window extended with
# this module marks all of its lines changed before each refresh, so it
# is copied whole and wins every cell it covers. The cost is one copy of
# the window's cells per refresh; doupdate sends the terminal only the
# cells that differ from what it already shows, so nothing more is sent
# where no window overlaps.
#
# Windows that belong with it (the prompt indicator, see
# {#keep_on_top_with}) are copied whole just before it at each refresh,
# so they stay on top too and the cursor still ends in this window.
module OnTopWindow
  # Keep other windows on top along with this one.
  #
  # @param windows [Proc] returns the windows (see the block)
  # @yieldreturn [Array<Curses::Window, nil>] the windows, asked for at
  #   each refresh (so a window replaced by a new layout is followed); nil
  #   entries are skipped
  # @return [self]
  def keep_on_top_with(&windows)
    @kept_with = windows
    self
  end

  # Copy the whole window to the next screen update, not just its changed
  # lines (see the module docs), after the windows kept on top with it,
  # and leave the cursor in it.
  #
  # @return [void]
  def noutrefresh
    copy_kept_with
    touch
    super
  end

  # Copy the whole window to the screen at once, as {#noutrefresh} does,
  # then update the terminal.
  #
  # @return [void]
  def refresh
    copy_kept_with
    touch
    super
  end

  # Whether a screen cell shows this window or a window kept on top with
  # it, whatever window the layout puts under it. A mouse press there
  # belongs to the command line, not to the hidden window (see
  # {MouseController}).
  #
  # @param screen_y [Integer] the cell's row on the screen
  # @param screen_x [Integer] the cell's column on the screen
  # @return [Boolean]
  def covers?(screen_y, screen_x)
    [self, *@kept_with&.call].any? do |window|
      window &&
        screen_y >= window.begy && screen_y < window.begy + window.maxy &&
        screen_x >= window.begx && screen_x < window.begx + window.maxx
    end
  end

  private

  # Copy each window kept on top with this one (see {#keep_on_top_with})
  # whole to the next screen update.
  #
  # @return [void]
  def copy_kept_with
    @kept_with&.call&.each do |window|
      next unless window

      window.touch
      window.noutrefresh
    end
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
