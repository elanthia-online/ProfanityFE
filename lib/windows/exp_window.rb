# frozen_string_literal: true

require_relative '../streams'
require_relative 'stream_window'

# Experience/skills display window with sorted skill list and highlight support.

# Experience and skills display window.
#
# Parses incoming skill strings (name, ranks, percent, mindstate and,
# in the DragonRealms form, learning rate) and
# maintains a sorted skill map. Redraws the full skill list on every
# update, applying highlights via {HighlightProcessor}.
class ExpWindow < BaseWindow
  include StreamWindow

  # The layout's last column is left blank, both when the window is built
  # and when it is resized, so the window doesn't widen on resize.
  #
  # @return [Integer]
  def self.right_margin
    1
  end

  # Resized after text and tabbed windows (see {BaseWindow.resize_order}).
  #
  # @return [Integer]
  def self.resize_order
    30
  end

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

  # An exp component closed: delete the skill it named from the display,
  # so an empty component (no skill line since {#component_opened})
  # removes the skill. Triggers a full redraw after removal.
  #
  # @return [void]
  def component_closed
    return unless @current_skill

    @skills.delete(@current_skill)
    redraw
    @current_skill = ''
  end

  # An exp component opened: set the current skill key for the next
  # {#add_string} call.
  #
  # @param skill [String] the skill identifier
  # @return [void]
  def component_opened(skill)
    @current_skill = skill
  end

  # A skill line in the "[mindstate/34]" form: "Skill Name:  123 45%  [ 12/34]".
  BRACKET_SKILL = %r{(?<name>.+):\s*(?<ranks>\d+) (?<percent>\d+)%  \[\s*(?<mindstate>\d+)/34\]}

  # A skill line as DragonRealms sends it: the mindstate is one or two
  # words and the learning rate follows it,
  # e.g. "   Parry Ability: 1709 59% mind lock     0.37".
  DR_SKILL = /(?<name>.+):\s*(?<ranks>\d+) (?<percent>\d+)% (?<mindstate>[a-z]+(?: [a-z]+)*)\s+(?<rate>\d+(?:\.\d+)?)/

  # Parse a skill text line and store the result under the current skill key.
  # Accepts the {BRACKET_SKILL} and {DR_SKILL} forms; any other text (the
  # favor, TDP, rested-exp and sleep components) is ignored.
  #
  # @param text [String] the skill text to parse
  # @param _line_colors [Array<Hash>] color regions (unused; highlights are recomputed)
  # @param indent [Boolean, nil] unused; accepted like every stream window's +add_string+
  # @return [void]
  def add_string(text, _line_colors = [], indent: nil) # rubocop:disable Lint/UnusedMethodArgument
    skill = parse_skill(text)
    return unless skill

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

  # Draw the window again from its current state: the same as {#redraw}
  # (see {BaseWindow#repaint}).
  #
  # @return [void]
  def repaint
    redraw
  end

  private

  # @param text [String] the skill text
  # @return [Skill, nil] the parsed skill, or nil when the text is not a skill line
  def parse_skill(text)
    if (match = text.match(BRACKET_SKILL))
      Skill.new(match[:name].strip, match[:ranks], match[:percent], match[:mindstate])
    elsif (match = text.match(DR_SKILL))
      Skill.new(match[:name].strip, match[:ranks], match[:percent], match[:mindstate], rate: match[:rate])
    end
  end
end

BaseWindow.register_type('exp') do |height, width, top, left, _element, wm|
  window = ExpWindow.new(height, width - ExpWindow.right_margin, top, left)
  wm.stream[Streams::EXP] = window
  window
end
