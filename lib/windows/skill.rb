# frozen_string_literal: true

# Skill data object for experience tracking in the {ExpWindow}.

# Value object representing a single skill's training state.
#
# Stores the skill name, rank count, rank percentage, current mindstate
# and, for DragonRealms lines, the learning rate. Provides a fixed-width
# {#to_s} suitable for columnar display in {ExpWindow}.
class Skill
  # Create a new Skill snapshot.
  #
  # @param name [String] skill name (e.g. "Evasion")
  # @param ranks [Integer, String] total ranks earned
  # @param percent [Integer, String] percentage toward next rank
  # @param mindstate [Integer, String] current mindstate: a number (0-34),
  #   or the mindstate word(s) DragonRealms sends (e.g. "mind lock")
  # @param rate [String, nil] learning rate as sent (e.g. "0.37"), or nil
  #   for the "[n/34]" form
  def initialize(name, ranks, percent, mindstate, rate: nil)
    @name = name
    @ranks = ranks
    @percent = percent
    @mindstate = mindstate
    @rate = rate
  end

  # Format the skill as a fixed-width columnar string. A skill with a rate
  # shows its mindstate word(s) padded to the widest ("nearly locked"), then
  # the rate, as DragonRealms lays out the line.
  #
  # @return [String] e.g. " Evasion:  123 45% [12/34]" or
  #   "     Bow: 1534 07% deliberative  0.27"
  def to_s
    return format('%8s:%5d %2s%% [%2s/34]', @name, @ranks, @percent, @mindstate) unless @rate

    format('%8s:%5d %2s%% %-13s %s', @name, @ranks, @percent, @mindstate, @rate)
  end
end
