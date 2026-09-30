# frozen_string_literal: true

# Tests Games::DragonRealms: spell abbreviations, the death window entry for
# each death line (.death_summary), the stun of a Raise Dead chant or the
# Shadow Valley fall (.stun_seconds), and logon lines (.logon).
#
# The game lines come from the patterns and tables in
# lib/games/dragonrealms.rb and the lines already used in
# game_rules_processing_spec, which checks how they are shown. Lines made up
# only to check what is not recognized say "synthetic" in the example name.

require_relative '../../../lib/spell_abbreviations'
require_relative '../../../lib/games/dragonrealms'

RSpec.describe Games::DragonRealms do
  describe '.spell_abbreviation' do
    it 'abbreviates known spells' do
      expect(described_class.spell_abbreviation('Aesandry Darlaeth')).to eq 'AD'
    end

    it 'has no abbreviation for unknown spells' do
      expect(described_class.spell_abbreviation('Nonexistent Spell')).to be_nil
    end

    it 'strips whitespace before lookup' do
      expect(described_class.spell_abbreviation('  Aesandry Darlaeth  ')).to eq 'AD'
    end

    it 'has no abbreviation for an empty string' do
      expect(described_class.spell_abbreviation('')).to be_nil
    end

    it 'has no abbreviation for whitespace only' do
      expect(described_class.spell_abbreviation('   ')).to be_nil
    end

    it 'is case-sensitive (spell names must match exactly)' do
      expect(described_class.spell_abbreviation('aesandry darlaeth')).to be_nil
    end
  end

  describe '.death_summary' do
    {
      ' * Mahtra was just struck down!'                                                              => 'Mahtra',
      " * A fiery phoenix soars into the heavens as Mahtra's spirit arises from the ashes of death." => 'Mahtra MF',
      ' * Grocha just disintegrated!'                                                                => 'Grocha',
      ' * Mahtra was lost to the Plane of Exile!'                                                    => 'Mahtra',
      ' * Grocha was smote by Aldauth!'                                                              => 'Grocha',
      ' * Chanepheous failed within the Bank of Duskruin!'                                           => 'Chanepheous',
      ' * Serapheim was just sacrificed to Dergati!'                                                 => 'Serapheim Sacrifice',
    }.each do |line, entry|
      it "gives #{line.strip.inspect} the entry #{entry.inspect}" do
        expect(described_class.death_summary(line)).to eq entry
      end
    end

    it 'is nil for a death line without the leading " * " (synthetic)' do
      expect(described_class.death_summary('Mahtra was just struck down!')).to be_nil
    end

    it 'is nil for a death line with a lowercase name (synthetic)' do
      expect(described_class.death_summary(' * mahtra was just struck down!')).to be_nil
    end

    it 'is nil for a name starting with a digit (synthetic)' do
      expect(described_class.death_summary(' * 1mahtra was just struck down!')).to be_nil
    end

    it 'is nil for an all-capitals name (synthetic)' do
      expect(described_class.death_summary(' * MA was just struck down!')).to be_nil
    end
  end

  describe '.stun_seconds' do
    raise_dead_stun = 30.6
    shadow_valley_stun = 16.2

    # The start of each deity's Raise Dead chant, as RAISE_DEAD_PATTERN
    # lists them.
    [
      'Deep and resonating, you feel the chant that falls from your lips',
      'Moisture beads upon your skin and you feel your eyes cloud over',
      'Lifting your finger, you begin to chant and draw a series of conjoined circles',
      'Crouching beside the prone form of Mahtra',
      'Murmuring softly, you call upon your connection with the Destroyer',
      'Rich and lively, the scent of wild flowers suddenly fills the air',
      'Breathing slowly, you extend your senses towards the world around you',
      'Your surroundings grow dim...you lapse into a state of awareness only',
      'Murmuring softly, a mournful chant slips from your lips',
      'Emptying all breathe from your body, you slowly still yourself',
      'Thin at first, a fine layer of rime tickles your hands',
      'As you begin to chant, you notice the scent of dry, dusty parchment',
      'Wrapped in an aura of chill, you close your eyes and softly begin to chant',
      'As Cleric begins to chant, your spirit is drawn closer to your body',
    ].each do |chant|
      it "is #{raise_dead_stun} for the Raise Dead chant #{chant.inspect}" do
        expect(described_class.stun_seconds(chant)).to eq raise_dead_stun
      end
    end

    it "is #{shadow_valley_stun} for the fall out of the Shadow Valley" do
      fall = 'Just as you think the falling will never end, you crash through an ethereal barrier which ' \
             'bursts into a dazzling kaleidoscope of color!  Your sensation of falling turns to dizziness ' \
             'and you feel unusually heavy for a moment.  Everything seems to stop for a prolonged second ' \
             'and then WHUMP!!!'
      expect(described_class.stun_seconds(fall)).to eq shadow_valley_stun
    end

    it 'is nil for only the first sentence of the Shadow Valley fall' do
      expect(described_class.stun_seconds('Just as you think the falling will never end')).to be_nil
    end

    it 'is nil for a combat line (synthetic)' do
      expect(described_class.stun_seconds('You swing a sword at a goblin')).to be_nil
    end

    it 'is nil for a line that only mentions a chant (synthetic)' do
      expect(described_class.stun_seconds('I feel the chant')).to be_nil
    end
  end

  describe '.logon' do
    it 'gives an arrival the name and green' do
      expect(described_class.logon(' * Mahtra joins the adventure with little fanfare.')).to eq %w[Mahtra 007700]
    end

    it 'gives a departure the name and yellow' do
      expect(described_class.logon(' * Mahtra departs from the adventure with little fanfare.')).to eq %w[Mahtra 777700]
    end

    it 'gives a disconnect the name and orange' do
      expect(described_class.logon(' * Mahtra has disconnected.')).to eq %w[Mahtra aa7733]
    end

    it 'is nil without the leading " * " (synthetic)' do
      expect(described_class.logon('Mahtra joins the adventure with little fanfare.')).to be_nil
    end
  end

  describe '.room_list_cut_short?' do
    it 'is true for a room objs component that ends with the cut-short mark' do
      expect(described_class.room_list_cut_short?('You also see a rock, a stick and some other stuff.')).to be true
    end

    it 'is false for a list that ends as a whole list does' do
      expect(described_class.room_list_cut_short?('You also see a rock, a stick and some junk.')).to be false
    end

    it 'is false when the mark is not at the end (synthetic)' do
      expect(described_class.room_list_cut_short?('You also see a rock and some other stuff. And a stick.')).to be false
    end

    it 'is false for "other stuff" that is not the mark (synthetic)' do
      expect(described_class.room_list_cut_short?('You also see a rock, a stick and handsome other stuff.')).to be false
    end
  end
end
