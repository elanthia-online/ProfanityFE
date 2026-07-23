# frozen_string_literal: true

require_relative '../../lib/anchored_selection'
require_relative '../../lib/selection_manager'

# Minimal stand-in for TextWindow's selection surface: a newest-first
# buffer, a monotonic append counter, and the same AnchoredSelection
# delegation the real windows use. Lets us drive press/drag/release
# against a mutating buffer without curses.
class FakeBufferWindow
  attr_reader :buffer, :lines_appended, :highlights

  def initialize(height:)
    @height = height
    @buffer = []
    @lines_appended = 0
    @buffer_pos = 0
    @highlights = []
  end

  def add_line(text, continuation: false)
    @buffer.unshift([text, [], continuation])
    @lines_appended += 1
  end

  def buffer_content
    @buffer
  end

  def evict_to(count)
    @buffer.pop while @buffer.length > count
  end

  def selection_anchor_at(rel_y, rel_x)
    id = AnchoredSelection.id_at_row(rel_y, lines_appended: @lines_appended,
                                            buffer_pos: @buffer_pos,
                                            buffer_length: @buffer.length,
                                            height: @height)
    id ? [id, [rel_x, 0].max] : nil
  end

  def extract_selection(start_id, start_x, end_id, end_x)
    AnchoredSelection.extract(@buffer, @lines_appended, start_id, start_x, end_id, end_x)
  end

  def highlight_selection(start_id, start_x, end_id, end_x)
    @highlights << [start_id, start_x, end_id, end_x]
  end

  def clear_highlight; end
end

