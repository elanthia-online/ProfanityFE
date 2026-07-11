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

  def add_line(text)
    @buffer.unshift([text, []])
    @lines_appended += 1
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
end
