# frozen_string_literal: true

require_relative 'rules'

# Namespace for per-game text processing rules.
module Games
  # Several games' rules asked in turn: for each question the first game
  # with an answer (not nil) wins.
  #
  # Without --game ProfanityFE doesn't know which game it is connected to,
  # so GameTextProcessor uses DragonRealms and GemStone together, in that
  # order ({Games::BOTH_GAMES}). A line both games claim then gets
  # DragonRealms' answer (e.g. a "failed within ...!" death line).
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
    def logon(text, link_nouns: [])
      first_answer { |game| game.logon(text, link_nouns: link_nouns) }
    end

    # (see Games::Rules#stun_seconds)
    def stun_seconds(text)
      first_answer { |game| game.stun_seconds(text) }
    end

    # (see Games::Rules#spell_abbreviation)
    def spell_abbreviation(spell_name)
      first_answer { |game| game.spell_abbreviation(spell_name) }
    end

    # Whether any of the games marks the list as cut short.
    #
    # @param text [String] the component's text, tags removed and stripped
    # @return [Boolean]
    def room_list_cut_short?(text)
      @games.any? { |game| game.room_list_cut_short?(text) }
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