RSpec.describe SelectionManager do
  let(:window) { FakeBufferWindow.new(height: 10) }
  let(:copied) { [] }

  before do
    described_class.clear_selection
    allow(described_class).to receive(:copy_to_clipboard) { |text| copied << text }
  end

  after { described_class.clear_selection }

  def fill(window, count)
    count.times { |i| window.add_line("line #{i}") }
  end

  it 'copies the text under the cursor for a simple drag' do
    fill(window, 10) # rows 0..9 show "line 0".."line 9"
    described_class.start_selection(window, 3, 0)
    described_class.update_selection(3, 6)
    described_class.end_selection
    expect(copied).to eq(['line 3'])
  end

  it 'copies the pressed-on text even when new lines arrive mid-drag' do
    fill(window, 10)
    described_class.start_selection(window, 9, 0) # press on "line 9", bottom row
    3.times { |i| window.add_line("new #{i}") }   # "line 9" moves up to row 6
    described_class.update_selection(6, 6)        # release where it moved to
    described_class.end_selection
    expect(copied).to eq(['line 9'])
  end

  it 'anchors at press time, not release time' do
    fill(window, 10)
    described_class.start_selection(window, 9, 0)
    window.add_line('intruder')
    # Release on the same screen row the press landed on — which now
    # shows different text. The selection must span from the pressed
    # line to the line now under the cursor, not silently re-target.
    described_class.update_selection(9, 8)
    described_class.end_selection
    expect(copied).to eq(["line 9\nintruder"])
  end

  it 'copies nothing when the anchored lines have been evicted' do
    fill(window, 10)
    described_class.start_selection(window, 0, 0) # oldest line
    described_class.update_selection(0, 6)
    window.evict_to(5) # "line 0".."line 4" evicted
    described_class.end_selection
    expect(copied).to be_empty
  end

  it 'does not start a selection on an empty window' do
    described_class.start_selection(window, 3, 0)
    described_class.update_selection(5, 5)
    described_class.end_selection
    expect(copied).to be_empty
    expect(window.highlights).to be_empty
  end

  it 'ignores windows without a selection surface' do
    plain = Object.new
    def plain.selection_anchor_at(_y, _x) = nil
    def plain.clear_highlight; end
    described_class.start_selection(plain, 1, 1)
    described_class.update_selection(2, 2)
    described_class.end_selection
    expect(copied).to be_empty
  end

  it 'keeps raw press coordinates for the click-vs-drag heuristic' do
    fill(window, 10)
    described_class.start_selection(window, 4, 7)
    window.add_line('shift')
    expect(described_class.start_pos).to eq([4, 7])
  end

  it 'highlights with anchored IDs while dragging' do
    fill(window, 10)
    described_class.start_selection(window, 3, 2) # "line 3" => ID 4
    described_class.update_selection(5, 6)        # "line 5" => ID 6
    expect(window.highlights.last).to eq([4, 2, 6, 6])
  end

  it 'reports the number of characters copied' do
    fill(window, 10)
    described_class.start_selection(window, 3, 0)
    described_class.update_selection(3, 6)
    expect(described_class.end_selection).to eq(6)
  end

  describe 'live drag throttling' do
    it 'coalesces a motion flood into interval-spaced redraws' do
      fill(window, 10)
      described_class.start_selection(window, 0, 0, now: 0.0)
      redraws = [0.001, 0.002, 0.003, 0.06, 0.07, 0.13].map.with_index do |t, i|
        described_class.drag_update(1 + i, 2, now: t)
      end
      # First motion redraws; the rest only when 50ms have passed
      expect(redraws).to eq([true, false, false, true, false, true])
    end

    it 'records the drag position even when the redraw is throttled' do
      fill(window, 10)
      described_class.start_selection(window, 0, 0, now: 0.0)
      described_class.drag_update(1, 2, now: 0.001)
      described_class.drag_update(5, 7, now: 0.002) # throttled
      expect(described_class.last_drag_pos).to eq([5, 7])
    end

    it 'does nothing without an anchored selection' do
      expect(described_class.drag_update(1, 1, now: 0.0)).to be(false)
    end
  end

  describe 'multi-click selection' do
    it 'double-click selects the word under the cursor' do
      window.add_line('get #40872332 from pack') # row 0
      described_class.start_selection(window, 0, 7, now: 0.0)
      expanded = described_class.start_selection(window, 0, 7, now: 0.2)
      expect(expanded).to be(true)
      expect(described_class.multi_click_selected?).to be(true)
      described_class.end_selection
      expect(copied).to eq(['#40872332'])
    end

    it 'triple-click selects the whole logical (unwrapped) line' do
      window.add_line('The quick brown ')
      window.add_line('  fox jumps', continuation: true) # rows 0..1
      3.times { |i| described_class.start_selection(window, 1, 3, now: i * 0.1) }
      expect(described_class.multi_click_selected?).to be(true)
      described_class.end_selection
      expect(copied).to eq(['The quick brown fox jumps'])
    end

    it 'does not expand when the second click is too slow' do
      window.add_line('get #40872332 from pack')
      described_class.start_selection(window, 0, 7, now: 0.0)
      described_class.start_selection(window, 0, 7, now: 1.0)
      expect(described_class.multi_click_selected?).to be(false)
    end

    it 'does not expand when the clicks land apart' do
      window.add_line('get #40872332 from pack')
      described_class.start_selection(window, 0, 7, now: 0.0)
      described_class.start_selection(window, 0, 15, now: 0.1)
      expect(described_class.multi_click_selected?).to be(false)
    end

    it 'does not expand a double-click on whitespace' do
      window.add_line('a b')
      described_class.start_selection(window, 0, 1, now: 0.0)
      expanded = described_class.start_selection(window, 0, 1, now: 0.1)
      expect(expanded).to be(false)
      expect(described_class.multi_click_selected?).to be(false)
    end
  end

  it 'copies wrapped display lines as one logical line' do
    window.add_line('The quick brown ')
    window.add_line('  fox jumps', continuation: true)
    described_class.start_selection(window, 0, 0)
    described_class.update_selection(1, 11)
    described_class.end_selection
    expect(copied).to eq(['The quick brown fox jumps'])
  end
end
