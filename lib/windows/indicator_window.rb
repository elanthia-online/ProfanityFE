# frozen_string_literal: true

# Status indicator display window (kneeling, hidden, bleeding, etc.).

# Single-label status indicator window.
#
# Displays a short label whose color changes based on a boolean or integer
# value. Supports optional highlight overlays via +label_colors+.
# Common uses: kneeling, hidden, stunned, bleeding status indicators.
class IndicatorWindow < BaseWindow
  # Resized after the room window, before progress bars and countdowns (see {BaseWindow.resize_order}).
  #
  # @return [Integer]
  def self.resize_order
    60
  end

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

  # Apply an indicator update: set whichever of the label, label colors
  # and value it gives, then redraw once if anything changed, so the
  # redraw sees all of them together. A label or value equal to the
  # current one is no change; label colors, when given, always are.
  #
  # @param changes [Hash] any of +:label+ (String), +:label_colors+
  #   (Array<Hash>, nil) and +:value+ (Boolean, Integer, nil)
  # @return [Boolean] true if the indicator was redrawn
  def apply_changes(changes)
    changed = false
    if changes.key?(:label) && @label != changes[:label]
      @label = changes[:label]
      changed = true
    end
    if changes.key?(:label_colors)
      @label_colors = changes[:label_colors]
      changed = true
    end
    if changes.key?(:value) && changes[:value] != @value
      @value = changes[:value]
      changed = true
    end
    redraw if changed
    changed
  end

  # Redraw the indicator label with the appropriate color for the current value.
  #
  # @return [Boolean] always true (the indicator was rendered)
  def redraw
    setpos(0, 0)
    clrtoeol

    index = color_index
    # Use label_colors if set (for highlight support), otherwise use single-color mode
    if @label_colors&.any?
      # Create base color region spanning entire label, then overlay highlights.
      # Highlights before base so they win ties (sort_by is stable; equal-range
      # entries keep input order, and first non-nil fg wins).
      base_color = { start: 0, end: @label.length, fg: @fg[index], bg: @bg[index] }
      colors = @label_colors + [base_color]
      add_line(@label, colors)
    else
      render_colored(@label, @fg[index], @bg[index])
    end
    noutrefresh
    true
  end

  # Index into {#fg}/{#bg} for the current value: an Integer is its own
  # index (0 is off), any other truthy value is 1 (on), false or nil 0.
  #
  # @return [Integer]
  private def color_index
    return @value if @value.is_a?(Integer)

    @value ? 1 : 0
  end

  # Draw the window again from its current state: the same as {#redraw}
  # (see {BaseWindow#repaint}).
  #
  # @return [void]
  def repaint
    redraw
  end
end

BaseWindow.register_type('indicator') do |height, width, top, left, element, wm|
  if element.attributes['value'] && (window = wm.previous_indicator[element.attributes['value']])
    wm.previous_indicator[element.attributes['value']] = nil
    wm.old_windows.delete(window)
    # Draw it at its new place and size, not the old layout's.
    window.resize(height, width)
    window.move(top, left)
  else
    window = IndicatorWindow.new(height, width, top, left)
  end
  window.scrollok(false)
  window.label = element.attributes['label'] if element.attributes['label']
  window.fg = BaseWindow.parse_color_attrs(element, 'fg') if element.attributes['fg']
  window.bg = BaseWindow.parse_color_attrs(element, 'bg') if element.attributes['bg']
  wm.indicator[element.attributes['value']] = window if element.attributes['value']
  window.redraw
  window
end
