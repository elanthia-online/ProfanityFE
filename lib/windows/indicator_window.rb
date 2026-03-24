# frozen_string_literal: true

# Status indicator display window (kneeling, hidden, bleeding, etc.).

# Single-label status indicator window.
#
# Displays a short label whose color changes based on a boolean or integer
# value. Supports optional highlight overlays via +label_colors+.
# Common uses: kneeling, hidden, stunned, bleeding status indicators.
class IndicatorWindow < BaseWindow
  # Default foreground colors: [off state, on state]
  DEFAULT_FG = %w[444444 ffff00].freeze

  # @return [Array<String>] foreground hex color codes indexed by value state
  attr_accessor :fg

  # @return [Array<String, nil>] background hex color codes indexed by value state
  attr_accessor :bg

  # @return [Array<Hash>, nil] optional highlight color regions for the label
  attr_accessor :label_colors

  # @return [String] the indicator label text
  attr_reader :label

  # @return [Boolean, Integer, nil] current indicator state
  attr_reader :value

  # Set the label text and trigger a redraw.
  #
  # @param str [String] new label text
  # @return [void]
  def label=(str)
    @label = str
    redraw
  end

  # Create a new indicator window with default colors.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @fg = DEFAULT_FG.dup
    @bg = [nil, nil]
    @label = '*'
    @label_colors = nil
    @value = nil
    super
  end

  # Update the indicator value and redraw if it changed.
  #
  # @param new_value [Boolean, Integer, nil] the new state value
  # @return [Boolean] true if the display was redrawn, false if unchanged
  def update(new_value)
    if new_value == @value
      false
    else
      @value = new_value
      redraw
    end
  end

  # Redraw the indicator label with the appropriate color for the current value.
  #
  # @return [Boolean] always true (the indicator was rendered)
  def redraw
    setpos(0, 0)
    clrtoeol

    # Use label_colors if set (for highlight support), otherwise use single-color mode
    if @label_colors&.any?
      # Determine base color based on value state
      base_fg = @value ? @fg[1] : @fg[0]
      base_bg = @value ? @bg[1] : @bg[0]

      # Create base color region spanning entire label, then overlay highlights.
      # Highlights before base so they win ties (sort_by is stable; equal-range
      # entries keep input order, and first non-nil fg wins).
      base_color = { start: 0, end: @label.length, fg: base_fg, bg: base_bg }
      colors = @label_colors + [base_color]
      add_line(@label, colors)
    elsif @value
      # Original single-color behavior
      if @value.is_a?(Integer)
        render_colored(@label, @fg[@value], @bg[@value])
      else
        render_colored(@label, @fg[1], @bg[1])
      end
    else
      render_colored(@label, @fg[0], @bg[0])
    end
    noutrefresh
    true
  end
end

BaseWindow.register_type('indicator') do |height, width, top, left, element, wm|
  if element.attributes['value'] && (window = wm.previous_indicator[element.attributes['value']])
    wm.previous_indicator[element.attributes['value']] = nil
    wm.old_windows.delete(window)
  else
    window = IndicatorWindow.new(height, width, top, left)
  end
  window.layout = [element.attributes['height'], element.attributes['width'], element.attributes['top'], element.attributes['left']]
  window.scrollok(false)
  window.label = element.attributes['label'] if element.attributes['label']
  window.fg = BaseWindow.parse_color_attrs(element, 'fg') if element.attributes['fg']
  window.bg = BaseWindow.parse_color_attrs(element, 'bg') if element.attributes['bg']
  wm.indicator[element.attributes['value']] = window if element.attributes['value']
  window.redraw
  window
end
