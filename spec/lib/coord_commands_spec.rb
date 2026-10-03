# frozen_string_literal: true

# Tests CoordCommands: the game's command table for coord links, read from
# a <cmdlist> (the tag parser's side is spec/lib/coord_links_spec.rb).

require_relative '../../lib/coord_commands'

RSpec.describe CoordCommands do
  subject(:commands) { described_class.new }

  # Read one table of [coord, command] entries.
  def read_table(*entries)
    commands.start
    entries.each { |coord, command| commands.add(coord: coord, command: command) }
    commands.finish
  end

  it 'has no command for any coord before a table arrives' do
    expect(commands.command_for('2524,1864', exist: '-1', noun: 'north')).to be_nil
    expect(commands).not_to be_reading
  end

  it 'reads a table between start and finish' do
    commands.start
    expect(commands).to be_reading

    commands.add(coord: '2524,1864', command: 'go @')
    expect(commands.command_for('2524,1864', exist: '-1', noun: 'north')).to be_nil

    commands.finish
    expect(commands).not_to be_reading
    expect(commands.command_for('2524,1864', exist: '-1', noun: 'north')).to eq 'go north'
  end

  it 'forgets a discarded table, and keeps the one read before' do
    read_table(%w[2524,1753 accept])
    commands.start
    commands.add(coord: '2524,1753', command: 'accept offer')
    commands.add(coord: '2524,1755', command: 'decline')
    commands.discard

    expect(commands).not_to be_reading
    expect(commands.command_for('2524,1753', exist: '-1', noun: nil)).to eq 'accept'
    expect(commands.command_for('2524,1755', exist: '-1', noun: nil)).to be_nil
  end

  it 'ignores an entry added outside a table, or with a missing or empty coord or command' do
    commands.add(coord: '2524,1753', command: 'accept')
    read_table(['2524,1754', nil], ['2524,1755', ''], [nil, 'x'], ['', 'y'])

    %w[2524,1753 2524,1754 2524,1755].each do |coord|
      expect(commands.command_for(coord, exist: '-1', noun: 'n')).to be_nil
    end
    expect(commands.command_for('', exist: '-1', noun: 'n')).to be_nil
  end

  it "doesn't fail when finish or discard comes without a start" do
    commands.finish
    commands.discard

    expect(commands).not_to be_reading
    expect(commands.command_for('2524,1753', exist: '-1', noun: nil)).to be_nil
  end

  it 'substitutes @ with the noun, # with #exist and % with the exist, every time it appears' do
    read_table(['1,1', 'go @ @'], ['1,2', 'look # and #'], ['1,3', 'x % %'], ['1,4', 'give @ to #'])

    expect(commands.command_for('1,1', exist: '-5', noun: 'gate')).to eq 'go gate gate'
    expect(commands.command_for('1,2', exist: '-5', noun: 'gate')).to eq 'look #-5 and #-5'
    expect(commands.command_for('1,3', exist: '-5', noun: 'gate')).to eq 'x -5 -5'
    expect(commands.command_for('1,4', exist: '-5', noun: 'gate')).to eq 'give gate to #-5'
  end

  it "doesn't substitute again inside the noun" do
    read_table(['1,1', 'say @'])

    expect(commands.command_for('1,1', exist: '-5', noun: 'a#b%c@')).to eq 'say a#b%c@'
  end

  it 'puts a backslash in the noun or exist in as written, not as a back-reference' do
    read_table(['1,1', 'go @'], ['1,2', 'look #'], ['1,3', 'tap %'])

    expect(commands.command_for('1,1', exist: '-5', noun: 'a\\0b')).to eq 'go a\\0b'
    expect(commands.command_for('1,1', exist: '-5', noun: '\\&\\1\\k<x>\\\\')).to eq 'go \\&\\1\\k<x>\\\\'
    expect(commands.command_for('1,2', exist: '\\0', noun: 'x')).to eq 'look #\\0'
    expect(commands.command_for('1,3', exist: "\\'", noun: 'x')).to eq "tap \\'"
  end

  it 'has no command for a template with both # and %' do
    read_table(['1,1', '_dialog # %'])

    expect(commands.command_for('1,1', exist: '-5', noun: 'x')).to be_nil
  end

  it 'leaves a missing noun or exist empty, collapsing the spaces' do
    read_table(['1,1', 'pay @ now'], ['1,3', 'tap %'])

    expect(commands.command_for('1,1', exist: '-5', noun: nil)).to eq 'pay now'
    expect(commands.command_for('1,3', exist: nil, noun: nil)).to eq 'tap'
  end

  it 'has no command when the result is empty or only whitespace' do
    read_table(['1,1', '@'], ['1,2', " \t@ "])

    expect(commands.command_for('1,1', exist: '-5', noun: nil)).to be_nil
    expect(commands.command_for('1,2', exist: '-5', noun: '')).to be_nil
  end

  it 'adds a later table to the first, the later command winning for the same coord' do
    read_table(%w[1,1 a], %w[1,2 b])
    read_table(%w[1,2 c], %w[1,3 d])

    expect(%w[1,1 1,2 1,3].map { |coord| commands.command_for(coord, exist: '-5', noun: nil) }).to eq %w[a c d]
  end

  it 'keeps the last entry for a coord a table names twice' do
    read_table(%w[1,1 first], %w[1,1 second])

    expect(commands.command_for('1,1', exist: '-5', noun: nil)).to eq 'second'
  end
end
