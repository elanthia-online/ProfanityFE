# frozen_string_literal: true

# Tests HighlightTable, the Hash behind HIGHLIGHT: every way of changing
# it starts a new generation (HighlightProcessor forgets the regions it
# remembered when the generation moves), reading it never does, and it
# is otherwise an ordinary Hash.

RSpec.describe HighlightTable do
  subject(:table) { described_class[/goblin/ => ['ff0000', nil, nil], /troll/ => ['00ff00', nil, nil]] }

  # The public Hash methods that change a Hash, found the way Ruby itself
  # tells: they raise FrozenError on a frozen Hash.
  def hash_mutators_of_this_ruby
    verbose = $VERBOSE
    $VERBOSE = nil # some methods warn that they ignore the block given to every method
    Hash.public_instance_methods(false).select do |name|
      [[], [/goblin/], [/goblin/, 1]].any? do |args|
        { /goblin/ => 1 }.freeze.public_send(name, *args) { true }
        false
      rescue FrozenError
        true
      rescue ArgumentError, TypeError, NoMethodError, LocalJumpError
        false
      end
    end
  ensure
    $VERBOSE = verbose
  end

  it 'covers every method this Ruby has for changing a Hash' do
    expect(described_class::MUTATORS).to match_array(hash_mutators_of_this_ruby)
  end

  it 'starts at generation 0, made with new or with []' do
    expect([described_class.new.generation, table.generation]).to eq [0, 0]
  end

  {
    '[]='                 => ->(t) { t[/kobold/] = ['0000ff', nil, nil] },
    'store'               => ->(t) { t.store(/goblin/, ['0000ff', nil, nil]) },
    'delete'              => ->(t) { t.delete(/goblin/) },
    'delete_if'           => ->(t) { t.delete_if { |regex, _| regex == /troll/ } },
    'reject!'             => ->(t) { t.reject! { |regex, _| regex == /troll/ } },
    'select!'             => ->(t) { t.select! { |regex, _| regex == /troll/ } },
    'filter!'             => ->(t) { t.filter! { |regex, _| regex == /troll/ } },
    'keep_if'             => ->(t) { t.keep_if { |regex, _| regex == /troll/ } },
    'clear'               => lambda(&:clear),
    'replace'             => ->(t) { t.replace(/kobold/ => ['0000ff', nil, nil]) },
    'merge!'              => ->(t) { t.merge!(/kobold/ => ['0000ff', nil, nil]) },
    'update'              => ->(t) { t.update(/kobold/ => ['0000ff', nil, nil]) },
    'shift'               => lambda(&:shift),
    'compact!'            => lambda(&:compact!),
    'transform_keys!'     => ->(t) { t.transform_keys! { |regex| Regexp.new(regex.source, Regexp::IGNORECASE) } },
    'transform_values!'   => ->(t) { t.transform_values! { |colors| ['0000ff', *colors.drop(1)] } },
    'rehash'              => lambda(&:rehash),
    'compare_by_identity' => lambda(&:compare_by_identity),
    'default='            => ->(t) { t.default = [] },
    'default_proc='       => ->(t) { t.default_proc = proc { [] } }
  }.each do |name, change|
    it "starts a new generation on #{name}" do
      expect { change.call(table) }.to change(table, :generation).by(1)
    end
  end

  # compact! with nothing to remove, or delete of a missing pattern,
  # leave the patterns as they were; a new generation only costs a rescan.
  it 'starts a new generation even when the change turns out to change nothing' do
    expect { table.delete(/kobold/) }.to change(table, :generation).by(1)
  end

  it 'starts a new generation when a change raises part way' do
    expect { table.delete_if { raise ArgumentError, 'boom' } }.to raise_error(ArgumentError, 'boom')
      .and change(table, :generation).by(1)
  end

  it 'keeps the generation on every way of reading it' do
    expect do
      table[/goblin/]
      table.fetch(/troll/)
      table.each_pair { nil }
      table.keys
      table.to_a
      table.merge(/kobold/ => ['0000ff', nil, nil])
      table.select { true }
      table.dup
    end.not_to change(table, :generation)
  end

  it 'counts its own changes, not those of a copy made from it' do
    copy = table.dup

    expect { copy.clear }.not_to change(table, :generation)
  end

  it 'equals a plain Hash with the same patterns in the same order' do
    expect(table).to eq(/goblin/ => ['ff0000', nil, nil], /troll/ => ['00ff00', nil, nil])
    expect(table.to_a.map(&:first)).to eq [/goblin/, /troll/]
  end

  it 'is the HIGHLIGHT of the application, emptied by CONFIG.reset! in a new generation' do
    HIGHLIGHT[/goblin/] = ['ff0000', nil, nil]

    expect { CONFIG.reset! }.to change(HIGHLIGHT, :generation)
    expect(HIGHLIGHT).to be_a(described_class).and be_empty
  end
end
