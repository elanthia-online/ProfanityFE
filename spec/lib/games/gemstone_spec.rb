# frozen_string_literal: true

require_relative '../../../lib/games/gemstone'

RSpec.describe Games::GemStone do
  describe 'DEATH_PATTERN' do
    let(:pattern) { described_class::DEATH_PATTERN }

    # Every area death message should match and resolve
    {
      'just bit the dust!'                                       => 'WL',
      'echoes in your mind!'                                     => 'RIFT',
      'just got squashed!'                                       => 'CY',
      'has gone to feed the fishes!'                             => 'RR',
      'just got iced in the Hinterwilds!'                        => 'HW',
      'just punched a one-way ticket!'                           => 'KD',
      'is going home on his shield!'                             => 'TV',
      'just took a long walk off of a short pier!'               => 'SOL',
      'is dust in the wind!'                                     => 'FWI',
      'is six hundred feet under!'                               => 'ZUL',
      'just gave up the ghost!'                                  => 'TRAIL',
      'was just defeated in Duskruin Arena!'                     => 'DR-A',
      'failed within the Bank at Bloodriven'                     => 'DR-B',
      'was just defeated in the Arena of the Abyss!'             => 'EG-A',
      'failed to bring a shrubbery to the Night at the Academy!' => 'NATA',
      'has just returned to Gosaena!'                            => '??',
    }.each do |death_msg, expected_area|
      it "matches '#{death_msg[0..40]}...' and resolves to #{expected_area}" do
        text = " * Mahtra #{death_msg}"
        match = text.match(pattern)
        expect(match).not_to be_nil, "Pattern did not match: #{text}"
        expect(match[:name]).to eq 'Mahtra'
        expect(described_class.resolve_death_area(match[:area])).to eq expected_area
      end
    end

    it 'matches death with "The death cry of" prefix' do
      text = ' * The death cry of Mahtra echoes in your mind!'
      match = text.match(pattern)
      expect(match[:prefix]).to include('death cry')
      expect(match[:name]).to eq 'Mahtra'
    end

    it 'matches gendered messages (his/her)' do
      expect(' * Mahtra is going home on her shield!').to match(pattern)
      expect(' * Grocha is going home on his shield!').to match(pattern)
    end

    it 'matches Duskruin Arena with round numbers' do
      (1..99).each do |round|
        text = " * Mahtra was just defeated during round #{round} in Duskruin Arena!"
        expect(text).to match(pattern), "Failed for round #{round}"
      end
    end

    it 'matches Endless Duskruin Arena' do
      text = ' * Mahtra was just defeated during round 15 in Endless Duskruin Arena!'
      expect(text).to match(pattern)
    end

    it 'matches OSA (Great Western Sea)' do
      text = ' * Mahtra just sank to the bottom of the Great Western Sea!'
      expect(text).to match(pattern)
    end

    it 'matches OSA (Tenebrous Cauldron)' do
      text = ' * Mahtra just sank to the bottom of the Tenebrous Cauldron!'
      expect(text).to match(pattern)
    end

    # Adversarial
    it 'does not match without leading " * "' do
      expect('Mahtra just bit the dust!').not_to match(pattern)
    end

    it 'does not match lowercase names' do
      expect(' * mahtra just bit the dust!').not_to match(pattern)
    end

    it 'does not match arbitrary death messages' do
      expect(' * Mahtra fell into a hole!').not_to match(pattern)
    end
  end

  describe 'DEATH_SUPPRESS_PATTERN' do
    let(:pattern) { described_class::DEATH_SUPPRESS_PATTERN }

    it('vaporized') { expect(' * Mahtra has been vaporized!').to match(pattern) }
    it('incinerated') { expect(' * Grocha was just incinerated!').to match(pattern) }
    it('with prefix') { expect(' * The death cry of Mahtra has been vaporized!').to match(pattern) }

    it 'does not match normal deaths' do
      expect(' * Mahtra just bit the dust!').not_to match(pattern)
    end
  end

  describe '.resolve_death_area' do
    it 'returns original text for unknown areas' do
      expect(described_class.resolve_death_area('fell off a cliff!')).to eq 'fell off a cliff!'
    end

    it 'returns original text for empty string' do
      expect(described_class.resolve_death_area('')).to eq ''
    end

    # Every area code should be reachable
    described_class::DEATH_AREA_CODES.each do |pattern, code|
      it "resolves #{code} from its pattern" do
        # Generate a matching string from the pattern
        # Use the pattern source to build a sample text
        sample = pattern.source
                        .gsub('(?:his|her)', 'his')
                        .gsub('(?:He|She)', 'He')
                        .gsub('\d+', '5')
                        .gsub('(?:Endless )?', '')
                        .gsub('(?:Great Western Sea|Tenebrous Cauldron)', 'Great Western Sea')
                        .gsub('\\s+', ' ')
                        .gsub('\\', '')
        expect(described_class.resolve_death_area(sample)).to eq code
      end
    end
  end

  describe 'LOGON_PATTERNS' do
    let(:patterns) { described_class::LOGON_PATTERNS }

    it 'has no duplicate keys' do
      expect(patterns.keys.length).to eq patterns.keys.uniq.length
    end

    it 'all values are valid hex color strings' do
      patterns.each_value do |color|
        expect(color).to match(/^[0-9a-f]{6}$/), "Invalid color: #{color}"
      end
    end
  end
end
