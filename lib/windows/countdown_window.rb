# frozen_string_literal: true

# Roundtime and casttime countdown display window.

# Countdown timer window for roundtime/casttime display.
#
# Computes remaining seconds from an end timestamp adjusted by server
# time offset. Renders a color-coded bar with primary and secondary
# countdown regions, updating only when the displayed value changes.
class CountdownWindow < BaseWindow
  # Default background colors: [inactive, primary countdown, secondary countdown]
  DEFAULT_BG = [nil, 'ff0000', '0000ff'].freeze

  # @return [String] label text displayed at the left of the bar
  attr_accessor :label

  # @return [Array<String>] foreground hex color codes indexed by bar region
  attr_accessor :fg

  # @return [Array<String, nil>] background hex color codes indexed by bar region
  attr_accessor :bg

  # @return [Numeric] Unix timestamp when the primary countdown expires
  attr_accessor :end_time

  # @return [Numeric] Unix timestamp when the secondary countdown expires
  attr_accessor :secondary_end_time

  # @return [Boolean, nil] whether the countdown is actively running
  attr_accessor :active

  # @return [Integer] current primary countdown value in seconds
  attr_reader :value

  # @return [Integer] current secondary countdown value in seconds
  attr_reader :secondary_value

  # Create a new countdown window with default color palette and zero timers.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @label = String.new
    @fg = []
    @bg = DEFAULT_BG.dup
    @active = nil
    @old_active = nil
    @end_time = 0
    @secondary_end_time = 0
    @value = 0
    @secondary_value = 0
    super
  end

  private

  # Render a text segment with explicit foreground/background colors.
  # Uses attrset instead of attron-with-block to ensure the background
  # attribute sticks on space characters (some curses implementations
  # only apply attron to non-space characters).
  #
  # @param text [String] text to render at current cursor position
  # @param fg_code [String, nil] foreground hex color
  # @param bg_code [String, nil] background hex color
  # @return [void]
  def draw_segment(text, fg_code, bg_code)
    attrset(Curses.color_pair(get_color_pair_id(fg_code, bg_code)))
    addstr(text)
    attrset(Curses::A_NORMAL)
  end

  public

  # Recalculate remaining time and redraw if the display changed.
  #
  # @return [Boolean] true if the display was redrawn, false if unchanged
  def update
    old_value = @value
    old_secondary_value = @secondary_value
    @value = [(@end_time.to_f - Time.now.to_f + $server_time_offset.to_f - COUNTDOWN_OFFSET).ceil, 0].max
    @secondary_value = [(@secondary_end_time.to_f - Time.now.to_f + $server_time_offset.to_f - COUNTDOWN_OFFSET).ceil,
                        0].max
    if old_value != @value || old_secondary_value != @secondary_value || @old_active != @active
      str = "#{@label}#{[@value, @secondary_value].max.to_s.rjust(maxx - @label.length)}"
      setpos(0, 0)
      if @value == 0 && @secondary_value == 0
        if @active
          str = "#{@label}#{'?'.rjust(maxx - @label.length)}"
          left_background_str = str[0, 1].to_s
          right_background_str = str[left_background_str.length, (@label.length + (maxx - @label.length))].to_s
          draw_segment(left_background_str, @fg[1], @bg[1])
          draw_segment(right_background_str, @fg[2], @bg[2])
        else
          draw_segment(str, @fg[0], @bg[0])
        end
      else
        left_background_str = str[0, @value].to_s
        secondary_background_str = str[left_background_str.length, (@secondary_value - @value)].to_s
        right_background_str = str[(left_background_str.length + secondary_background_str.length),
                                   (@label.length + (maxx - @label.length))].to_s
        draw_segment(left_background_str, @fg[1], @bg[1]) unless left_background_str.empty?
        draw_segment(secondary_background_str, @fg[2], @bg[2]) unless secondary_background_str.empty?
        draw_segment(right_background_str, @fg[3], @bg[3]) unless right_background_str.empty?
      end
      @old_active = @active
      noutrefresh
      true
    else
      false
    end
  end
end

BaseWindow.register_type('countdown') do |height, width, top, left, element, wm|
  if element.attributes['value'] && (window = wm.previous_countdown[element.attributes['value']])
    wm.previous_countdown[element.attributes['value']] = nil
    wm.old_windows.delete(window)
  else
    window = CountdownWindow.new(height, width, top, left)
  end
  window.layout = [element.attributes['height'], element.attributes['width'], element.attributes['top'], element.attributes['left']]
  window.scrollok(false)
  window.label = element.attributes['label'] if element.attributes['label']
  window.fg = BaseWindow.parse_color_attrs(element, 'fg') if element.attributes['fg']
  window.bg = BaseWindow.parse_color_attrs(element, 'bg') if element.attributes['bg']
  wm.countdown[element.attributes['value']] = window if element.attributes['value']
  window.update
  window
end
