# frozen_string_literal: true

# Tests LineBuffer, the line storage behind text and tabbed windows:
# newest-first storage with a cap, stable line IDs, scroll clamping and
# the row-to-line mapping of a text area.

require_relative '../../lib/line_buffer'

RSpec.describe LineBuffer do
  subject(:buffer) { described_class.new(cap: 5) }

  # Push plain lines, oldest first.
  def push_lines(*texts)
    texts.each { |text| buffer.push(text, [], false) }
  end

  # Texts of the lines shown in a text area, top row first.
  def shown(height)
    (0...height).filter_map { |row| buffer.line_at_row(row, height)&.last&.first }
  end

  describe '#push' do
    it 'stores lines newest first with their colors and continuation flag' do
      buffer.push('one', [{ start: 0, end: 3, fg: 'ff0000' }], false)
      buffer.push('  two', [], true)

      expect(buffer.lines).to eq [['  two', [], true], ['one', [{ start: 0, end: 3, fg: 'ff0000' }], false]]
    end

    it 'evicts the oldest line once the buffer is over its cap' do
      push_lines('l1', 'l2', 'l3', 'l4', 'l5', 'l6')

      expect(buffer.lines.map(&:first)).to eq %w[l6 l5 l4 l3 l2]
    end

    it 'keeps counting appended lines after eviction, so IDs stay stable' do
      push_lines('l1', 'l2', 'l3', 'l4', 'l5', 'l6')

      expect(buffer.lines_appended).to eq 6
    end

    it 'keeps nothing with a cap of zero' do
      zero = described_class.new(cap: 0)
      zero.push('l1', [], false)

      expect(zero.lines).to be_empty
    end

    it 'leaves the scroll position alone' do
      push_lines('l1', 'l2', 'l3', 'l4')
      buffer.scroll_back(1, 2)

      push_lines('l5')

      expect(buffer.pos).to eq 1
    end
  end

  describe '#cap=' do
    it 'converts the value to an integer' do
      buffer.cap = '3'

      expect(buffer.cap).to eq 3
    end

    it 'does not trim lines already over a lowered cap; each push evicts one' do
      push_lines('l1', 'l2', 'l3', 'l4', 'l5')
      buffer.cap = 2

      push_lines('l6')

      expect(buffer.lines.map(&:first)).to eq %w[l6 l5 l4 l3 l2]
    end
  end

  describe '#scroll_back' do
    before { push_lines('l1', 'l2', 'l3', 'l4', 'l5') }

    it 'moves back by the requested count when there is room' do
      expect(buffer.scroll_back(1, 2)).to eq 1
      expect(buffer.pos).to eq 1
    end

    it 'stops when the oldest line reaches the top row' do
      expect(buffer.scroll_back(10, 2)).to eq 3
      expect(shown(2)).to eq %w[l1 l2]
    end

    it 'does not move when the buffer fits in the text area' do
      expect(buffer.scroll_back(1, 5)).to eq 0
      expect(buffer.pos).to eq 0
    end
  end

  describe '#scroll_forward' do
    before do
      push_lines('l1', 'l2', 'l3', 'l4', 'l5')
      buffer.scroll_back(3, 2)
    end

    it 'moves forward by the requested count' do
      expect(buffer.scroll_forward(2)).to eq 2
      expect(shown(2)).to eq %w[l3 l4]
    end

    it 'stops at the newest line' do
      expect(buffer.scroll_forward(10)).to eq 3
      expect(buffer).to be_live
    end

    it 'does not move when already live' do
      buffer.scroll_forward(3)

      expect(buffer.scroll_forward(1)).to eq 0
    end
  end

  describe '#line_at_row' do
    it 'fills the text area from its top row when the buffer is short' do
      push_lines('l1', 'l2')

      expect([buffer.line_at_row(0, 4)&.last&.first, buffer.line_at_row(1, 4)&.last&.first,
              buffer.line_at_row(2, 4)]).to eq ['l1', 'l2', nil]
    end

    it 'shows the newest lines on the bottom rows when live' do
      push_lines('l1', 'l2', 'l3', 'l4', 'l5')

      expect(shown(3)).to eq %w[l3 l4 l5]
    end

    it 'shows older lines when scrolled back' do
      push_lines('l1', 'l2', 'l3', 'l4', 'l5')
      buffer.scroll_back(2, 3)

      expect(shown(3)).to eq %w[l1 l2 l3]
    end

    it 'returns the stable ID of the line with it' do
      push_lines('l1', 'l2', 'l3', 'l4', 'l5', 'l6')

      id, entry = buffer.line_at_row(0, 3)

      expect([id, entry.first]).to eq [4, 'l4']
    end

    it 'returns nil for every row of an empty buffer' do
      expect(buffer.line_at_row(0, 3)).to be_nil
    end

    it 'returns nil for every row of a zero-height text area' do
      push_lines('l1')

      expect(buffer.line_at_row(0, 0)).to be_nil
    end
  end

  describe '#visible_count' do
    it 'is the height when the buffer overflows the text area' do
      push_lines('l1', 'l2', 'l3')

      expect(buffer.visible_count(2)).to eq 2
    end

    it 'is the line count when the buffer is short' do
      push_lines('l1')

      expect(buffer.visible_count(4)).to eq 1
    end
  end

  describe '#id_at_row' do
    it 'is the ID of the line shown on the row' do
      push_lines('l1', 'l2', 'l3', 'l4')

      expect(buffer.id_at_row(0, 2)).to eq 3
    end

    it 'clamps rows above the text area to the top line' do
      push_lines('l1', 'l2', 'l3', 'l4')

      expect(buffer.id_at_row(-3, 2)).to eq 3
    end

    it 'is nil for an empty buffer' do
      expect(buffer.id_at_row(0, 2)).to be_nil
    end
  end

  describe '#extract' do
    it 'rejoins a wrapped line without its continuation indent' do
      buffer.push('one two ', [], false)
      buffer.push('  three', [], true)

      expect(buffer.extract(1, 0, 2, 7)).to eq 'one two three'
    end

    it 'skips evicted lines' do
      push_lines('l1', 'l2', 'l3', 'l4', 'l5', 'l6')

      expect(buffer.extract(1, 0, 2, 2)).to eq 'l2'
    end
  end

  describe '#newest_text?' do
    it 'is false for an empty buffer' do
      expect(buffer.newest_text?('>')).to be false
    end

    it 'compares the newest non-empty line, skipping blank lines' do
      push_lines('>', '')

      expect(buffer.newest_text?('>')).to be true
    end

    it 'is false when the newest non-empty line differs' do
      push_lines('>', 'You wave.')

      expect(buffer.newest_text?('>')).to be false
    end

    it 'is nil when every line is empty' do
      push_lines('', '')

      expect(buffer.newest_text?('>')).to be_nil
    end
  end
end
