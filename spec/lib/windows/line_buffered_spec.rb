# frozen_string_literal: true

# Tests the viewport TextWindow and TabbedTextWindow share (LineBuffered)
# as a user sees it, on both windows: the same text-area behaviour whether
# the text area is the whole window or the rows below a tab bar. Windows
# are built from layout XML and draw onto the virtual screen
# (spec/support/virtual_screen.rb).

require 'rexml/document'
require_relative '../../../lib/window_manager'

RSpec.describe LineBuffered do
  # Build the window for one layout element and return the window
  # serving the main stream.
  def build(window_xml)
    LAYOUT['test'] = REXML::Document.new("<layout>#{window_xml}</layout>").root
    window_manager = WindowManager.new
    window_manager.load_layout('test')
    window_manager.stream['main']
  end

  # Both windows have 3 text rows, 20 columns of text and a scrollbar.
  shared_examples 'a line-buffer text area' do
    # @return [Array<String>] the visible text-area rows
    def text_rows
      window.rows.drop(window.content_top)
    end

    # @return [Integer] the window row of a text-area row
    def window_row(text_row)
      window.content_top + text_row
    end

    before { %w[l1 l2 l3 l4 l5].each { |line| window.add_string(line) } }

    it 'opens the link on the text-area row the user clicks' do
      window.add_string('go north', [{ start: 3, end: 8, cmd: 'north' }])

      expect(window.link_cmd_at(window_row(2), 4)).to eq 'north'
      expect(window.link_cmd_at(window_row(1), 4)).to be_nil
    end

    it 'copies the text shown on the text-area rows the user selects' do
      start_id, = window.selection_anchor_at(window_row(0), 0)
      end_id, = window.selection_anchor_at(window_row(1), 2)

      expect(window.extract_selection(start_id, 0, end_id, 2)).to eq "l3\nl4"
    end

    it 'scrolls back one line when a drag reaches the top text row' do
      expect(window.drag_auto_scroll(window_row(0))).to be true
      expect(text_rows).to eq %w[l2 l3 l4]
    end

    it 'scrolls forward one line when a drag reaches the bottom row' do
      window.scroll_lines(-2)

      expect(window.drag_auto_scroll(window.maxy - 1)).to be true
      expect(text_rows).to eq %w[l2 l3 l4]
    end

    it 'does not scroll when a drag stays inside the text area' do
      expect(window.drag_auto_scroll(window_row(1))).to be false
    end

    it 'keeps the scrolled-back view in place as new lines arrive' do
      window.scroll_lines(-1)

      window.add_string('l6')

      expect(text_rows).to eq %w[l2 l3 l4]
      expect(window.buffer_pos).to eq 2
    end

    context 'when scrolled back two pages' do
      before do
        %w[l6 l7 l8 l9 l10 l11 l12].each { |line| window.add_string(line) }
        2.times { window.scroll_lines(-window.content_height) }
      end

      it 'shows the newest lines on jumping to the bottom (the bottom key)' do
        window.scroll_lines(window.max_buffer_size)

        expect(text_rows).to eq %w[l10 l11 l12]
        expect(window.buffer_pos).to eq 0
      end

      it 'shows the next page on scrolling forward exactly one text area' do
        window.scroll_lines(window.content_height)

        expect(text_rows).to eq %w[l7 l8 l9]
      end

      it 'shows the right lines on scrolling forward more than one text area' do
        window.scroll_lines(window.content_height + 1)

        expect(text_rows).to eq %w[l8 l9 l10]
      end
    end

    it 'shows the right lines on scrolling back more than one text area' do
      %w[l6 l7 l8 l9 l10 l11 l12].each { |line| window.add_string(line) }

      window.scroll_lines(-(window.content_height + 1))

      expect(text_rows).to eq %w[l6 l7 l8]
    end

    # @return [Array<String>] each scrollbar cell: its character, or
    #   'thumb' for the reverse-video position marker
    def scrollbar_cells
      scrollbar = window.scrollbar
      (0...scrollbar.maxy).map do |y|
        scrollbar.attrs_at(y, 0).anybits?(Curses::A_REVERSE) ? 'thumb' : scrollbar.row(y)
      end
    end

    it 'draws the scrollbar beside the text rows, the thumb on the bottom one while live' do
      window.set_active(true)

      expect(scrollbar_cells).to eq Array.new(window.content_top, '') +
                                    [BaseWindow::ACTIVE_INDICATOR, BaseWindow::ACTIVE_SCROLLBAR_CHAR, 'thumb']
    end

    it 'moves the scrollbar thumb to the top text row when scrolled back to the oldest line' do
      window.set_active(true)

      window.scroll_lines(-2)

      expect(scrollbar_cells).to eq Array.new(window.content_top, '') +
                                    ['thumb', BaseWindow::ACTIVE_SCROLLBAR_CHAR, BaseWindow::ACTIVE_SCROLLBAR_CHAR]
    end

    it 'keeps a highlight on its text when the view scrolls' do
      line_id, = window.selection_anchor_at(window_row(1), 0)
      window.highlight_selection(line_id, 0, line_id, 2)

      window.scroll_lines(-1)

      expect(text_rows).to eq %w[l2 l3 l4]
      expect(window.attrs_at(window_row(1), 0) & Curses::A_REVERSE).to eq 0
      expect(window.attrs_at(window_row(2), 0) & Curses::A_REVERSE).to eq Curses::A_REVERSE
    end
  end

  # Both windows have 3 text rows and wrap at 10 columns. The cap counts
  # game lines: 'one two three four' is one line shown on 3 rows.
  shared_examples 'a text area with a capped buffer' do
    # @return [Array<String>] the visible text-area rows
    def text_rows
      window.rows.drop(window.content_top)
    end

    it 'keeps a wrapped line whole while it is under the cap' do
      ['one two three four', 'l1', 'l2', 'l3'].each { |line| window.add_string(line) }

      window.scroll_lines(-window.content_height)

      expect(text_rows).to eq ['one two', '  three', '  four']
    end

    it 'moves a view showing only an evicted line onto the oldest line left' do
      ['one two three four', 'l1', 'l2', 'l3'].each { |line| window.add_string(line) }
      window.scroll_lines(-window.content_height)

      window.add_string('l4')

      expect(text_rows).to eq %w[l1 l2 l3]
    end

    it 'moves a view showing part of an evicted line up by the rows it lost' do
      ['one two three four', 'l1', 'l2', 'l3'].each { |line| window.add_string(line) }
      window.scroll_lines(-2)
      expect(text_rows).to eq ['  three', '  four', 'l1']

      window.add_string('l4')

      expect(text_rows).to eq %w[l1 l2 l3]
      expect(window.buffer_pos).to eq 1
    end

    it 'keeps a selection on its text when an eviction drops several rows' do
      ['one two three four', 'l1', 'l2', 'l3'].each { |line| window.add_string(line) }
      line_id, = window.selection_anchor_at(window.content_top + 1, 0)
      window.highlight_selection(line_id, 0, line_id, 2)

      window.add_string('l4')

      expect(text_rows).to eq %w[l2 l3 l4]
      expect(window.attrs_at(window.content_top, 0) & Curses::A_REVERSE).to eq Curses::A_REVERSE
      expect(window.extract_selection(line_id, 0, line_id, 2)).to eq 'l2'
    end
  end

  context 'with a text window' do
    let(:window) { build("<window class='text' top='0' left='0' height='3' width='21' value='main'/>") }

    it_behaves_like 'a line-buffer text area'
  end

  context 'with a text window keeping 4 lines' do
    let(:window) { build("<window class='text' top='0' left='0' height='3' width='12' value='main' buffer-size='4'/>") }

    it_behaves_like 'a text area with a capped buffer'
  end

  context 'with a tabbed window keeping 4 lines per tab' do
    let(:window) { build("<window class='tabbed' top='0' left='0' height='4' width='12' tabs='main' buffer-size='4'/>") }

    it_behaves_like 'a text area with a capped buffer'
  end

  context 'with a tabbed window' do
    let(:window) { build("<window class='tabbed' top='0' left='0' height='4' width='21' tabs='main,combat'/>") }

    it_behaves_like 'a line-buffer text area'

    it 'keeps each tab its own lines and shows them on switching' do
      window.add_string_to_tab('combat', 'c1')

      window.switch_tab('combat')

      expect(window.rows).to eq [' 1:main | 2:combat', 'c1', '', '']
    end

    it 'keeps text off the tab bar on jumping to the bottom from one line more than a page back' do
      %w[l1 l2 l3 l4 l5 l6 l7].each { |line| window.add_string(line) }
      window.scroll_lines(-window.content_height)
      window.scroll_lines(-1)

      window.scroll_lines(window.max_buffer_size)

      expect(window.rows).to eq [' 1:main | 2:combat', 'l5', 'l6', 'l7']
    end

    context 'when the tab bar leaves room on its row' do
      let(:window) { build("<window class='tabbed' top='0' left='0' height='4' width='31' tabs='main,combat'/>") }

      it 'keeps old text off the tab bar on jumping to the bottom right after the tab bar is redrawn' do
        %w[l1 l2 l3 l4 l5 l6 l7 l8 l9 l10 l11 l12].each { |line| window.add_string(line) }
        2.times { window.scroll_lines(-window.content_height) }
        window.add_string_to_tab('combat', 'c1') # marks the tab: redraws the tab bar

        window.scroll_lines(window.max_buffer_size)

        expect(window.rows).to eq [' 1:main | 2:combat*', 'l10', 'l11', 'l12']
      end
    end
  end
end
