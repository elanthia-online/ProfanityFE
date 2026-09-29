# frozen_string_literal: true

require_relative 'rules'

# Namespace for per-game text processing rules.
module Games
  # Several games' rules asked in turn: for each question the first game
  # with an answer (not nil) wins.
  #
  # ProfanityFE doesn't know which game it is connected to, so
  # GameTextProcessor uses DragonRealms and GemStone together, in that
  # order. A line both games claim therefore gets DragonRealms' answer
  # (e.g. a "failed within ...!" death line).
  #
  # @example
  #   rules = Games::CombinedRules.new(Games::DragonRealms, Games::GemStone)
  #   rules.logon(' * Mahtra joins the adventure.')  #=> ["Mahtra", "007700"]
  class CombinedRules
    include Rules

    # The games asked, first to last.
    #
    # @return [Array<Games::Rules>]
    attr_reader :games

    # @param games [Array<Games::Rules>] the games' rules, first asked first
    def initialize(*games)
      @games = games.freeze
    end

    # (see Games::Rules#death_summary)
    def death_summary(text)
      first_answer { |game| game.death_summary(text) }
    end

    # (see Games::Rules#logon)
    def logon(text)
      first_answer { |game| game.logon(text) }
    end

    # (see Games::Rules#stun_seconds)
    def stun_seconds(text)
      first_answer { |game| game.stun_seconds(text) }
    end

    # (see Games::Rules#spell_abbreviation)
    def spell_abbreviation(spell_name)
      first_answer { |game| game.spell_abbreviation(spell_name) }
    end

    private

    # The first game's non-nil answer.
    #
    # @yieldparam game [Games::Rules]
    # @yieldreturn [Object, nil] the game's answer
    # @return [Object, nil] the first answer that isn't nil
    def first_answer
      @games.each do |game|
        answer = yield game
        return answer unless answer.nil?
      end
      nil
    end
  end
end
