# frozen_string_literal: true

# Tests SpanTracker on its own: opening and closing each kind of span, the
# runs a close records, and what each kind does at a mid-line flush, with
# the line's last text and at the end of the line. The same behaviour
# through the real parser is pinned in span_lifecycle_spec.rb.

require_relative '../../lib/span_tracker'

RSpec.describe SpanTracker do
  subject(:spans) { described_class.new }

  let(:red) { { fg: 'ff0000', bg: nil } }

  describe '#open / #close' do
    it 'records a run with the start, the attributes in the order given, then the end' do
      spans.open(:link, 2, fg: 'a', bg: nil, cmd: 'look')
      spans.close(:link, 6)
      run = spans.runs.first
      expect(run).to eq(start: 2, fg: 'a', bg: nil, cmd: 'look', end: 6)
      expect(run.keys).to eq %i[start fg bg cmd end]
    end

    it 'closes the innermost span of a stacking kind first' do
      spans.open(:bold, 0, **red)
      spans.open(:bold, 3, **red)
      spans.close(:bold, 5)
      spans.close(:bold, 9)
      expect(spans.runs).to eq [{ start: 3, **red, end: 5 }, { start: 0, **red, end: 9 }]
    end

    it 'keeps kinds apart: closing one kind leaves the others open' do
      spans.open(:bold, 0, **red)
      spans.open(:color, 1, fg: 'b')
      expect(spans.close(:preset, 4)).to be_nil
      spans.close(:bold, 4)
      expect(spans.runs).to eq [{ start: 0, **red, end: 4 }]
      expect(spans.open_span(:color)).to eq(start: 1, fg: 'b')
    end

    it 'gives a style a single slot: a second open replaces the first' do
      spans.open(:style, 0, **red)
      spans.open(:style, 4, fg: 'b', bg: nil)
      spans.close(:style, 6)
      expect(spans.runs).to eq [{ start: 4, fg: 'b', bg: nil, end: 6 }]
      expect(spans.close(:style, 8)).to be_nil
    end

    it 'returns nil and yields nothing when no span of the kind is open' do
      expect { |b| expect(spans.close(:link, 3, &b)).to be_nil }.not_to yield_control
      expect(spans.runs).to be_empty
    end

    it 'yields the span with its end set, before deciding whether it records a run' do
      spans.open(:link, 1, fg: 'a', bg: nil, cmd: nil)
      spans.close(:link, 4) { |span| span[:cmd] = "x#{span[:start]}-#{span[:end]}" }
      expect(spans.runs).to eq [{ start: 1, fg: 'a', bg: nil, cmd: 'x1-4', end: 4 }]
    end

    it 'raises on an unknown kind' do
      expect { spans.open(:blink, 0) }.to raise_error(KeyError)
      expect { spans.close(:blink, 0) }.to raise_error(KeyError)
    end

    {
      bold: [false, true, true, true],
      preset: [false, true, true, true],
      link: [false, true, true, true],
      color: [true, true, true, true],
      style: [false, true, false, false]
    }.each do |kind, (plain, colored, colored_empty, bg_only_empty)|
      it "records a #{kind} run: uncolored #{plain}, colored #{colored}, colored but empty #{colored_empty}" do
        record = lambda do |start, end_pos, **attrs|
          tracker = described_class.new
          tracker.open(kind, start, **attrs)
          tracker.close(kind, end_pos)
          !tracker.runs.empty?
        end
        expect(record.call(0, 3)).to be plain
        expect(record.call(0, 3, **red)).to be colored
        expect(record.call(2, 2, **red)).to be colored_empty
        expect(record.call(3, 3, fg: nil, bg: '00ff00')).to be bg_only_empty
      end
    end
  end

  describe '#split_at_flush' do
    it 'records runs for bold, preset, style and color in that order, after the runs already closed' do
      spans.open(:color, 0, fg: 'c')
      spans.open(:link, 0, fg: 'l', bg: nil, cmd: 'go')
      spans.open(:style, 0, fg: 's', bg: nil)
      spans.open(:preset, 1, fg: 'p', bg: nil)
      spans.open(:bold, 2, **red)
      spans.open(:color, 1, fg: 'x')
      spans.close(:color, 2)
      expect(spans.split_at_flush(5)).to eq [
        { start: 1, fg: 'x', end: 2 },
        { start: 2, **red, end: 5 },
        { start: 1, fg: 'p', bg: nil, end: 5 },
        { start: 0, fg: 's', bg: nil, end: 5 },
        { start: 0, fg: 'c', end: 5 }
      ]
    end

    it 'restarts the spans it splits at 0, and drops open links' do
      spans.open(:bold, 2, **red)
      spans.open(:link, 1, fg: 'l', bg: nil, cmd: 'go')
      spans.split_at_flush(5)
      expect(spans.open_span(:bold)).to eq(start: 0, **red)
      expect(spans.open_span(:link)).to be_nil
      expect(spans.close(:link, 3)).to be_nil
      spans.close(:bold, 3)
      expect(spans.split_at_flush(4)).to eq [{ start: 0, **red, end: 3 }]
    end

    it 'records uncolored bold and preset nothing, but still restarts them; uncolored style and color record' do
      spans.open(:bold, 1)
      spans.open(:preset, 1)
      spans.open(:style, 2)
      spans.open(:color, 3)
      expect(spans.split_at_flush(4)).to eq [{ start: 2, end: 4 }, { start: 3, end: 4 }]
      expect(spans.open_span(:bold)).to eq(start: 0)
      expect(spans.open_span(:preset)).to eq(start: 0)
    end

    it 'records a split even when the span is empty' do
      spans.open(:style, 4, **red)
      expect(spans.split_at_flush(4)).to eq [{ start: 4, **red, end: 4 }]
    end

    it 'hands over the list: runs recorded later go into a new one' do
      spans.open(:color, 0, fg: 'c')
      handed = spans.split_at_flush(2)
      spans.close(:color, 1)
      expect(handed).to eq [{ start: 0, fg: 'c', end: 2 }]
      expect(spans.runs).to eq [{ start: 0, fg: 'c', end: 1 }]
    end
  end

  describe '#split_at_line_end' do
    it 'records style and color to the end of the text, and not bold or preset' do
      spans.open(:bold, 0, **red)
      spans.open(:preset, 0, **red)
      spans.open(:style, 1, fg: 's', bg: nil)
      spans.open(:color, 2, fg: 'c')
      expect(spans.split_at_line_end(6)).to eq [{ start: 1, fg: 's', bg: nil, end: 6 }, { start: 2, fg: 'c', end: 6 }]
    end

    it 'drops open links' do
      spans.open(:link, 0, fg: 'l', bg: nil, cmd: 'go')
      expect(spans.split_at_line_end(3)).to be_empty
      expect(spans.open_span(:link)).to be_nil
    end
  end

  describe '#end_line' do
    it 'drops bold, preset and color, and keeps a style for the next line from 0' do
      %i[bold preset color].each { |kind| spans.open(kind, 1, **red) }
      spans.open(:style, 1, **red)
      spans.split_at_line_end(3)
      spans.end_line
      expect(%i[bold preset color link].map { |kind| spans.open_span(kind) }).to all(be_nil)
      expect(spans.split_at_line_end(2)).to eq [{ start: 0, **red, end: 2 }]
    end

    it 'after #prompt, drops a style too, and only at the end of that line' do
      spans.prompt
      spans.open(:style, 1, **red)
      expect(spans.split_at_line_end(3)).to eq [{ start: 1, **red, end: 3 }]
      spans.end_line
      expect(spans.open_span(:style)).to be_nil
      spans.open(:style, 0, **red)
      spans.end_line
      expect(spans.open_span(:style)).to eq(start: 0, **red)
    end

    it 'leaves the runs recorded alone (a line that failed keeps them)' do
      spans.open(:color, 0, fg: 'c')
      spans.close(:color, 1)
      spans.end_line
      expect(spans.runs).to eq [{ start: 0, fg: 'c', end: 1 }]
    end

    it 'leaves an open link alone (a line that failed before its last text keeps it)' do
      spans.open(:link, 0, fg: 'l', bg: nil, cmd: 'go')
      spans.end_line
      expect(spans.open_span(:link)).to eq(start: 0, fg: 'l', bg: nil, cmd: 'go')
    end
  end

  describe 'copies' do
    it '#runs and #open_span return copies' do
      spans.open(:color, 0, fg: 'c')
      spans.open_span(:color)[:start] = 9
      spans.runs << { start: 0, end: 1 }
      expect(spans.runs).to be_empty
      expect(spans.split_at_line_end(2)).to eq [{ start: 0, fg: 'c', end: 2 }]
    end
  end

  describe 'the room marks (ROOM_MARKS)' do
    subject(:marks) { described_class.new(described_class::ROOM_MARKS) }

    it 'tracks only bold and links' do
      expect(described_class::ROOM_MARKS.keys).to eq %i[bold link]
      expect { marks.open(:preset, 0) }.to raise_error(KeyError)
      expect { marks.close(:color, 0) }.to raise_error(KeyError)
    end

    it 'records a bold mark without a color, at a close and at a flush' do
      marks.open(:bold, 2, mark: :bold)
      marks.close(:bold, 5)
      marks.open(:bold, 7, mark: :bold)
      expect(marks.split_at_flush(9)).to eq [{ start: 2, mark: :bold, end: 5 }, { start: 7, mark: :bold, end: 9 }]
      marks.close(:bold, 3)
      expect(marks.split_at_line_end(4)).to eq [{ start: 0, mark: :bold, end: 3 }]
    end

    it 'records an empty bold mark' do
      marks.open(:bold, 4, mark: :bold)
      marks.close(:bold, 4)
      expect(marks.runs).to eq [{ start: 4, mark: :bold, end: 4 }]
    end

    it 'records a link mark without a color or a command' do
      marks.open(:link, 1, mark: :link, cmd: nil)
      marks.close(:link, 3)
      expect(marks.runs).to eq [{ start: 1, mark: :link, cmd: nil, end: 3 }]
    end

    it 'drops an open link at a flush, and records nothing for it' do
      marks.open(:link, 1, mark: :link, cmd: 'go')
      expect(marks.split_at_flush(4)).to be_empty
      expect(marks.close(:link, 6)).to be_nil
      expect(marks.runs).to be_empty
    end

    it 'closes nested links innermost first' do
      marks.open(:link, 0, mark: :link, cmd: 'a')
      marks.open(:link, 1, mark: :link, cmd: 'b')
      marks.close(:link, 2)
      marks.close(:link, 3)
      expect(marks.runs).to eq [{ start: 1, mark: :link, cmd: 'b', end: 2 }, { start: 0, mark: :link, cmd: 'a', end: 3 }]
    end

    it 'records nothing for bold open at the last text, and drops it at the end of the line' do
      marks.open(:bold, 2, mark: :bold)
      expect(marks.split_at_line_end(5)).to be_empty
      marks.end_line
      expect(marks.close(:bold, 1)).to be_nil
    end

    # Characterization (passes before ROOM_MARKS too): the default rules
    # are unchanged.
    it 'leaves the color runs of a tracker built with the default rules alone' do
      colors = described_class.new
      colors.open(:bold, 0)
      colors.close(:bold, 2)
      expect(colors.runs).to be_empty
    end
  end
end
