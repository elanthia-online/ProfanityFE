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
