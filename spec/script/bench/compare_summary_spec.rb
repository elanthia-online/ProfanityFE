# frozen_string_literal: true

require_relative '../../../script/bench/compare'

RSpec.describe CompareSummary do
  # A replay.rb result with the given CPU numbers.
  def run(cpu, server)
    { 'cpu_s' => cpu, 'counters' => { 'server_thread_cpu' => server } }
  end

  describe '.median' do
    it 'takes the middle value, the upper one for an even count, ignoring nils' do
      expect(described_class.median([3, 1, 2])).to eq(2)
      expect(described_class.median([4, 1, 3, 2])).to eq(3)
      expect(described_class.median([nil, 5])).to eq(5)
      expect(described_class.median([])).to be_nil
    end
  end

  describe '.summarise' do
    it 'gives each build its medians and runs, in the order given' do
      rounds = [{ 'main' => run(1.2, 0.6), 'branch' => run(0.9, 0.3) },
                { 'main' => run(1.0, 0.5), 'branch' => run(0.8, 0.25) },
                { 'main' => run(1.4, 0.7), 'branch' => run(1.0, 0.35) }]

      rows = described_class.summarise(rounds, %w[main branch])

      expect(rows.map { |r| [r[:label], r[:cpu], r[:server]] }).to eq([['main', 1.2, 0.6], ['branch', 0.9, 0.3]])
      expect(rows.last[:server_runs]).to eq([0.3, 0.25, 0.35])
    end

    it 'compares each later build with the first round by round, not median to median' do
      # Per round: -50%, -10%, -10%; median -10%. Median to median would be 0.5 vs 0.6, -16.7%.
      rounds = [{ 'main' => run(1, 1.0), 'branch' => run(1, 0.5) },
                { 'main' => run(1, 0.4), 'branch' => run(1, 0.36) },
                { 'main' => run(1, 0.6), 'branch' => run(1, 0.54) }]

      rows = described_class.summarise(rounds, %w[main branch])

      expect(rows.first).not_to have_key(:server_delta_pct)
      expect(rows.last[:server_delta_pct]).to be_within(0.001).of(-10.0)
    end

    it 'skips a round in which a build failed' do
      rounds = [{ 'main' => run(1, 0.4), 'branch' => run(1, 0.2) }, { 'main' => run(1, 0.4) }]

      row = described_class.summarise(rounds, %w[main branch]).last

      expect(row[:server_runs]).to eq([0.2])
      expect(row[:server_delta_pct]).to eq(-50.0)
    end
  end
end
