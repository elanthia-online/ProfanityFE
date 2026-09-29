# frozen_string_literal: true

require_relative 'rules'

=begin
GemStone IV-specific game text processing.
Contains death message formatting with area consolidation, logon message
patterns with preset colors, and GS-specific text processing rules.
=end

# Namespace for per-game text processing rules.
module Games
  # GemStone IV-specific text processing rules.
  #
  # Provides pattern matching and formatting for GS game streams:
  # death messages with area code consolidation, logon/logoff/disconnect
  # messages with per-type preset colors.
  #
  # Ported from elanthia-online/ProfanityFE death/logon stream handling.
  # Answers the {Games::Rules} questions for GemStone; it has no stun or
  # spell-name rules.
  module GemStone
    extend Rules

    # GS death messages, mapped to the short area code shown in the death
    # window ("HH:MM Name AREA"). This table is the single source of truth:
    # DEATH_PATTERN below is built from its keys, so every message listed here
    # is recognized and no message is recognized without an area code.
    #
    # Each key matches the area-specific text that follows the character's
    # name, starting at its first word (DEATH_PATTERN anchors it right after
    # the name). resolve_death_area checks the keys in order and the first
    # match wins, so a key must not also match an earlier key's messages.
    #
    # @return [Hash<Regexp, String>]
    DEATH_AREA_CODES = {
      /(?:is off to a rough start!\s+(?:He|She) )?just bit the dust!/            => 'WL',
      /echoes in your mind!/                                                     => 'RIFT',
      /just got squashed!/                                                       => 'CY',
      /has gone to feed the fishes!/                                             => 'RR',
      /life on land appears to be as rough as (?:his|her) life at sea\./         => 'KF',
      /just turned (?:his|her) last page!/                                       => 'TI',
      /(?:is off to a rough start!\s+(?:He|She) )?was just put on ice!/          => 'IMT',
      /just sank to the bottom of the (?:Great Western Sea|Tenebrous Cauldron)!/ => 'OSA',
      /just gave up the ghost!/                                                  => 'TRAIL',
      /just got iced in the Hinterwilds!/                                        => 'HW',
      /just punched a one-way ticket!/                                           => 'KD',
      /is going home on (?:his|her) shield!/                                     => 'TV',
      /just took a long walk off of a short pier!/                               => 'SOL',
      /is dust in the wind!/                                                     => 'FWI',
      /is six hundred feet under!/                                               => 'ZUL',
      /just lost (?:his|her) way somewhere in the Settlement of Reim!/           => 'REIM',
      /may just be going home on (?:his|her) shield!/                            => 'RED',
      /flame just burnt out in the Sea of Fire!/                                 => 'SOS',
      /failed within the Bank at Bloodriven/                                     => 'DR-B',
      /was just defeated in Duskruin Arena!/                                     => 'DR-A',
      /was just defeated during round \d+ in (?:Endless )?Duskruin Arena!/       => 'DR-A',
      /was just defeated in the Arena of the Abyss!/                             => 'EG-A',
      /failed to bring a shrubbery to the Night at the Academy!/                 => 'NATA',
      /has just returned to Gosaena!/                                            => '??',
    }.freeze

    # GS death message pattern — matches the full death cry line and captures
    # the optional prefix, character name, and area-specific death message.
    # The area alternatives are the keys of DEATH_AREA_CODES.
    #
    # @return [Regexp]
    DEATH_PATTERN = /^\s\*\s(?<prefix>The death cry of )?(?<name>[A-Z][a-z]+)(?:['s]*) (?<area>#{Regexp.union(DEATH_AREA_CODES.keys)})/

    # GS death messages that should be suppressed (no area code)
    DEATH_SUPPRESS_PATTERN = /^\s\*\s(?:The death cry of )?[A-Z][a-z]+(?:['s]*) (?:has been vaporized!|was just incinerated!)/.freeze

    # Resolve a death area message to its short area code.
    #
    # @param area_text [String] the area-specific portion of the death message
    # @return [String] short area code (e.g. 'WL', 'RIFT') or the original text
    def self.resolve_death_area(area_text)
      DEATH_AREA_CODES.each do |pattern, code|
        return code if area_text.match?(pattern)
      end
      area_text
    end

    # GS logon/logoff/disconnect message patterns mapped to display colors.
    # Green (007700) = login, yellow (777700) = logout, orange (aa7733) = disconnect.
    #
    # @return [Hash<String, String>] message suffix => hex color code
    LOGON_PATTERNS = {
      'joins the adventure.'                         => '007700',
      'returns home from a hard day of adventuring.' => '777700',
      'has disconnected.'                            => 'aa7733',
    }.freeze

    # Matches a " * Name <message>" arrival/departure line whose message is a
    # key of {LOGON_PATTERNS}; captures +name+ and the message as +type+.
    LOGON_REGEXP = Rules.logon_regexp(LOGON_PATTERNS.keys)

    # A GS death line's entry: the name and the area code (see
    # {resolve_death_area}), or an empty entry for a death shown nowhere
    # ({DEATH_SUPPRESS_PATTERN}).
    #
    # @param text [String] the line, tags removed
    # @return [String, nil] e.g. "Mahtra WL"; "" for a vaporized or
    #   incinerated character; nil when it isn't a GS death line
    def self.death_summary(text)
      if (match = text.match(DEATH_PATTERN))
        "#{match[:name]} #{resolve_death_area(match[:area])}"
      elsif text.match?(DEATH_SUPPRESS_PATTERN)
        ''
      end
    end

    # (see Games::Rules#logon)
    def self.logon(text)
      match = text.match(LOGON_REGEXP) or return nil

      [match[:name], LOGON_PATTERNS[match[:type]]]
    end
  end
end
