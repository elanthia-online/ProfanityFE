# frozen_string_literal: true

# Tests WindowManager#resize's handling of the command window: after the
# terminal is resized, the command buffer is redrawn so its cursor and
# horizontal scroll offset fit the new command-window width.

require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../../lib/window_manager'
require_relative '../support/screen_line_window'

RSpec.describe WindowManager, '#resize' do
  subject(:wm) { described_class.new }

  let(:screen) { ScreenLineWindow.new(30) }
  let(:buf) { CommandBuffer.new }

  # No layout is loaded, so the command window is the only window to resize.
  before do
    # Curses.cols is 80 in the spec stub, so the command window becomes 10 wide.
    wm.install_command_window(WindowLayout.new(height: '1', width: 'cols-70', top: '23', left: '0')) { screen }
    buf.window = screen
    'abcdefghijklmnopqrstuvwxy'.each_char { |ch| buf.put_ch(ch) }
  end

  it 'redraws the command buffer for the new width' do
    wm.resize(buf)
    expect(screen.maxx).to eq 10
    expect(screen.errors).to be_empty
    expect(screen.line).to eq 'qrstuvwxy '
    expect(screen.curx).to eq 9
  end

  it 'leaves the command line usable for typing after the resize' do
    wm.resize(buf)
    buf.put_ch('Z')
    expect(screen.visible).to eq 'rstuvwxyZ'
    expect(screen.curx).to eq 9
  end

  it 'redraws after resizing and before the command window is flushed' do
    screen.call_log.clear
    wm.resize(buf)
    calls = screen.call_log.map(&:first)
    expect(calls.rindex(:setpos)).to be < calls.rindex(:noutrefresh)
    expect(calls.index(:resize)).to be < calls.index(:addstr)
  end

  it 'resizes the command window when there is no command buffer to redraw' do
    wm.resize(nil)

    expect(screen.maxx).to eq 10
  end
end
