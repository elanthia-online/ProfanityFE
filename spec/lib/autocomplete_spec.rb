# frozen_string_literal: true

# Tests Autocomplete.complete: history entries that start with the whole
# command line replace the whole command line and leave the cursor at the
# end, wherever the cursor was when the key was pressed.
#
# Screen assertions use ScreenLineWindow (spec/support), a one-row fake
# that models the visible cells and cursor column, so specs check the
# command line the user sees.

require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../../lib/autocomplete'
require_relative '../support/screen_line_window'

RSpec.describe Autocomplete do
  # Records the feedback lines Autocomplete prints to the main window.
  let(:main_window) do
    Class.new do
      def lines = (@lines ||= [])
      def add_string(text, _colors) = lines << text
    end.new
  end
  let(:screen) { ScreenLineWindow.new(30) }
  let(:buf) do
    CommandBuffer.new.tap do |b|
      b.window = screen
      history.each { |cmd| b.add_to_history(cmd) }
    end
  end

  def type(str)
    str.each_char { |ch| buf.put_ch(ch) }
  end

  def complete
    described_class.complete(buf, main_window)
  end

  context 'with one matching history entry' do
    let(:history) { ['attack goblin'] }

    it 'fills in the command with the cursor at the end' do
      type('att')
      complete
      expect(screen.visible).to eq 'attack goblin'
      expect(screen.curx).to eq 13
    end

    it 'fills in the same command when the cursor is inside the text' do
      type('att')
      2.times { buf.cursor_left }
      complete
      expect(screen.visible).to eq 'attack goblin'
      expect(screen.curx).to eq 13
    end

    it 'fills in the same command when the cursor is at the start' do
      type('att')
      buf.cursor_home
      complete
      expect(screen.visible).to eq 'attack goblin'
      expect(screen.curx).to eq 13
    end

    it 'scrolls to the end of a long completion from inside the text' do
      narrow = ScreenLineWindow.new(10)
      buf.window = narrow
      type('att')
      2.times { buf.cursor_left }
      complete
      expect(narrow.visible).to eq 'ck goblin'
      expect(narrow.curx).to eq 9
    end
  end

  context 'with several matching history entries' do
    let(:history) { ['attack goblin', 'attack troll', 'atone'] }

    it 'fills in the common prefix and lists the candidates' do
      type('att')
      complete
      expect(screen.visible).to eq 'attack'
      expect(screen.curx).to eq 7
      expect(main_window.lines).to eq ['[autocomplete:2]', '[0] attack troll', '[1] attack goblin']
    end

    it 'fills in the same prefix when the cursor is inside the text' do
      type('att')
      2.times { buf.cursor_left }
      complete
      expect(screen.visible).to eq 'attack'
      expect(screen.curx).to eq 7
      expect(main_window.lines).to eq ['[autocomplete:2]', '[0] attack troll', '[1] attack goblin']
    end

    it 'leaves the line and cursor alone when there is no common prefix to add' do
      type('at')
      buf.cursor_left
      complete
      expect(screen.visible).to eq 'at'
      expect(screen.curx).to eq 1
      expect(main_window.lines.first).to eq '[autocomplete:3]'
    end
  end

  # Autocomplete offers only lines that were sent, newest first: not a line
  # saved by the down arrow, and not an edit left in a recalled entry.
  context 'with lines that were never sent' do
    let(:history) { ['attack goblin', 'attack troll'] }

    it 'does not offer a line saved by the down arrow' do
      type('attack orc')
      buf.next_command
      type('att')
      complete
      expect(main_window.lines).to eq ['[autocomplete:2]', '[0] attack troll', '[1] attack goblin']
    end

    it 'offers the sent line, not the edit left in it' do
      buf.previous_command # recall "attack troll"
      3.times { buf.backspace }
      type('ll')           # edited to "attack trll", not sent
      buf.next_command
      type('att')
      complete
      expect(main_window.lines).to eq ['[autocomplete:2]', '[0] attack troll', '[1] attack goblin']
    end
  end

  context 'with no matching history entry' do
    let(:history) { ['attack goblin'] }

    it 'leaves the line and cursor alone and says so' do
      type('xyz')
      buf.cursor_left
      complete
      expect(screen.visible).to eq 'xyz'
      expect(screen.curx).to eq 2
      expect(main_window.lines).to eq ['[autocomplete] no suggestions']
    end
  end
end
