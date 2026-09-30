# frozen_string_literal: true

# Tests that a resize re-wraps only the shown tab of a tabbed window, and
# that a hidden tab, re-wrapped when it is shown, looks exactly as if it
# had been re-wrapped at every resize: its rows, its place when scrolled
# back, lines that arrived meanwhile, evictions past the buffer size, and
# the prompt checks that read its newest line. Windows are built from
# layout XML and draw onto the virtual screen
# (spec/support/virtual_screen.rb); the terminal width is stubbed.

require 'rexml/document'
require_relative '../../lib/window_manager'
require_relative '../../lib/prompt_tracker'
require_relative '../../lib/pending_render'
require_relative '../../lib/shared_state'
require_relative '../../lib/event_bus'

RSpec.describe TabbedTextWindow, 'resized with hidden tabs' do
  subject(:wm) { WindowManager.new }

  # The tab bar on row 0 and 3 rows of text below it. At 80 columns the
  # window is 40 wide (39 of text, wrapping at 38), at 48 columns 24 wide
  # (wrapping at 22), at 120 columns 60 wide (wrapping at 58).
  let(:window) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='tabbed' top='0' left='0' height='4' width='cols/2' tabs='main,combat,assess' buffer-size='#{buffer_size}'/>
      </layout>
    XML
    wm.load_layout('test')
    wm.stream['main']
  end
  let(:buffer_size) { 1000 }
  let(:long_line) { 'one two three four five six seven' }

  before { allow(Curses).to receive(:cols).and_return(80) }

  # Change the terminal width and resize the windows.
  def resize_to(new_cols)
    allow(Curses).to receive(:cols).and_return(new_cols)
    wm.resize(nil)
  end

  # @return [Array<String>] the visible text rows below the tab bar
  def text_rows
    window.rows.drop(TabbedTextWindow::TAB_BAR_HEIGHT)
  end

  # Record the text of every line word-wrapped from now on.
  #
  # @return [Array<String>] filled as lines are wrapped
  def wrapped_lines
    texts = []
    allow_any_instance_of(StyledText).to receive(:wrap).and_wrap_original do |original, *args, **opts|
      texts << original.receiver.text
      original.call(*args, **opts)
    end
    texts
  end

  it 're-wraps only the shown tab on a resize, and a hidden tab once, when it is shown' do
    window.add_string_to_tab('main', long_line)
    3.times { |i| window.add_string_to_tab('combat', "combat #{i} #{long_line}") }
    window.add_string_to_tab('assess', "assess #{long_line}")
    wrapped = wrapped_lines

    resize_to(48)
    resize_to(120)
    resize_to(48)

    expect(wrapped).to eq [long_line] * 3

    wrapped.clear
    window.switch_tab('combat')

    expect(wrapped).to eq(Array.new(3) { |i| "combat #{i} #{long_line}" })
    expect(text_rows).to eq ['combat 2 one two', '  three four five six', '  seven']
  end

  it 'does not re-wrap a hidden tab for lines arriving in it or a lowered buffer-size' do
    3.times { |i| window.add_string_to_tab('combat', "combat #{i}") }
    resize_to(48)
    wrapped = wrapped_lines

    window.add_string_to_tab('combat', 'combat 3')
    window.max_buffer_size = 2

    expect(wrapped).to be_empty
  end

  it 'wraps only the newest line of each hidden tab for the movement check at a blank line' do
    3.times { |i| window.add_string_to_tab('combat', "combat #{i}") }
    2.times { |i| window.add_string_to_tab('assess', "assess #{i}") }
    resize_to(48)
    wrapped = wrapped_lines
    event_bus = EventBus.new
    prompts = []
    event_bus.on(:add_prompt) { |data| prompts << data[:text] }
    state = SharedState.new.tap do |shared|
      shared.prompt_text = 'H>'
      shared.need_prompt = true
    end

    PromptTracker.new(shared_state: state, event_bus: event_bus, pending_render: PendingRender.new,
                      window_mgr: wm).blank_line

    expect(prompts).to eq ['H>']
    expect(wrapped).to eq ['combat 2', 'assess 1']
  end

  it 'wraps only the newest line of a hidden main tab to check for a repeated prompt' do
    3.times { |i| window.add_string_to_tab('main', "main #{i}") }
    window.switch_tab('combat')
    resize_to(48)
    wrapped = wrapped_lines

    wm.add_prompt(window, 'H>')
    wm.add_prompt(window, 'H>')

    expect(wrapped).to eq ['main 2', 'H>']
    window.switch_tab('main')
    expect(text_rows).to eq ['main 1', 'main 2', 'H>']
  end

  it 'shows a hidden tab wrapped to the width at the time it is shown' do
    window.add_string_to_tab('combat', long_line)

    resize_to(48)
    resize_to(120)
    window.switch_tab('combat')

    expect(text_rows).to eq [long_line, '', '']
  end

  it 'shows lines that arrived in a hidden tab after a resize wrapped to the current width' do
    window.add_string_to_tab('combat', 'c1')
    resize_to(48)
    window.add_string_to_tab('combat', long_line)

    window.switch_tab('combat')

    expect(text_rows).to eq ['c1', 'one two three four', '  five six seven']
  end

  it 'keeps a scrolled-back hidden tab on the line that was on its bottom row' do
    window.switch_tab('combat')
    (%w[c1 c2 c3 c4] + [long_line, 'c6']).each { |line| window.add_string(line) }
    window.scroll_lines(-2)
    expect(text_rows).to eq %w[c2 c3 c4]
    window.switch_tab('main')

    resize_to(48)
    window.switch_tab('combat')

    expect(text_rows).to eq %w[c2 c3 c4]
    window.scroll_lines(window.buffer_pos)
    expect(text_rows).to eq ['one two three four', '  five six seven', 'c6']
  end

  it 'keeps where each resize left a scrolled-back hidden tab, as re-wrapping at every resize does' do
    resize_to(48)
    window.switch_tab('combat')
    ['c1', long_line, 'c3', 'c4'].each { |line| window.add_string(line) }
    window.scroll_lines(-3)
    expect(text_rows).to eq ['c1', 'one two three four', '  five six seven']
    window.switch_tab('main')

    # Wider, the long line takes one row: the view moves down to show the
    # oldest rows, and c3 is on its bottom row, where the next re-wrap
    # keeps it
    resize_to(80)
    resize_to(48)
    window.switch_tab('combat')

    expect(text_rows).to eq ['one two three four', '  five six seven', 'c3']
  end

  it "moves a hidden tab's view from the middle of a line to the line's last row on a resize" do
    resize_to(48)
    window.switch_tab('combat')
    ['c0', 'c1', 'c2', "#{long_line} #{long_line}", 'c4', 'c5'].each { |line| window.add_string(line) }
    window.scroll_lines(-5)
    expect(text_rows).to eq ['c1', 'c2', 'one two three four']
    window.switch_tab('main')

    resize_to(80)
    window.switch_tab('combat')

    expect(text_rows).to eq ['c2', 'one two three four five six seven one', '  two three four five six seven']
  end

  context 'with a buffer-size of 5' do
    let(:buffer_size) { 5 }

    it 'moves a scrolled-back hidden tab onto the oldest line left when lines arrive past the cap' do
      window.switch_tab('combat')
      %w[c1 c2 c3 c4 c5].each { |line| window.add_string(line) }
      window.scroll_lines(-2)
      window.switch_tab('main')
      resize_to(48)

      window.add_string_to_tab('combat', long_line)
      window.add_string_to_tab('combat', 'c7')
      window.switch_tab('combat')

      # The long line pushed the view back two rows and evicted c1; c7
      # pushed it back one and evicted c2: each time it moved down to the
      # oldest rows left
      expect(text_rows).to eq %w[c3 c4 c5]
      window.scroll_lines(window.buffer_pos)
      expect(text_rows).to eq ['one two three four', '  five six seven', 'c7']
    end

    it 'keeps a hidden tab on the oldest rows, part of a line, when long lines evict the short ones' do
      window.switch_tab('combat')
      %w[c1 c2 c3 c4 c5].each { |line| window.add_string(line) }
      window.scroll_lines(-2)
      window.switch_tab('main')
      resize_to(48)

      5.times { |i| window.add_string_to_tab('combat', "b#{i} #{long_line} #{long_line}") }
      window.switch_tab('combat')

      # Each long line takes 4 rows; the view is on the oldest 3
      expect(text_rows).to eq ['b0 one two three four', '  five six seven one', '  two three four five']
      window.scroll_lines(1)
      expect(text_rows).to eq ['  five six seven one', '  two three four five', '  six seven']
    end

    it 'moves a scrolled-back hidden tab onto the oldest line left when the buffer-size is lowered' do
      window.switch_tab('combat')
      %w[c1 c2 c3 c4 c5].each { |line| window.add_string(line) }
      window.scroll_lines(-2)
      window.switch_tab('main')
      resize_to(48)

      window.max_buffer_size = 4
      window.switch_tab('combat')

      expect(text_rows).to eq %w[c2 c3 c4]
    end

    it 'drops the oldest lines of a hidden tab when a layout lowers the buffer-size' do
      window.switch_tab('combat')
      ['c1', 'c2', 'c3', long_line, 'c5'].each { |line| window.add_string(line) }
      window.switch_tab('main')
      resize_to(48)

      LAYOUT['small'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='tabbed' top='0' left='0' height='4' width='cols/3' tabs='main,combat,assess' buffer-size='2'/>
        </layout>
      XML
      wm.load_layout('small')
      window.switch_tab('combat')

      expect(wm.stream['combat']).to be window
      # 16 wide at 48 columns: wrapping at 14
      expect(text_rows).to eq ['  four five', '  six seven', 'c5']
      window.scroll_lines(-5)
      expect(text_rows).to eq ['one two three', '  four five', '  six seven']
    end
  end

  context 'with a window the terminal height sizes' do
    # 3 text rows at 24 lines, none (the tab bar alone) at 21
    let(:window) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='tabbed' top='0' left='0' height='lines-20' width='cols/2' tabs='main,combat' buffer-size='5'/>
        </layout>
      XML
      wm.load_layout('test')
      wm.stream['main']
    end

    before { allow(Curses).to receive(:lines).and_return(24) }

    it 'shows the newest lines of a hidden tab scrolled back past its oldest line while the window had no text rows' do
      window.switch_tab('combat')
      %w[c1 c2 c3 c4 c5].each { |line| window.add_string(line) }
      window.scroll_lines(-2)
      window.switch_tab('main')
      allow(Curses).to receive(:lines).and_return(21)
      resize_to(48)
      %w[c6 c7 c8].each { |line| window.add_string_to_tab('combat', line) }

      allow(Curses).to receive(:lines).and_return(24)
      resize_to(80)
      window.switch_tab('combat')

      expect(text_rows).to eq %w[c6 c7 c8]
    end
  end

  it 'shows a repeated prompt once in a hidden main tab after a resize' do
    window.add_string_to_tab('main', long_line)
    wm.add_prompt(window, 'H>')
    window.switch_tab('combat')
    resize_to(48)

    wm.add_prompt(window, 'H>')
    window.switch_tab('main')

    expect(text_rows).to eq ['one two three four', '  five six seven', 'H>']
  end
end
