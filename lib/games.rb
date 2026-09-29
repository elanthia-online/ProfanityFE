# frozen_string_literal: true

require_relative 'games/rules'
require_relative 'games/dragonrealms'
require_relative 'games/gemstone'
require_relative 'games/combined_rules'

# Namespace for per-game text processing rules.
module Games
  # Both games' rules, DragonRealms first: used when the game isn't known
  # (no --game).
  BOTH_GAMES = CombinedRules.new(DragonRealms, GemStone)

  # Each game's rules by the start of its game code. Lich's codes are DR,
  # DRT, DRF (DragonRealms) and GS4, GSX, GST, GSF (GemStone); case is
  # ignored.
  RULES_BY_CODE = {
    /\ADR/i => DragonRealms,
    /\AGS/i => GemStone,
  }.freeze

  # Whether {rules_for} knows +code+.
  #
  # @param code [String] a game code, e.g. "DR" or "gs4"
  # @return [Boolean]
  def self.known_code?(code)
    RULES_BY_CODE.keys.any? { |pattern| code.match?(pattern) }
  end

  # The rules for a game code (--game).
  #
  # @param code [String, nil] a game code, e.g. "DR" or "GS4"; nil when the
  #   game isn't known
  # @return [Games::Rules] that game's rules; {BOTH_GAMES} for nil
  # @raise [ArgumentError] for a code no game starts with
  def self.rules_for(code)
    return BOTH_GAMES if code.nil?

    RULES_BY_CODE.each { |pattern, rules| return rules if code.match?(pattern) }
    raise ArgumentError, "unknown game code: #{code.inspect}"
  end
end
