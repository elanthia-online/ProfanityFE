# frozen_string_literal: true

# Namespace for per-game text processing rules.
module Games
  # What GameTextProcessor asks a game's rules. {Games::DragonRealms} and
  # {Games::GemStone} each answer for their own game; {Games::CombinedRules}
  # asks several games in turn.
  #
  # Every question returns nil when the line isn't one of the game's, so a
  # game answers only what it knows. Extending this module gives a game the
  # nil answers (these empty methods) for the questions it has no rules for.
  #
  # @example
  #   rules = Games::CombinedRules.new(Games::DragonRealms, Games::GemStone)
  #   rules.death_summary(' * Mahtra just bit the dust!')  #=> "Mahtra WL"
  module Rules
    # The shape of a character's name in a game line: a capital and then
    # lowercase letters.
    NAME = /[A-Z][a-z]+/

    # A pattern for the " * Name <message>" line a game sends when a
    # character arrives or leaves; it captures +name+ and the message as
    # +type+. Messages are tried in the order given.
    #
    # @param messages [Array<String>] the literal messages that follow the name
    # @return [Regexp]
    def self.logon_regexp(messages)
      /^\s\*\s(?<name>#{NAME.source}) (?<type>#{messages.map { |k| Regexp.escape(k) }.join('|')})/
    end

    # The death window entry for a line on the death stream, shown after the
    # time (e.g. "Mahtra" or "Mahtra WL").
    #
    # @param text [String] the line, tags removed
    # @return [String, nil] the entry; an empty string when the game hides
    #   the line; nil when it isn't one of the game's death lines
    def death_summary(text); end

    # Who arrived or left, and in which color, for a line on the logons
    # stream.
    #
    # @param text [String] the line, tags removed
    # @param link_nouns [Array<String>] the +noun+ of each link on the line
    #   that has one, in the order the links appear
    # @return [Array(String, String), Array(String, nil), nil] the
    #   character's name and the hex color of the time (nil when the line
    #   doesn't say whether the character arrived or left); nil when it
    #   isn't one of the game's logon lines
    def logon(text, link_nouns: []); end

    # How long a game line stuns the character, for the stun countdown.
    #
    # @param text [String] a game line, tags removed
    # @return [Numeric, nil] the stun in seconds; nil when the line doesn't
    #   stun
    def stun_seconds(text); end

    # The short name of a spell for the spell window.
    #
    # @param spell_name [String] the spell's name as sent (surrounding
    #   whitespace is ignored)
    # @return [String, nil] the short name; nil when the game has none for it
    def spell_abbreviation(spell_name); end

    # Whether a room component's list was cut short by the game, so it
    # doesn't hold the whole room: the room's inline line has the full
    # list, and fills the room window in its place.
    #
    # @param text [String] the component's text, tags removed and stripped
    # @return [Boolean, nil] true when the game marked the list as cut
    #   short; nil when the game has no such mark
    def room_list_cut_short?(text); end
  end
end
