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
# layout loads, the loader holds the previous layout's hashes and windows;
# builders reach them through the manager ({WindowManager#previous_stream}
# and friends) to reuse a window, and delete what they reuse from
# {#old_windows}. The loader then places each reused window where the new
# layout puts it and draws it again there ({BaseWindow#place_after_reuse}).
#
# @example
#   loader = LayoutLoader.new(window_manager)
#   loader.load('default')
class LayoutLoader
  # The previous layout's indicator windows keyed by value, during {#load};
  # empty otherwise.
  #
  # @return [Hash]
  attr_reader :previous_indicator

  # The previous layout's stream windows keyed by stream name, during
  # {#load}; empty otherwise.
  #
  # @return [Hash]
  attr_reader :previous_stream

  # The previous layout's progress windows keyed by value, during {#load};
  # empty otherwise.
  #
  # @return [Hash]
  attr_reader :previous_progress

  # The previous layout's countdown windows keyed by value, during {#load};
  # empty otherwise.
  #
  # @return [Hash]
  attr_reader :previous_countdown

  # Windows from the previous layout that have not been reused. Builders
  # delete reused windows from this list; the rest are closed after the
  # layout loop.
  #
  # @return [Array<BaseWindow>]
  attr_reader :old_windows

  # @param window_manager [WindowManager] owns the handler hashes, and is
  #   handed to every builder
  # @return [LayoutLoader]
  def initialize(window_manager)
    @wm = window_manager
    forget_previous_layout
  end

  # Load a layout by ID from the LAYOUT constant and rebuild all windows.
  # See {WindowManager#load_layout} for what is reused and what is closed.
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
    @previous_indicator = @wm.indicator
    @previous_stream = @wm.stream
    @previous_progress = @wm.progress
    @previous_countdown = @wm.countdown
    @wm.reset_registries

    xml.elements.each { |element| build(element) if element.name == 'window' }

    @old_windows.each { |window| close_window(window) }
    forget_previous_layout

    SCROLL_WINDOW[0]&.set_active(true)

    CursesRenderer.doupdate
  end

  private

  # Build the window one +<window>+ element describes. A +sink+ window
  # swallows the streams in its +value+. Any other class is built by its
  # registered builder, if it has one, when its geometry is on screen;
  # a BaseWindow gets the element's {WindowLayout} as its +layout+, and
  # one reused from the previous layout is placed and drawn again there.
  #
  # @param element [REXML::Element] a +<window>+ element of the layout
  # @return [void]
  def build(element)
    if element.attributes['class'] == 'sink'
      sink = SinkWindow.new
      element.attributes['value']&.split(',')&.each do |str|
        @wm.stream[str.strip] = sink
      end
      return
    end

    layout = WindowLayout.from_element(element)
    size = layout.geometry

    return unless (size.height > 0) && (size.width > 0) && (size.top >= 0) && (size.left >= 0) &&
                  (size.top < Curses.lines) && (size.left < Curses.cols)

    builder = BaseWindow.type_registry[element.attributes['class']]
    window = builder&.call(size.height, size.width, size.top, size.left, element, @wm)
    return unless window.is_a?(BaseWindow)

    window.layout = layout
    window.place_after_reuse if @previous_windows.any? { |previous| previous.equal?(window) }
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
    @previous_indicator = {}
    @previous_stream = {}
    @previous_progress = {}
    @previous_countdown = {}
  end
end
