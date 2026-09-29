# frozen_string_literal: true

# Tests Games::GemStone: the death window entry for each death line
# (.death_summary), deaths shown nowhere, and logon lines (.logon).
#
# The game lines are written from the message tables in
# lib/games/gemstone.rb (DEATH_AREA_CODES, DEATH_SUPPRESS_PATTERN,
# LOGON_PATTERNS) and the lines already used in game_rules_processing_spec,
# which checks how they are shown in the death and logons windows. Lines
# made up only to check what is not recognized say "synthetic" in the
# example name.

require_relative '../../../lib/games/gemstone'

RSpec.describe Games::GemStone do
  describe '.death_summary' do
    # One literal line per DEATH_AREA_CODES key (two for keys with
    # alternatives), with the entry it must give. Written out by hand, not
    # generated from the table's regexps, so a key that stops matching its
    # message fails here.
    death_lines = {
      ' * Mahtra just bit the dust!'                                           => 'Mahtra WL',
      ' * Mahtra is off to a rough start!  She just bit the dust!'             => 'Mahtra WL',
      ' * The death cry of Mahtra echoes in your mind!'                        => 'Mahtra RIFT',
      ' * Mahtra just got squashed!'                                           => 'Mahtra CY',
      ' * Mahtra has gone to feed the fishes!'                                 => 'Mahtra RR',
      " * Mahtra's life on land appears to be as rough as her life at sea."    => 'Mahtra KF',
      ' * Mahtra just turned her last page!'                                   => 'Mahtra TI',
      ' * Mahtra is off to a rough start!  She was just put on ice!'           => 'Mahtra IMT',
      ' * Mahtra was just put on ice!'                                         => 'Mahtra IMT',
      ' * Mahtra just sank to the bottom of the Great Western Sea!'            => 'Mahtra OSA',
      ' * Mahtra just sank to the bottom of the Tenebrous Cauldron!'           => 'Mahtra OSA',
      ' * Mahtra just gave up the ghost!'                                      => 'Mahtra TRAIL',
      ' * Mahtra just got iced in the Hinterwilds!'                            => 'Mahtra HW',
      ' * Mahtra just punched a one-way ticket!'                               => 'Mahtra KD',
      ' * Mahtra is going home on her shield!'                                 => 'Mahtra TV',
      ' * Grocha is going home on his shield!'                                 => 'Grocha TV',
      ' * Mahtra just took a long walk off of a short pier!'                   => 'Mahtra SOL',
      ' * Mahtra is dust in the wind!'                                         => 'Mahtra FWI',
      ' * Mahtra is six hundred feet under!'                                   => 'Mahtra ZUL',
      ' * Mahtra just lost her way somewhere in the Settlement of Reim!'       => 'Mahtra REIM',
      ' * Bob may just be going home on his shield!'                           => 'Bob RED',
      " * Mahtra's flame just burnt out in the Sea of Fire!"                   => 'Mahtra SOS',
      ' * Mahtra failed within the Bank at Bloodriven'                         => 'Mahtra DR-B',
      ' * Mahtra was just defeated in Duskruin Arena!'                         => 'Mahtra DR-A',
      ' * Mahtra was just defeated during round 12 in Endless Duskruin Arena!' => 'Mahtra DR-A',
      ' * Mahtra was just defeated in the Arena of the Abyss!'                 => 'Mahtra EG-A',
      ' * Mahtra failed to bring a shrubbery to the Night at the Academy!'     => 'Mahtra NATA',
      ' * Mahtra has just returned to Gosaena!'                                => 'Mahtra ??',
    }.freeze

    death_lines.each do |line, entry|
      it "gives #{line.strip.inspect} the entry #{entry.inspect}" do
        expect(described_class.death_summary(line)).to eq entry
      end
    end

    it 'has a sample line above for every DEATH_AREA_CODES entry' do
      first_keys = death_lines.keys.filter_map do |line|
        match = line.match(described_class::DEATH_PATTERN) or next
        described_class::DEATH_AREA_CODES.keys.find { |key| match[:area].match?(key) }
      end
      expect(described_class::DEATH_AREA_CODES.keys - first_keys).to be_empty
    end

    it 'gives a Duskruin Arena death in any round the DR-A code' do
      rounds = [1, 9, 10, 99]
      entries = rounds.map do |round|
        described_class.death_summary(" * Mahtra was just defeated during round #{round} in Duskruin Arena!")
      end
      expect(entries).to eq ['Mahtra DR-A'] * rounds.size
    end

    # Deaths DEATH_SUPPRESS_PATTERN hides: an empty entry, shown nowhere.
    [
      ' * Mahtra has been vaporized!',
      ' * Grocha was just incinerated!',
      ' * The death cry of Mahtra has been vaporized!',
    ].each do |line|
      it "gives #{line.strip.inspect} an empty entry" do
        expect(described_class.death_summary(line)).to eq ''
      end
    end

    it 'is nil for a death line without the leading " * " (synthetic)' do
      expect(described_class.death_summary('Mahtra just bit the dust!')).to be_nil
    end

    it 'is nil for a death line with a lowercase name (synthetic)' do
      expect(described_class.death_summary(' * mahtra just bit the dust!')).to be_nil
    end

    it 'is nil for a death message that is not in the table (synthetic)' do
      expect(described_class.death_summary(' * Mahtra fell into a hole!')).to be_nil
    end
  end

  describe 'DEATH_SUPPRESS_PATTERN' do
    it 'does not match a death with an area code' do
      expect(' * Mahtra just bit the dust!').not_to match(described_class::DEATH_SUPPRESS_PATTERN)
    end
  end

  describe '.resolve_death_area' do
    it 'returns the text itself for a message that is not in the table (synthetic)' do
      expect(described_class.resolve_death_area('fell off a cliff!')).to eq 'fell off a cliff!'
    end

    it 'returns an empty string for an empty string' do
      expect(described_class.resolve_death_area('')).to eq ''
    end
  end

  describe '.logon' do
    it 'gives an arrival the name and green' do
      expect(described_class.logon(' * Mahtra joins the adventure.')).to eq %w[Mahtra 007700]
    end

    it 'gives a departure the name and yellow' do
      expect(described_class.logon(' * Mahtra returns home from a hard day of adventuring.')).to eq %w[Mahtra 777700]
    end

    it 'gives a disconnect the name and orange' do
      expect(described_class.logon(' * Mahtra has disconnected.')).to eq %w[Mahtra aa7733]
    end

    it 'is nil for a message that is not in LOGON_PATTERNS (synthetic)' do
      expect(described_class.logon(' * Mahtra tiptoes into the adventure.')).to be_nil
    end
  end
end
