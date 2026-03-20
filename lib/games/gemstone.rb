# frozen_string_literal: true

=begin
GemStone IV-specific game text processing.
Contains death message formatting with area consolidation, logon message
patterns with preset colors, and GS-specific text processing rules.
=end

# GemStone IV-specific text processing rules.
#
# Provides pattern matching and formatting for GS game streams:
# death messages with area code consolidation, logon/logoff/disconnect
# messages with per-type preset colors.
#
# Ported from elanthia-online/ProfanityFE death/logon stream handling.
module Games
  module GemStone
    # GS death message pattern — matches the full death cry line and captures
    # the optional prefix, character name, and area-specific death message.
    #
    # @return [Regexp]
    DEATH_PATTERN = /^\s\*\s(?<prefix>The death cry of )?(?<name>[A-Z][a-z]+)(?:['s]*) (?<area>just bit the dust!|life on land appears to be as rough as (?:his|her) life at sea\.|just got iced in the Hinterwilds!|is off to a rough start!\s+(?:He|She) just bit the dust!|echoes in your mind!|just got squashed!|has gone to feed the fishes!|just turned (?:his|her) last page!|is off to a rough start!\s+(?:He|She) was just put on ice!|was just put on ice!|just punched a one-way ticket!|is going home on (?:his|her) shield!|just took a long walk off of a short pier!|is dust in the wind!|is six hundred feet under!|just lost (?:his|her) way somewhere in the Settlement of Reim!|just gave up the ghost!|flame just burnt out in the Sea of Fire!|failed within the Bank at Bloodriven|was just defeated in Duskruin Arena!|was just defeated during round \d+ in (?:Endless )?Duskruin Arena!|failed to bring a shrubbery to the Night at the Academy!|just sank to the bottom of the (?:Great Western Sea|Tenebrous Cauldron)!|was just defeated in the Arena of the Abyss!|has just returned to Gosaena!)/.freeze

    # GS death messages that should be suppressed (no area code)
    DEATH_SUPPRESS_PATTERN = /^\s\*\s(?:The death cry of )?[A-Z][a-z]+(?:['s]*) (?:has been vaporized!|was just incinerated!)/.freeze

    # Map area-specific death messages to short area codes.
    # Used to consolidate verbose death cries into compact "Name AREA HH:MM" format.
    #
    # @return [Hash<Regexp, String>]
    DEATH_AREA_CODES = {
      /just bit the dust!/                                                       => 'WL',
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

    # Abbreviate a GS spell name (stub — returns original name).
    #
    # @param spell_name [String] full spell name
    # @return [String] the original name (no GS abbreviation table yet)
    def abbreviate_spell(spell_name)
      spell_name
    end
  end
end
