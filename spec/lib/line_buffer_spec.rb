# frozen_string_literal: true

# Tests LineBuffer, the line storage behind text and tabbed windows:
# logical lines wrapped into newest-first rows, a cap counted in logical
# lines, stable row IDs, scroll clamping and the row-to-line mapping of a
# text area.

require_relative '../../lib/line_buffer'

RSpec.describe LineBuffer do
  subject(:buffer) { described_class.new(cap: 5, width: 10) }

  # Push plain lines that fit the width, oldest first.
  def push_lines(*texts)
    texts.each { |text| buffer.push(text, [], indent: true) }
  end

  # Texts of the rows shown in a text area, top row first.
  def shown(height)
    (0...height).filter_map { |row| buffer.line_at_row(row, height)&.last&.first }
  end

  describe '#push' do
    it 'stores a line that fits the width as one row with its colors' do
      buffer.push('one', [{ start: 0, end: 3, fg: 'ff0000' }], indent: true)

      expect(buffer.lines).to eq [['one', [{ start: 0, end: 3, fg: 'ff0000' }], false]]
    end

    it 'wraps a long line to the width, newest row first, flagging the continuation rows' do
      buffer.push('one two three four', [], indent: true)

      expect(buffer.lines).to eq [['  four', [], true], ['  three ', [], true], ['one two ', [], false]]
    end

    it 'splits the color runs across the rows and indents only when asked' do
      buffer.push('one two three', [{ start: 4, end: 13, fg: 'ff0000' }], indent: false)

      expect(buffer.lines).to eq [['three', [{ start: 0, end: 5, fg: 'ff0000' }], true],
                                  ['one two ', [{ start: 4, end: 8, fg: 'ff0000' }], false]]
    end

    it 'returns the number of rows the line was wrapped to' do
      expect(buffer.push('one two three four', [], indent: true)).to eq 3
    end

    it 'evicts the oldest line once the buffer is over its cap' do
      push_lines('l1', 'l2', 'l3', 'l4', 'l5', 'l6')

      expect(buffer.lines.map(&:first)).to eq %w[l6 l5 l4 l3 l2]
    end

    it 'counts the cap in lines, not rows' do
      capped = described_class.new(cap: 2, width: 10)
      capped.push('one two three four', [], indent: true)
      capped.push('l2', [], indent: true)

      expect(capped.lines.map(&:first)).to eq ['l2', '  four', '  three ', 'one two ']
    end

    it 'evicts every row of the oldest line together' do
      capped = described_class.new(cap: 2, width: 10)
      ['one two three four', 'l2', 'l3'].each { |text| capped.push(text, [], indent: true) }

      expect(capped.lines.map(&:first)).to eq %w[l3 l2]
    end

    it 'keeps counting appended rows after eviction, so IDs stay stable' do
      capped = described_class.new(cap: 2, width: 10)
      ['one two three four', 'l2', 'l3'].each { |text| capped.push(text, [], indent: true) }

      expect(capped.lines_appended).to eq 5
    end

    it 'keeps nothing with a cap of zero' do
      zero = described_class.new(cap: 0, width: 10)
      zero.push('l1', [], indent: true)

      expect(zero.lines).to be_empty
    end

    it 'leaves the scroll position alone' do
      push_lines('l1', 'l2', 'l3', 'l4')
      buffer.scroll_back(1, 2)

      push_lines('l5')

      expect(buffer.pos).to eq 1
    end
  end

  describe '#width=' do
    it 're-wraps every stored line to the new width' do
      buffer.push('one two three', [{ start: 4, end: 13, fg: 'ff0000' }], indent: false)
      push_lines('l2')

      buffer.width = 20

      expect(buffer.lines).to eq [['l2', [], false], ['one two three', [{ start: 4, end: 13, fg: 'ff0000' }], false]]
    end

    it 'wraps each line with its own indent setting' do
      buffer.width = 20
      buffer.push('one two three', [], indent: false)
      buffer.push('one two three', [], indent: true)

      buffer.width = 10

      expect(buffer.lines.map(&:first)).to eq ['  three', 'one two ', 'three', 'one two ']
    end

    it 'keeps the line on the bottom row there' do
      wide = described_class.new(cap: 10, width: 20)
      ['l1', 'l2', 'l3', 'one two three four'].each { |text| wide.push(text, [], indent: true) }
      wide.scroll_back(1, 2)
      expect(wide.line_at_row(1, 2).last.first).to eq 'l3'

      wide.width = 10

      expect(wide.line_at_row(1, 2).last.first).to eq 'l3'
      expect(wide.pos).to eq 3
    end

    it 'stays live when live' do
      push_lines('l1')
      buffer.push('one two three four', [], indent: true)

      buffer.width = 20

      expect(buffer).to be_live
    end

    it 'gives the new rows IDs no old row had, so old anchors match nothing' do
      push_lines('l1', 'l2')

      buffer.width = 20

      expect(buffer.lines_appended).to eq 4
      expect(buffer.extract(1, 0, 2, 2)).to eq ''
      expect(buffer.extract(3, 0, 4, 2)).to eq "l1\nl2"
    end

    it 'keeps the lines as added, unaffected by later changes to the caller\'s colors' do
      colors = [{ start: 0, end: 3, fg: 'ff0000' }]
      buffer.push('one two three', colors, indent: false)
      colors.first[:fg] = '00ff00'

      buffer.width = 20

      expect(buffer.lines.first[1]).to eq [{ start: 0, end: 3, fg: 'ff0000' }]
    end

    it 'does nothing when the width is unchanged' do
      push_lines('l1')

      buffer.width = 10

      expect(buffer.lines_appended).to eq 1
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
      buffer.push('one two three', [], indent: true)

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
