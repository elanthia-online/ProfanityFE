# frozen_string_literal: true

# Tests CommandHistory, the lines sent that the resend keys and
# autocomplete read: the length rule, consecutive-duplicate skip, the
# size cap read from CONFIG on every add, newest-first access and the
# frozen copies it hands out.

require_relative '../../lib/command_history'

RSpec.describe CommandHistory do
  subject(:sent) { described_class.new }

  def add(*lines)
    lines.each { |line| sent.add(line) }
  end

  describe '#add' do
    it 'records lines newest first' do
      add('north', 'look')
      expect(sent.to_a).to eq %w[look north]
    end

    it 'skips a line shorter than 4 characters' do
      add('abc', 'ab', '')
      expect(sent.to_a).to be_empty
    end

    it 'records a line of exactly 4 characters' do
      add('abcd')
      expect(sent.to_a).to eq %w[abcd]
    end

    it 'records a short line of digits' do
      add('5', '42')
      expect(sent.to_a).to eq %w[42 5]
    end

    it 'follows a changed minimum length' do
      sent.min_length = 2
      add('ab', 'a')
      expect(sent.to_a).to eq %w[ab]
    end

    it 'skips a line identical to the newest one' do
      add('look', 'look')
      expect(sent.to_a).to eq %w[look]
    end

    it 'records a line identical to an older one' do
      add('look', 'north', 'look')
      expect(sent.to_a).to eq %w[look north look]
    end

    it 'keeps the newest CONFIG.history_size lines' do
      CONFIG.history_size = 2
      add('north', 'south', 'east')
      expect(sent.to_a).to eq %w[east south]
    end

    it 'applies a lowered size with the next line' do
      add('north', 'south', 'east')
      CONFIG.history_size = 1
      expect(sent.to_a).to eq %w[east south north]
      add('west')
      expect(sent.to_a).to eq %w[west]
    end

    it 'keeps nothing when the size is 0' do
      CONFIG.history_size = 0
      add('north')
      expect(sent.to_a).to be_empty
      expect(sent.recent(1)).to be_nil
    end

    it 'keeps its own copy of the line' do
      line = +'north'
      sent.add(line)
      line << 'east'
      expect(sent.to_a).to eq %w[north]
    end
  end

  describe '#recent' do
    before { add('north', 'look') }

    it 'returns the last line for 1 and the one before it for 2' do
      expect([sent.recent(1), sent.recent(2)]).to eq %w[look north]
    end

    it 'returns nil past the oldest line' do
      expect(sent.recent(3)).to be_nil
    end

    it 'returns nil for 0 and below, not the oldest line' do
      expect([sent.recent(0), sent.recent(-1)]).to eq [nil, nil]
    end
  end

  describe '#to_a' do
    before { add('north') }

    it 'returns a copy that cannot change the lines' do
      expect { sent.to_a << 'look' }.to raise_error(FrozenError)
      expect { sent.to_a.first << ' me' }.to raise_error(FrozenError)
      expect { sent.recent(1) << ' me' }.to raise_error(FrozenError)
      expect(sent.to_a).to eq %w[north]
    end
  end
end
