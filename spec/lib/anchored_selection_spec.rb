# frozen_string_literal: true

require_relative '../../lib/anchored_selection'

RSpec.describe AnchoredSelection do
  # Build a newest-first buffer like TextWindow's: line N-1 appended last.
  # buffer_for(3) => [["line 2", []], ["line 1", []], ["line 0", []]]
  def buffer_for(count)
    (0...count).map { |i| ["line #{i}", []] }.reverse
  end

  describe '.visible_lines' do
    it 'is the window height when the buffer overflows the window' do
      expect(described_class.visible_lines(100, 0, 10)).to eq(10)
    end

    it 'is the remaining line count when scrolled near the top' do
      expect(described_class.visible_lines(100, 95, 10)).to eq(5)
    end

    it 'is the buffer length for a partially-filled window' do
      expect(described_class.visible_lines(3, 0, 10)).to eq(3)
    end

    it 'is zero for an empty buffer' do
      expect(described_class.visible_lines(0, 0, 10)).to eq(0)
    end
  end

  describe '.id_at_row' do
    it 'assigns the newest line (bottom row) the highest ID' do
      # 5 lines, live view, height 10: rows 0..4 populated, row 4 is newest
      id = described_class.id_at_row(4, lines_appended: 5, buffer_pos: 0, buffer_length: 5, height: 10)
      expect(id).to eq(5)
    end

    it 'assigns the oldest visible line (top row) the lowest ID' do
      id = described_class.id_at_row(0, lines_appended: 5, buffer_pos: 0, buffer_length: 5, height: 10)
      expect(id).to eq(1)
    end

    it 'returns nil for an empty buffer' do
      expect(described_class.id_at_row(0, lines_appended: 0, buffer_pos: 0, buffer_length: 0, height: 10)).to be_nil
    end

    it 'clamps rows below the populated area to the newest line' do
      # 3 lines in a 10-row window: rows 3..9 are blank; clicking there
      # anchors to the last real line instead of failing
      id = described_class.id_at_row(9, lines_appended: 3, buffer_pos: 0, buffer_length: 3, height: 10)
      expect(id).to eq(3)
    end

    it 'clamps negative rows (drag above the window) to the top line' do
      id = described_class.id_at_row(-2, lines_appended: 20, buffer_pos: 0, buffer_length: 20, height: 10)
      expect(id).to eq(described_class.id_at_row(0, lines_appended: 20, buffer_pos: 0, buffer_length: 20, height: 10))
    end

    it 'accounts for scroll position' do
      # 20 lines, height 10, scrolled up 5: bottom row shows index 5
      id = described_class.id_at_row(9, lines_appended: 20, buffer_pos: 5, buffer_length: 20, height: 10)
      expect(id).to eq(15)
    end

    it 'is stable across appends: the same text keeps its ID as rows shift' do
      before = described_class.id_at_row(9, lines_appended: 20, buffer_pos: 0, buffer_length: 20, height: 10)
      # 3 new lines arrive; the line that was on row 9 is now on row 6
      after = described_class.id_at_row(6, lines_appended: 23, buffer_pos: 0, buffer_length: 23, height: 10)
      expect(after).to eq(before)
    end
  end

  describe '.row_of_id' do
    it 'round-trips with id_at_row in a live view' do
      (0...10).each do |row|
        id = described_class.id_at_row(row, lines_appended: 20, buffer_pos: 0, buffer_length: 20, height: 10)
        expect(described_class.row_of_id(id, lines_appended: 20, buffer_pos: 0, buffer_length: 20, height: 10)).to eq(row)
      end
    end

    it 'round-trips while scrolled' do
      id = described_class.id_at_row(3, lines_appended: 50, buffer_pos: 12, buffer_length: 50, height: 10)
      expect(described_class.row_of_id(id, lines_appended: 50, buffer_pos: 12, buffer_length: 50, height: 10)).to eq(3)
    end

    it 'returns nil when the line has scrolled off the bottom of the view' do
      # ID 20 is the newest line; scrolled up 15, it is below the viewport
      expect(described_class.row_of_id(20, lines_appended: 20, buffer_pos: 15, buffer_length: 20, height: 10)).to be_nil
    end

    it 'returns nil when the line is above the top of the view' do
      # ID 1 is the oldest of 20 lines; a 5-row live view shows only IDs 16..20
      expect(described_class.row_of_id(1, lines_appended: 20, buffer_pos: 0, buffer_length: 20, height: 5)).to be_nil
    end

    it 'returns nil for an evicted line' do
      # 30 appended but only 20 retained: IDs 1..10 are gone
      expect(described_class.row_of_id(5, lines_appended: 30, buffer_pos: 0, buffer_length: 20, height: 10)).to be_nil
    end
  end

  describe '.normalize' do
    it 'keeps an already-ordered selection unchanged' do
      expect(described_class.normalize(3, 2, 5, 7)).to eq([3, 2, 5, 7])
    end

    it 'swaps endpoints when dragged upward' do
      expect(described_class.normalize(5, 7, 3, 2)).to eq([3, 2, 5, 7])
    end

    it 'swaps columns when dragged right-to-left on one line' do
      expect(described_class.normalize(4, 9, 4, 2)).to eq([4, 2, 4, 9])
    end
  end

  describe '.extract' do
    let(:buffer) { buffer_for(5) } # IDs 1..5, "line 0" (oldest, ID 1) .. "line 4" (newest, ID 5)

    it 'extracts a single-line span' do
      expect(described_class.extract(buffer, 5, 2, 0, 2, 4)).to eq('line')
    end

    it 'extracts a multi-line span with partial first and last lines' do
      text = described_class.extract(buffer, 5, 2, 5, 4, 4)
      expect(text).to eq("1\nline 2\nline")
    end

    it 'extracts the same text regardless of drag direction' do
      down = described_class.extract(buffer, 5, 2, 5, 4, 4)
      up = described_class.extract(buffer, 5, 4, 4, 2, 5)
      expect(up).to eq(down)
    end

    it 'still extracts the anchored text after new lines are appended' do
      # Select "line 3" (ID 4) end-to-end, then 10 lines arrive
      grown = (5...15).map { |i| ["line #{i}", []] }.reverse + buffer
      expect(described_class.extract(grown, 15, 4, 0, 4, 6)).to eq('line 3')
    end

    it 'skips lines evicted past the buffer cap' do
      # IDs 1..2 evicted: buffer holds IDs 3..5 of 5 appended
      trimmed = buffer_for(5).first(3)
      expect(described_class.extract(trimmed, 5, 1, 0, 3, 6)).to eq('line 2')
    end

    it 'skips IDs newer than anything appended' do
      expect(described_class.extract(buffer, 5, 5, 0, 99, 6)).to eq('line 4')
    end

    it 'clamps columns past the end of a line' do
      expect(described_class.extract(buffer, 5, 3, 2, 3, 500)).to eq('ne 2')
    end

    it 'returns empty when the start column is past the end of a single-line span' do
      expect(described_class.extract(buffer, 5, 3, 500, 3, 900)).to eq('')
    end

    it 'returns empty for an entirely evicted span' do
      trimmed = buffer_for(5).first(2)
      expect(described_class.extract(trimmed, 5, 1, 0, 2, 6)).to eq('')
    end

    it 'treats a nil line text as empty rather than crashing' do
      with_nil = [[nil, []]] + buffer
      expect(described_class.extract(with_nil, 6, 5, 0, 6, 3)).to eq("line 4\n")
    end
  end

  describe '.extract with wrap continuations' do
    # A logical line wrapped to three display lines (indent adds 2 spaces,
    # StyledText#wrap keeps the break space on the previous line), then a
    # separate unwrapped line. Newest first, IDs 1..4.
    let(:wrapped) do
      [
        ['Next line', [], false],           # ID 4
        ['  the lazy dog', [], true],       # ID 3
        ['  fox jumps over ', [], true],    # ID 2
        ['The quick brown ', [], false]     # ID 1
      ]
    end

    it 'rejoins wrapped display lines into one logical line' do
      text = described_class.extract(wrapped, 4, 1, 0, 4, 9)
      expect(text).to eq("The quick brown fox jumps over the lazy dog\nNext line")
    end

    it 'joins partial pieces across a wrap boundary' do
      text = described_class.extract(wrapped, 4, 2, 2, 3, 8)
      expect(text).to eq('fox jumps over the la')
    end

    it 'does not join when the selection starts on a continuation line' do
      text = described_class.extract(wrapped, 4, 3, 0, 4, 4)
      expect(text).to eq("  the lazy dog\nNext")
    end

    it 'rejoins a hard mid-word break seamlessly' do
      hard = [['  efgh', [], true], ['abcd', [], false]]
      expect(described_class.extract(hard, 2, 1, 0, 2, 6)).to eq('abcdefgh')
    end

    it 'keeps a continuation intact when its wrap start was evicted' do
      trimmed = wrapped.first(3) # ID 1 ("The quick brown ") evicted
      text = described_class.extract(trimmed, 4, 1, 0, 4, 9)
      expect(text).to eq("  fox jumps over the lazy dog\nNext line")
    end
  end

  describe '.word_span' do
    let(:line) { 'get #40872332 from pack' }

    it 'spans the whitespace-delimited word under the column' do
      expect(described_class.word_span(line, 7)).to eq([4, 13])
      expect(line[4...13]).to eq('#40872332')
    end

    it 'spans a word from its first and last characters' do
      expect(described_class.word_span(line, 0)).to eq([0, 3])
      expect(described_class.word_span(line, 2)).to eq([0, 3])
    end

    it 'returns nil on whitespace' do
      expect(described_class.word_span(line, 3)).to be_nil
    end

    it 'returns nil for an empty or nil line' do
      expect(described_class.word_span('', 0)).to be_nil
      expect(described_class.word_span(nil, 0)).to be_nil
    end

    it 'clamps a column past the end of the line to the last word' do
      expect(described_class.word_span(line, 500)).to eq([19, 23])
    end
  end

  describe '.logical_line_span' do
    let(:wrapped) do
      [
        ['Next line', [], false],           # ID 4
        ['  the lazy dog', [], true],       # ID 3
        ['  fox jumps over ', [], true],    # ID 2
        ['The quick brown ', [], false]     # ID 1
      ]
    end

    it 'expands from a middle continuation to the full logical line' do
      expect(described_class.logical_line_span(wrapped, 4, 2)).to eq([1, 3])
    end

    it 'expands from the first display line forward' do
      expect(described_class.logical_line_span(wrapped, 4, 1)).to eq([1, 3])
    end

    it 'returns the line itself for an unwrapped line' do
      expect(described_class.logical_line_span(wrapped, 4, 4)).to eq([4, 4])
    end

    it 'stops the backward walk at an evicted line' do
      trimmed = wrapped.first(3) # ID 1 evicted
      expect(described_class.logical_line_span(trimmed, 4, 3)).to eq([2, 3])
    end
  end
end
