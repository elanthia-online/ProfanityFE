# frozen_string_literal: true

require_relative '../spell_abbreviations'

=begin
DragonRealms-specific game text processing.
Contains death message formatting, logon message patterns, stun detection,
spell abbreviations, and familiar notification patterns unique to DR.
=end

# DragonRealms-specific text processing rules.
#
# Provides pattern matching and formatting for DR game streams:
# death messages, logon/logoff messages, Raise Dead stun detection,
# Shadow Valley stun, nerve wound detection, and spell abbreviation
# for the percWindow.
#
# @example
#   include Games::DragonRealms
#   abbreviate_spell('Aesandry Darlaeth')  #=> 'AD'
module Games
  module DragonRealms
    # DR spell abbreviation lookup for percWindow.
    SPELL_ABBREVIATIONS = DR_SPELL_ABBREVIATIONS

    # DR logon/logoff message patterns mapped to display colors.
    # Green (007700) = login, yellow (777700) = logout, orange (aa7733) = disconnect.
    #
    # @return [Hash<String, String>] message suffix => hex color code
    LOGON_PATTERNS = {
      'joins the adventure with little fanfare.'                             => '007700',
      'just sauntered into the adventure with an annoying tune on his lips.' => '007700',
      'just wandered into another adventure.'                                => '007700',
      'just limped in for another adventure.'                                => '007700',
      'snuck out of the shadow he was hiding in.'                            => '007700',
      'joins the adventure with a gleam in her eye.'                         => '007700',
      'joins the adventure with a gleam in his eye.'                         => '007700',
      'comes out from within the shadows with renewed vigor.'                => '007700',
      'just crawled into the adventure.'                                     => '007700',
      'has woken up in search of new ale!'                                   => '007700',
      'just popped into existance.'                                          => '007700',
      'has joined the adventure after escaping another.'                     => '007700',
      'joins the adventure.'                                                 => '007700',
      'returns home from a hard day of adventuring.'                         => '777700',
      'has left to contemplate the life of a warrior.'                       => '777700',
      'just sauntered off-duty to get some rest.'                            => '777700',
      'departs from the adventure with little fanfare.'                      => '777700',
      'limped away from the adventure for now.'                              => '777700',
      'thankfully just returned home to work on a new tune.'                 => '777700',
      'fades swiftly into the shadows.'                                      => '777700',
      'retires from the adventure for now.'                                  => '777700',
      'just found a shadow to hide out in.'                                  => '777700',
      'quietly departs the adventure.'                                       => '777700',
      'has disconnected.'                                                    => 'aa7733'
    }.freeze

    # DR death message pattern (phoenix, struck down, disintegrated, etc.)
    #
    # @return [Regexp]
    DEATH_PATTERN = /^\s\*\s(?:A fiery phoenix soars into the heavens as\s)?(?<name>[A-Z][a-z]+)(?: was just struck down.*| just disintegrated!| was lost to the Plane of Exile!|'s spirit arises from the ashes of death.| was smote by \w+!)/.freeze

    # DR Raise Dead stun pattern (cleric deity-specific messaging variants)
    #
    # @return [Regexp]
    RAISE_DEAD_PATTERN = /^Deep and resonating, you feel the chant that falls from your lips|^Moisture beads upon your skin and you feel your eyes cloud over|^Lifting your finger, you begin to chant and draw a series of conjoined circles|^Crouching beside the prone form of|^Murmuring softly, you call upon your connection with the Destroyer|^Rich and lively, the scent of wild flowers suddenly fills the air|^Breathing slowly, you extend your senses towards the world around you|^Your surroundings grow dim\.\.\.you lapse into a state of awareness only|^Murmuring softly, a mournful chant slips from your lips|^Emptying all breathe from your body, you slowly still yourself|^Thin at first, a fine layer of rime tickles your hands|^As you begin to chant,? you notice the scent of dry, dusty parchment|^Wrapped in an aura of chill, you close your eyes and softly begin to chant|^As .*? begins to chant, your spirit is drawn closer to your body/.freeze

    # DR Shadow Valley exit stun message
    #
    # @return [Regexp]
    SHADOW_VALLEY_PATTERN = /^Just as you think the falling will never end, you crash through an ethereal barrier which bursts into a dazzling kaleidoscope of color!  Your sensation of falling turns to dizziness and you feel unusually heavy for a moment\.  Everything seems to stop for a prolonged second and then WHUMP!!!/.freeze

    # Abbreviate a DR spell name for compact percWindow display.
    #
    # @param spell_name [String] full spell name from game server
    # @return [String] abbreviated name, or original if no abbreviation exists
    def abbreviate_spell(spell_name)
      SPELL_ABBREVIATIONS[spell_name.strip] || spell_name
    end
  end
end
