# frozen_string_literal: true

require_relative 'safe_arithmetic'

# Where a layout puts a window, as the layout file writes it: four
# dimension expressions such as +"lines-2"+ or +"cols/3+1"+, kept
# unevaluated so the window can be placed again whenever the terminal
# changes size.
#
# @example
#   layout = WindowLayout.new(height: 'lines-1', width: 'cols/2', top: '0', left: 'cols/2')
#   layout.geometry # on a 24x80 terminal
#   #=> #<data WindowLayout::Geometry height=23, width=40, top=0, left=40>
#
# @!attribute [r] height
#   @return [String] expression for the window's height in rows
# @!attribute [r] width
#   @return [String] expression for the window's width in columns
# @!attribute [r] top
#   @return [String] expression for the screen row of the window's top edge
# @!attribute [r] left
#   @return [String] expression for the screen column of the window's left edge
WindowLayout = Data.define(:height, :width, :top, :left) do
  # The layout of a +<window>+ element in a layout file.
  #
  # @param element [REXML::Element] the element, with height, width, top
  #   and left attributes
  # @return [WindowLayout]
  def self.from_element(element)
    new(height: element.attributes['height'], width: element.attributes['width'],
        top: element.attributes['top'], left: element.attributes['left'])
  end

  # Evaluate a dimension expression to an integer, substituting the
  # current terminal size for the tokens "lines" and "cols".
  #
  # @param expression [String] dimension expression (e.g. "lines-2", "cols/3")
  # @return [Integer] the value (see {SafeArithmetic.evaluate} for how
  #   malformed expressions evaluate)
  def self.evaluate(expression)
    SafeArithmetic.evaluate(expression.gsub('lines', Curses.lines.to_s).gsub('cols', Curses.cols.to_s))
  end

  # Evaluate all four expressions for the current terminal size, in the
  # order height, width, top, left.
  #
  # @return [Geometry]
  def geometry
    self.class::Geometry.new(height: self.class.evaluate(height), width: self.class.evaluate(width),
                             top: self.class.evaluate(top), left: self.class.evaluate(left))
  end

  # Size and place a window where this layout puts it on the current
  # terminal. Sizes are raised to at least one row and one column and
  # positions to at least 0, since ncurses crashes on smaller ones. A
  # window whose top-left corner would be off the screen is left as it is.
  #
  # @param window [Curses::Window] the window to resize and move
  # @param right_margin [Integer] columns of the layout's width to leave
  #   unused at the window's right
  # @return [Boolean] true if the window was resized and moved, false if
  #   it was left as it is
  def place(window, right_margin: 0)
    size = geometry
    height = [size.height, 1].max
    width = [size.width - right_margin, 1].max
    top = [size.top, 0].max
    left = [size.left, 0].max
    return false unless top < Curses.lines && left < Curses.cols

    window.resize(height, width)
    window.move(top, left)
    true
  end
end

# A {WindowLayout} evaluated for one terminal size.
#
# @!attribute [r] height
#   @return [Integer] height in rows
# @!attribute [r] width
#   @return [Integer] width in columns
# @!attribute [r] top
#   @return [Integer] screen row of the top edge
# @!attribute [r] left
#   @return [Integer] screen column of the left edge
WindowLayout::Geometry = Data.define(:height, :width, :top, :left)
