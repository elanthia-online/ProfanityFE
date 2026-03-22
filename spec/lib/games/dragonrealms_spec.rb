# frozen_string_literal: true

require_relative '../../../lib/spell_abbreviations'
require_relative '../../../lib/games/dragonrealms'

RSpec.describe Games::DragonRealms do
  let(:processor) { Class.new { include Games::DragonRealms }.new }

  describe '#abbreviate_spell' do
    it 'abbreviates known spells' do
      expect(processor.abbreviate_spell('Aesandry Darlaeth')).to eq 'AD'
    end

    it 'returns unknown spells unchanged' do
      expect(processor.abbreviate_spell('Nonexistent Spell')).to eq 'Nonexistent Spell'
    end

    it 'strips whitespace before lookup' do
      expect(processor.abbreviate_spell('  Aesandry Darlaeth  ')).to eq 'AD'
    end

    # Adversarial
    it 'returns empty string unchanged' do
      expect(processor.abbreviate_spell('')).to eq ''
    end

    it 'returns whitespace-only unchanged' do
      expect(processor.abbreviate_spell('   ')).to eq '   '
    end

    it 'is case-sensitive (spell names must match exactly)' do
      expect(processor.abbreviate_spell('aesandry darlaeth')).to eq 'aesandry darlaeth'
    end
  end

  describe 'DEATH_PATTERN' do
    let(:pattern) { described_class::DEATH_PATTERN }

    it 'captures name from standard death' do
      match = ' * Mahtra was just struck down!'.match(pattern)
      expect(match[:name]).to eq 'Mahtra'
    end

    it 'captures name from phoenix death' do
      text = " * A fiery phoenix soars into the heavens as Mahtra's spirit arises from the ashes of death."
      expect(text.match(pattern)[:name]).to eq 'Mahtra'
    end

    it 'captures name from disintegration' do
      expect(' * Grocha just disintegrated!'.match(pattern)[:name]).to eq 'Grocha'
    end

    it 'captures name from Plane of Exile' do
      expect(' * Mahtra was lost to the Plane of Exile!'.match(pattern)[:name]).to eq 'Mahtra'
    end

    it 'captures name from smote' do
      expect(' * Grocha was smote by Aldauth!'.match(pattern)[:name]).to eq 'Grocha'
    end

    it 'captures name from failed within (Duskruin Bank)' do
      expect(' * Chanepheous failed within the Bank of Duskruin!'.match(pattern)[:name]).to eq 'Chanepheous'
    end

    it 'captures name from sacrifice' do
      expect(' * Serapheim was just sacrificed to Dergati!'.match(pattern)[:name]).to eq 'Serapheim'
    end

    # Adversarial
    it 'does not match without leading " * "' do
      expect('Mahtra was just struck down!').not_to match(pattern)
    end

    it 'does not match lowercase names' do
      expect(' * mahtra was just struck down!').not_to match(pattern)
    end

    it 'does not match names starting with numbers' do
      expect(' * 1mahtra was just struck down!').not_to match(pattern)
    end

    it 'requires name to start with uppercase followed by lowercase' do
      expect(' * MA was just struck down!').not_to match(pattern)
    end
  end

  describe 'RAISE_DEAD_PATTERN' do
    let(:pattern) { described_class::RAISE_DEAD_PATTERN }

    # Test each deity variant
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
    ].each do |text|
      it "matches: #{text[0..60]}..." do
        expect(text).to match(pattern)
      end
    end

    it 'does not match normal combat text' do
      expect('You swing a sword at a goblin').not_to match(pattern)
    end

    it 'does not match partial raise dead text' do
      expect('I feel the chant').not_to match(pattern)
    end
  end

  describe 'SHADOW_VALLEY_PATTERN' do
    it 'matches the shadow valley stun message' do
      text = 'Just as you think the falling will never end, you crash through an ethereal barrier which bursts into a dazzling kaleidoscope of color!  Your sensation of falling turns to dizziness and you feel unusually heavy for a moment.  Everything seems to stop for a prolonged second and then WHUMP!!!'
      expect(text).to match(described_class::SHADOW_VALLEY_PATTERN)
    end

    it 'does not match partial text' do
      expect('Just as you think the falling will never end').not_to match(described_class::SHADOW_VALLEY_PATTERN)
    end
  end

  describe 'LOGON_PATTERNS' do
    let(:patterns) { described_class::LOGON_PATTERNS }

    it 'has green for all login variants' do
      login_patterns = patterns.select { |_, color| color == '007700' }
      expect(login_patterns.length).to be >= 10
    end

    it 'has yellow for all logout variants' do
      logout_patterns = patterns.select { |_, color| color == '777700' }
      expect(logout_patterns.length).to be >= 5
    end

    it 'has exactly one disconnect pattern' do
      disconnect = patterns.select { |_, color| color == 'aa7733' }
      expect(disconnect.length).to eq 1
      expect(disconnect.keys.first).to eq 'has disconnected.'
    end

    it 'has no duplicate keys' do
      expect(patterns.keys.length).to eq patterns.keys.uniq.length
    end
  end
end
