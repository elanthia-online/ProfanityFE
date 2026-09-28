# frozen_string_literal: true

# Tests TabbedTextWindow as a user sees it: windows are built from layout XML
# by WindowManager and draw onto the virtual screen (spec/support/virtual_screen.rb).

require 'rexml/document'
require_relative '../../../lib/window_manager'

RSpec.describe TabbedTextWindow do
  # A tabbed window 4 rows high and 12 columns wide: the tab bar on row 0
  # and 3 rows of text below it. The builder keeps one column for the
  # scrollbar, so text wraps at 10 characters.
  let(:window) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='tabbed' top='0' left='0' height='4' width='12' tabs='main'/></layout>
    XML
    window_manager = WindowManager.new
    window_manager.load_layout('test')
    window_manager.stream['main']
  end

  # @return [Array<String>] the visible text rows below the tab bar
  def text_rows
    window.rows.drop(TabbedTextWindow::TAB_BAR_HEIGHT)
  end

  # @return [Array<Integer>] the tab-bar columns drawn in reverse video
  def reverse_columns
    (0...window.maxx).select { |x| window.attrs_at(0, x).anybits?(Curses::A_REVERSE) }
  end

  context 'when the tab bar is wider than the window' do
    # The full bar, ' 1:main | 2:combat | 3:thoughts ', needs 32 columns;
    # the window has 11.
    let(:window) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout><window class='tabbed' top='0' left='0' height='4' width='12' tabs='main,combat,thoughts'/></layout>
      XML
      window_manager = WindowManager.new
      window_manager.load_layout('test')
      window_manager.stream['main']
    end

    before { %w[l1 l2 l3].each { |line| window.add_string(line) } }

    it 'cuts the bar off at the right edge when a background tab gets text' do
      window.add_string_to_tab('combat', 'c1')

      expect(window.rows).to eq [' 1:main | 2', 'l1', 'l2', 'l3']
    end

    it 'keeps the bar on its row when switching to a tab past the right edge and back' do
      window.switch_tab('thoughts')
      expect(window.rows).to eq [' 1:main | 2', '', '', '']
      expect(reverse_columns).to be_empty

      window.switch_tab('main')
      expect(window.rows).to eq [' 1:main | 2', 'l1', 'l2', 'l3']
      expect(reverse_columns).to eq (0..7).to_a
    end
  end

  context 'when the window is one row high and the tab bar reaches its right edge' do
    # ' 1:main ' fills all 8 columns. Writing a one-row window's last
    # column scrolls it, so the bar leaves that column blank.
    let(:window) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout><window class='tabbed' top='0' left='0' height='1' width='9' tabs='main'/></layout>
      XML
      window_manager = WindowManager.new
      window_manager.load_layout('test')
      window_manager.stream['main']
    end

    it 'shows the bar up to the last column' do
      window.draw_tab_bar

      expect(window.rows).to eq [' 1:main']
      expect(reverse_columns).to eq (0..6).to_a
    end
  end

  it 'shows the newest lines below the tab bar once the tab is full' do
    %w[l1 l2 l3 l4 l5].each { |line| window.add_string(line) }

    expect(window.rows).to eq [' 1:main', 'l3', 'l4', 'l5']
  end

  it 'draws a blank line as an empty row between its neighbours, like a text window' do
    ['l1', '', 'l2'].each { |line| window.add_string(line) }

    expect(text_rows).to eq ['l1', '', 'l2']
  end

  it 'shows a blank line again when scrolled back to it' do
    ['l1', '', 'l2', 'l3', 'l4'].each { |line| window.add_string(line) }

    window.scroll(-2)

    expect(text_rows).to eq ['l1', '', 'l2']
  end

  context 'when the window is two rows high' do
    # One text row below the tab bar. ncurses refuses a scroll region of
    # one row. The height follows the terminal (24 rows in specs), so a
    # resize can make the window taller.
    let(:window_manager) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout><window class='tabbed' top='0' left='0' height='lines-22' width='12' tabs='main'/></layout>
      XML
      WindowManager.new.tap { |manager| manager.load_layout('test') }
    end
    let(:window) { window_manager.stream['main'] }

    before { %w[l1 l2 l3].each { |line| window.add_string(line) } }

    it 'keeps the tab bar and shows the newest line as lines arrive' do
      expect(window.rows).to eq [' 1:main', 'l3']
    end

    it 'keeps the tab bar when scrolled back and forward' do
      window.scroll(-1)
      expect(window.rows).to eq [' 1:main', 'l2']

      window.scroll(1)
      expect(window.rows).to eq [' 1:main', 'l3']
    end

    it 'keeps the tab bar as lines arrive once a resize makes the window taller' do
      allow(Curses).to receive(:lines).and_return(26)
      window_manager.resize(nil)

      %w[l4 l5 l6].each { |line| window.add_string(line) }

      expect(window.rows).to eq [' 1:main', 'l4', 'l5', 'l6']
    end
  end

  it 'removes the reverse-video highlight from the text when the selection is cleared' do
    %w[l1 l2 l3].each { |line| window.add_string(line) }
    line_id, = window.selection_anchor_at(2, 0)
    window.highlight_selection(line_id, 0, line_id, 2)

    window.clear_highlight

    text_area = (TabbedTextWindow::TAB_BAR_HEIGHT...window.maxy).to_a.product((0...window.maxx).to_a)
    expect(text_area.select { |y, x| window.attrs_at(y, x).anybits?(Curses::A_REVERSE) }).to be_empty
    expect(text_rows).to eq %w[l1 l2 l3]
  end

  it 'shows a full page of older lines after a page-up of the whole text area' do
    %w[l1 l2 l3 l4 l5 l6 l7 l8 l9].each { |line| window.add_string(line) }

    window.scroll(-window.content_height)

    expect(window.rows).to eq [' 1:main', 'l4', 'l5', 'l6']
  end

  context 'when lines arrive for a tab the user is not viewing' do
    # A wider window (the tab bar fits on its row) with a second tab.
    let(:window) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout><window class='tabbed' top='0' left='0' height='4' width='24' tabs='main,combat'/></layout>
      XML
      window_manager = WindowManager.new
      window_manager.load_layout('test')
      window_manager.stream['main']
    end

    before do
      %w[m1 m2 m3].each { |line| window.add_string_to_tab('main', line) }
      %w[c1 c2 c3 c4 c5].each { |line| window.add_string_to_tab('combat', line) }
    end

    it 'keeps a scrolled-back tab in place, so it shows the same lines on switching back' do
      window.switch_tab('combat')
      window.scroll(-1)
      window.switch_tab('main')

      %w[c6 c7].each { |line| window.add_string_to_tab('combat', line) }
      window.switch_tab('combat')

      expect(text_rows).to eq %w[c2 c3 c4]
    end

    it 'keeps a live tab live, so it shows the newest lines on switching back' do
      %w[c6 c7].each { |line| window.add_string_to_tab('combat', line) }
      window.switch_tab('combat')

      expect(text_rows).to eq %w[c5 c6 c7]
    end

    it 'leaves the shown tab on screen while a scrolled-back tab takes new lines' do
      window.switch_tab('combat')
      window.scroll(-1)
      window.switch_tab('main')

      %w[c6 c7].each { |line| window.add_string_to_tab('combat', line) }

      expect(window.rows).to eq [' 1:main | 2:combat*', 'm1', 'm2', 'm3']
    end

    context 'when that tab is full and scrolled back to its oldest lines' do
      # Same window, keeping only 6 lines per tab.
      let(:window) do
        LAYOUT['test'] = REXML::Document.new(<<~XML).root
          <layout><window class='tabbed' top='0' left='0' height='4' width='24' tabs='main,combat' buffer-size='6'/></layout>
        XML
        window_manager = WindowManager.new
        window_manager.load_layout('test')
        window_manager.stream['main']
      end

      it 'moves the view past each evicted oldest line, as a shown tab does' do
        window.add_string_to_tab('combat', 'c6')
        window.switch_tab('combat')
        window.scroll(-window.content_height)
        window.switch_tab('main')

        %w[c7 c8].each { |line| window.add_string_to_tab('combat', line) }
        window.switch_tab('combat')

        expect(text_rows).to eq %w[c3 c4 c5]
      end
    end
  end

  context 'when evictions in a scrolled-back background tab drop the rows it showed' do
    # Two tabs keeping 3 lines each; text wraps at 19 columns.
    let(:window) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout><window class='tabbed' top='0' left='0' height='4' width='21' tabs='main,combat' buffer-size='3'/></layout>
      XML
      window_manager = WindowManager.new
      window_manager.load_layout('test')
      window_manager.stream['main']
    end

    it 'shows the lines left when the tab is shown again' do
      ['one two three four five six seven eight', 'nine ten eleven twelve thirteen fourteen', 'l1'].each do |line|
        window.add_string(line)
      end
      window.scroll(-window.content_height)
      window.switch_tab('combat')

      %w[l2 l3].each { |line| window.add_string_to_tab('main', line) }
      window.switch_tab('main')

      expect(text_rows).to eq %w[l1 l2 l3]
    end
  end

  context 'when the buffer is full and the user has scrolled back to its oldest lines' do
    # Same window, but keeping only 6 lines per tab.
    let(:window) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout><window class='tabbed' top='0' left='0' height='4' width='12' tabs='main' buffer-size='6'/></layout>
      XML
      window_manager = WindowManager.new
      window_manager.load_layout('test')
      window_manager.stream['main']
    end

    before do
      %w[l1 l2 l3 l4 l5 l6].each { |line| window.add_string(line) }
      window.scroll(-window.content_height)
    end

    it 'moves the view past the evicted oldest line and draws the next line on the bottom row' do
      window.add_string('l7')

      expect(text_rows).to eq %w[l2 l3 l4]
    end

    it 'shows the newest lines after scrolling back down past the new lines' do
      %w[l7 l8].each { |line| window.add_string(line) }

      window.scroll(window.content_height)

      expect(text_rows).to eq %w[l6 l7 l8]
    end
  end

  context 'when the window is one row high' do
    # The tab bar takes the only row, leaving no rows for text. The
    # height follows the terminal (24 rows in specs), so a resize can
    # make the window taller.
    let(:window_manager) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout><window class='tabbed' top='0' left='0' height='lines-23' width='12' tabs='main'/></layout>
      XML
      WindowManager.new.tap { |manager| manager.load_layout('test') }
    end
    let(:window) { window_manager.stream['main'] }

    # Each example starts from a correctly drawn tab bar.
    before do
      %w[l1 l2 l3].each { |line| window.add_string(line) }
      window.redraw
    end

    it 'shows just the tab bar as lines arrive' do
      window.add_string('l4')

      expect(window.rows).to eq [' 1:main']
      expect((0...window.maxx).select { |x| window.attrs_at(0, x).anybits?(Curses::A_REVERSE) }).to eq (0..7).to_a
    end

    it 'shows just the tab bar when scrolled back and forward' do
      window.scroll(-1)
      expect(window.rows).to eq [' 1:main']

      window.scroll(1)
      expect(window.rows).to eq [' 1:main']
    end

    it 'shows just the tab bar when a drag reaches its top row' do
      window.drag_auto_scroll(0)

      expect(window.rows).to eq [' 1:main']
    end

    it 'shows just the tab bar when text is highlighted and the highlight cleared' do
      window.highlight_selection(1, 0, 3, 2)
      expect(window.rows).to eq [' 1:main']

      window.clear_highlight
      expect(window.rows).to eq [' 1:main']
    end

    it 'shows just the tab bar after the terminal is resized' do
      window_manager.resize(nil)

      expect(window.rows).to eq [' 1:main']
    end

    it 'shows the kept lines once a resize makes the window taller' do
      window.scroll(-1)
      window.add_string('l4')
      allow(Curses).to receive(:lines).and_return(27)

      window_manager.resize(nil)

      expect(window.rows).to eq [' 1:main', 'l2', 'l3', 'l4']
    end
  end
end
