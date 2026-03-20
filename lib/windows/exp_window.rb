# frozen_string_literal: true

# Experience/skills display window with sorted skill list and highlight support.

# Experience and skills display window.
#
# Parses incoming skill strings (name, ranks, percent, mindstate) and
# maintains a sorted skill map. Redraws the full skill list on every
# update, applying highlights via {HighlightProcessor}.
class ExpWindow < BaseWindow
  # Create a new experience window.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @skills = {}
    @open = false
    super
  end

  # Return the skill list as buffer entries for selection support.
  #
  # @return [Array<Array(String, Array)>] each skill's display text paired with empty colors
  def buffer_content
    @skills.values.map { |skill| [skill.to_s, []] }
  end

  # Delete the most recently targeted skill from the display.
  # Triggers a full redraw after removal.
  #
  # @return [void]
  def delete_skill
    return unless @current_skill

    @skills.delete(@current_skill)
    redraw
    @current_skill = ''
  end

  # Set the current skill key for the next {#add_string} call.
  #
  # @param skill [String] the skill identifier
  # @return [void]
  def set_current(skill)
    @current_skill = skill
  end

  # Parse a skill text line and store the result under the current skill key.
  # Expected format: "Skill Name:  123 45%  [ 12/34]"
  #
  # @param text [String] the skill text to parse
  # @param _line_colors [Array<Hash>] color regions (unused; highlights are recomputed)
  # @return [void]
  def add_string(text, _line_colors, indent: nil) # rubocop:disable Lint/UnusedMethodArgument
    match = text.match(%r{(?<name>.+):\s*(?<ranks>\d+) (?<percent>\d+)%  \[\s*(?<mindstate>\d+)/34\]})
    return unless match

    skill = Skill.new(match[:name].strip, match[:ranks], match[:percent], match[:mindstate])
    @skills[@current_skill] = skill
    redraw
    @current_skill = ''
  end

  # Redraw the full sorted skill list with highlight colors.
  #
  # @return [void]
  def redraw
    erase
    setpos(0, 0)

    @skills.sort.each do |_name, skill|
      skill_text = skill.to_s
      # Apply highlights using centralized processor
      skill_colors = HighlightProcessor.apply_highlights(skill_text, [])
      # Render using inherited add_line
      add_line(skill_text, skill_colors, newline: true)
    end
    noutrefresh
  end
end

BaseWindow.register_type('exp') do |height, width, top, left, element, wm|
  window = ExpWindow.new(height, width - 1, top, left)
  window.layout = [element.attributes['height'], element.attributes['width'], element.attributes['top'], element.attributes['left']]
  wm.stream['exp'] = window
  window
end
