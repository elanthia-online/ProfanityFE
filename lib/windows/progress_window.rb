# frozen_string_literal: true

# Health/mana/stamina progress bar display window.

# Progress bar window for health, mana, stamina, and similar gauges.
#
# Renders a single-row bar whose filled portion is proportional to
# +value / max_value+. Supports up to four color pairs (left fill,
# middle transition, right background, and zero-value) via the +fg+
# and +bg+ arrays.
class ProgressWindow < BaseWindow
  # Resized after indicators (see {BaseWindow.resize_order}).
  #
  # @return [Integer]
  def self.resize_order
    70
  end

  # Default background colors: [fill, empty]
  DEFAULT_BG = %w[0000aa 000055].freeze

  # @return [Array<String>] foreground hex color codes indexed by bar region
  attr_accessor :fg

  # @return [Array<String>] background hex color codes indexed by bar region
  attr_accessor :bg

  # @return [String] label text displayed at the left of the bar
  attr_accessor :label

  # @return [Integer] current value
  attr_reader :value

  # @return [Integer] maximum value (clamped to >= 1)
  attr_reader :max_value

  # Create a new progress bar window with default colors (100/100).
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @label = String.new
    @fg = []
    @bg = DEFAULT_BG.dup
    @value = 100
    @max_value = 100
    super
  end

  # Update the bar value and optionally the maximum.
  # Triggers a {#redraw} only when a value actually changes.
  #
  # @param new_value [Integer] the new current value
  # @param new_max_value [Integer, nil] the new maximum (kept unchanged when nil)
  # @return [Boolean] true if the display was redrawn, false if unchanged
  def update(new_value, new_max_value = nil)
    apply_changes(value: new_value, max: new_max_value)
  end

  # Apply a progress update: set whichever of the label, colors, value
  # and maximum it gives, then redraw once if anything changed, so a new
  # label or new colors show even when the value stays the same. A label,
  # color list or number equal to the current one is no change.
  #
  # @param changes [Hash] any of +:label+ (String), +:fg+ and +:bg+
  #   (Array<String, nil>), +:value+ (Integer) and +:max+ (Integer; nil
  #   keeps the current maximum)
  # @return [Boolean] true if the bar was redrawn
  def apply_changes(changes)
    changed = false
    %i[label fg bg].each do |attr|
      next unless changes.key?(attr) && changes[attr] != public_send(attr)

      public_send(:"#{attr}=", changes[attr])
      changed = true
    end
    new_value = changes.fetch(:value, @value)
    new_max_value = changes[:max] || @max_value
    if (new_value != @value) or (new_max_value != @max_value)
      @value = new_value
      @max_value = [new_max_value, 1].max
      changed = true
    end
    redraw if changed
    changed
  end

  # Redraw the progress bar using the current value, max, and color palette.
  #
  # @return [Boolean] always true (the bar was rendered)
  def redraw
    str = "#{@label}#{@value.to_s.rjust(maxx - @label.length)}"
    percent = [[(@value / @max_value.to_f), 0.to_f].max, 1].min
    if (@value == 0) and (fg[3] or bg[3])
      setpos(0, 0)
      render_colored(str, @fg[3], @bg[3])
    else
      left_str = str[0, (str.length * percent).floor].to_s
      if (@fg[1] or @bg[1]) and (left_str.length < str.length) and (((left_str.length + 0.5) * (1 / str.length.to_f)) < percent)
        middle_str = str[left_str.length, 1].to_s
      else
        middle_str = ''
      end
      right_str = str[(left_str.length + middle_str.length), (@label.length + (maxx - @label.length))].to_s
      setpos(0, 0)
      render_colored(left_str, @fg[0], @bg[0]) unless left_str.empty?
      render_colored(middle_str, @fg[1], @bg[1]) unless middle_str.empty?
      render_colored(right_str, @fg[2], @bg[2]) unless right_str.empty?
    end
    noutrefresh
    true
  end

  # Draw the window again from its current state: the same as {#redraw}
  # (see {BaseWindow#repaint}).
  #
  # @return [void]
  def repaint
    redraw
  end
end

BaseWindow.register_type('progress') do |height, width, top, left, element, wm|
  unless (window = wm.claim_window(:progress, element.attributes['value'], ProgressWindow))
    window = ProgressWindow.new(height, width, top, left)
  end
  window.scrollok(false)
  window.label = element.attributes['label'] if element.attributes['label']
  window.fg = BaseWindow.parse_color_attrs(element, 'fg') if element.attributes['fg']
  window.bg = BaseWindow.parse_color_attrs(element, 'bg') if element.attributes['bg']
  wm.progress[element.attributes['value']] = window if element.attributes['value']
  window.redraw
  window
end
