# frozen_string_literal: true

require_relative 'selection_manager'
require_relative 'window_layout'

# Turns a layout from the settings file into windows.
#
# {WindowManager#load_layout} delegates here. The loader evaluates each
# +<window>+ element's geometry, calls the builder registered for its
# class ({BaseWindow.type_registry}) with the {WindowManager}, and then
# closes every window of the previous layout that no builder reused.
#
# The {WindowManager} keeps the handler hashes the builders fill. While a
# layout loads, the loader holds the previous layout's hashes and windows,
# and a builder takes the previous window it can reuse with {#claim}
# (through {WindowManager#claim_window}), so no other builder reuses it
# and it isn't closed. The loader then places each reused window where
# the new layout puts it and draws it again there
# ({BaseWindow#place_after_reuse}).
#
# An element whose window doesn't fit on the terminal when the layout
# loads (off the screen, no rows or columns, or too narrow for its
# builder) is not built then. The loader keeps it, and
# {#build_skipped_windows} builds it once the terminal is large enough,
# as the layout would have built it at load at that size.
#
# @example
#   loader = LayoutLoader.new(window_manager)
#   loader.load('default')
class LayoutLoader
  # The handler hashes of {WindowManager} a builder can {#claim} a window
  # from.
  REGISTRIES = %i[stream indicator progress countdown room].freeze

  # @param window_manager [WindowManager] owns the handler hashes, and is
  #   handed to every builder
  # @return [LayoutLoader]
  def initialize(window_manager)
    @wm = window_manager
    forget_previous_layout
    forget_layout_order
  end

  # Load a layout by ID from the LAYOUT constant and rebuild all windows.
  # See {WindowManager#load_layout} for what is reused and what is closed.
  # The elements whose windows don't fit on the terminal are kept for
  # {#build_skipped_windows}, in place of the previous layout's.
  #
  # An unknown ID warns and changes nothing.
  #
  # @param layout_id [String] key into the global LAYOUT hash
  # @return [void]
  def load(layout_id)
    xml = LAYOUT[layout_id]
    unless xml
      warn "Warning: layout '#{layout_id}' not found in LAYOUT (available: #{LAYOUT.keys.join(', ')})"
      return
    end

    @old_windows = BaseWindow.all_windows
    @previous_windows = @old_windows.dup
    @previous = REGISTRIES.to_h { |registry| [registry, @wm.public_send(registry)] }
    @wm.reset_registries
    forget_layout_order

    xml.elements.each { |element| build(element, @position += 1) if element.name == 'window' }

    @old_windows.each { |window| close_window(window) }
    forget_previous_layout

    SCROLL_WINDOW[0]&.set_active(true)

    CursesRenderer.doupdate
  end

  # Build the windows of the current layout that didn't fit on the
  # terminal when it loaded and fit now, as {#load} builds them: each
  # element's builder runs with the element's geometry for the current
  # terminal, and a BaseWindow gets the element's {WindowLayout}. Those
  # that still don't fit are kept for a later call.
  #
  # The result is what the layout would have built at load on a terminal
  # of this size, for the windows already built too:
  # - a stream or value two elements serve goes to the one listed later
  #   in the layout, so a window built now takes over what an earlier
  #   element's window took, and nothing a later element's window took;
  # - a text or tabbed window joins the switch-window (Tab) cycle after
  #   the window the layout lists before it, so the cycle keeps the
  #   layout's order, and the current window stays current (with no
  #   current window, the first one built becomes it).
  #
  # @return [Array<BaseWindow>] the windows built, in layout order (empty
  #   when none was)
  def build_skipped_windows
    current = SCROLL_WINDOW[0]
    built = []
    @skipped = @skipped.reject do |position, element|
      window = build_in_order(element, position)
      built << window if window.is_a?(BaseWindow)
      window
    end
    SCROLL_WINDOW[0].set_active(true) if current.nil? && SCROLL_WINDOW[0]
    built
  end

  # Take a window of the previous layout for a builder to reuse: trying
  # +keys+ in order, the first window of the previous layout's +registry+
  # hash that one of them maps to and that is a +window_class+ (not a
  # subclass). Every key of that hash that maps to it is dropped, so no
  # later builder reuses it too, and it isn't closed after the layout
  # loads. Outside {#load}, and when no key maps to such a window, there
  # is nothing to take.
  #
  # @param registry [Symbol] one of {REGISTRIES}
  # @param keys [String, Array<String>, nil] the keys (streams, values)
  #   the new window serves, in the order to try them
  # @param window_class [Class] the class the window must be
  # @return [BaseWindow, nil] the window to reuse, or nil to build one
  def claim(registry, keys, window_class)
    previous = @previous.fetch(registry)
    window = Array(keys).map { |key| previous[key] }.find { |old| old.instance_of?(window_class) }
    return unless window

    previous.delete_if { |_key, old| old.equal?(window) }
    @old_windows.delete(window)
    window
  end

  private

  # Build the window one +<window>+ element describes. A +sink+ window
  # swallows the streams in its +value+. Any other class is built by its
  # registered builder, if it has one, when its geometry is on screen;
  # a BaseWindow gets the element's {WindowLayout} as its +layout+, and
  # one reused from the previous layout is placed and drawn again there.
  # An element of a registered class whose window doesn't fit (see
  # {#build_window}) is kept for {#build_skipped_windows}.
  #
  # @param element [CachedElement] a +<window>+ element of the layout
  # @param position [Integer] the element's place among the layout's
  #   +<window>+ elements, from 1
  # @return [void]
  def build(element, position)
    if element.attributes['class'] == 'sink'
      sink = SinkWindow.new
      @positions[sink] = position
      element.attributes['value']&.split(',')&.each do |str|
        @wm.stream[str.strip] = sink
      end
      return
    end

    window = build_window(element)
    if window
      @positions[window] = position
    elsif BaseWindow.type_registry.key?(element.attributes['class'])
      @skipped << [position, element]
    end
    window.place_after_reuse if window.is_a?(BaseWindow) && @previous_windows.any? { |previous| previous.equal?(window) }
  end

  # Run the builder of the element's class with the element's geometry
  # for the current terminal, if the window fits there: its top-left
  # corner on the screen, at least one row and one column. A BaseWindow
  # the builder returns gets the element's {WindowLayout} as its +layout+.
  #
  # @param element [CachedElement] a +<window>+ element of the layout, of
  #   any class but +sink+
  # @return [BaseWindow, Curses::Window, nil] what the builder returned
  #   (the command window is a plain Curses::Window); nil when the window
  #   doesn't fit, the builder refused it (a text or tabbed window one
  #   column wide), or the class has no builder
  def build_window(element)
    layout = WindowLayout.from_element(element)
    size = layout.geometry

    return unless (size.height > 0) && (size.width > 0) && (size.top >= 0) && (size.left >= 0) &&
                  (size.top < Curses.lines) && (size.left < Curses.cols)

    builder = BaseWindow.type_registry[element.attributes['class']]
    window = builder&.call(size.height, size.width, size.top, size.left, element, @wm)
    window.layout = layout if window.is_a?(BaseWindow)
    window
  end

  # Build a skipped element's window (see {#build_window}) after the
  # layout loaded, and give it only what the layout gives it at load
  # (see {#build_skipped_windows}): the keys no element listed later
  # took, and its place in the switch-window cycle.
  #
  # @param element [CachedElement] the skipped +<window>+ element
  # @param position [Integer] the element's place in the layout
  # @return [BaseWindow, Curses::Window, nil] what {#build_window}
  #   returned; nil when the window still doesn't fit
  def build_in_order(element, position)
    taken = REGISTRIES.to_h { |registry| [registry, @wm.public_send(registry).dup] }
    window = build_window(element)
    return unless window

    @positions[window] = position
    give_back_keys_listed_later(taken, position)
    take_place_in_scroll_cycle(window, position) if SCROLL_WINDOW.last.equal?(window)
    window
  end

  # After a skipped element's window was built, hand each key it took
  # from a window of an element listed later in the layout back to that
  # window, as at load, where the later element would have taken it last.
  #
  # @param taken [Hash{Symbol => Hash}] each handler hash as it was
  #   before the builder ran
  # @param position [Integer] the built element's place in the layout
  # @return [void]
  def give_back_keys_listed_later(taken, position)
    taken.each do |registry, before|
      now = @wm.public_send(registry)
      before.each do |key, window|
        now[key] = window if !now[key].equal?(window) && @positions.fetch(window, 0) > position
      end
    end
  end

  # Move a text or tabbed window its builder appended to the end of the
  # switch-window cycle (SCROLL_WINDOW) to just after the window the
  # layout lists before it (the last one listed, for the first window),
  # as at load, where the cycle follows the layout. SCROLL_WINDOW[0], the
  # current window, never moves.
  #
  # @param window [BaseWindow] the window just built
  # @param position [Integer] its element's place in the layout
  # @return [void]
  def take_place_in_scroll_cycle(window, position)
    SCROLL_WINDOW.pop
    return SCROLL_WINDOW.push(window) if SCROLL_WINDOW.empty?

    order = SCROLL_WINDOW.map { |other| @positions.fetch(other, 0) }
    before = order.select { |other| other < position }.max || order.max
    SCROLL_WINDOW.insert(order.index(before) + 1, window)
  end

  # Close a window the new layout did not reuse, and remove it from every
  # list that could still hit-test, repaint, or scroll it, and from the
  # mouse selection (see {SelectionManager.forget_window}).
  #
  # @param window [BaseWindow] a window from the previous layout
  # @return [void]
  def close_window(window)
    window.class.unregister_instance(window)
    SCROLL_WINDOW.delete(window)
    SelectionManager.forget_window(window)
    window.scrollbar&.close if window.respond_to?(:scrollbar)
    window.close
  end

  # Drop the previous-layout references the builders used during
  # {#load}, so closed windows are not kept reachable.
  #
  # @return [void]
  def forget_previous_layout
    @old_windows = []
    @previous_windows = []
    @previous = REGISTRIES.to_h { |registry| [registry, {}] }
  end

  # Forget the current layout's order: the elements left to build and
  # each window's place in the layout (see {#build_skipped_windows}).
  #
  # @return [void]
  def forget_layout_order
    @position = 0
    @skipped = []
    @positions = {}.compare_by_identity
  end
end
