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
                                    [LineBuffered::ACTIVE_INDICATOR, LineBuffered::ACTIVE_SCROLLBAR_CHAR, 'thumb']
    end

    it 'moves the scrollbar thumb to the top text row when scrolled back to the oldest line' do
      window.set_active(true)

      window.scroll_lines(-2)

      expect(scrollbar_cells).to eq Array.new(window.content_top, '') +
                                    ['thumb', LineBuffered::ACTIVE_SCROLLBAR_CHAR, LineBuffered::ACTIVE_SCROLLBAR_CHAR]
    end

    it 'keeps a highlight on its text when the view scrolls' do
      line_id, = window.selection_anchor_at(window_row(1), 0)
      window.highlight_selection(line_id, 0, line_id, 2)

      window.scroll_lines(-1)

      expect(text_rows).to eq %w[l2 l3 l4]
      expect(window.attrs_at(window_row(1), 0) & Curses::A_REVERSE).to eq 0
      expect(window.attrs_at(window_row(2), 0) & Curses::A_REVERSE).to eq Curses::A_REVERSE
    end

    context 'with part of a shown line highlighted' do
      # @return [Array<Array<Boolean>>] per text-area row, whether each of
      #   its first 6 cells is in reverse video
      def reverse_cells
        (0...window.content_height).map do |text_row|
          (0...6).map { |x| window.attrs_at(window_row(text_row), x).anybits?(Curses::A_REVERSE) }
        end
      end

      before do
        window.add_string('abcdef')
        line_id, = window.selection_anchor_at(window_row(2), 0)
        window.highlight_selection(line_id, 1, line_id, 4)
      end

      it 'keeps the highlight on the selected cells as lines arrive and scroll them up' do
        window.add_string('l6')
        window.add_string('l7')

        expect(text_rows).to eq %w[abcdef l6 l7]
        expect(reverse_cells).to eq [[false, true, true, true, false, false], [false] * 6, [false] * 6]
      end

      it 'keeps the highlight on the selected cells as a wrapped line arrives' do
        window.add_string('one two three four five')

        expect(text_rows).to eq ['abcdef', 'one two three four', '  five']
        expect(reverse_cells).to eq [[false, true, true, true, false, false], [false] * 6, [false] * 6]
      end

      it 'highlights the start of a line that arrives inside a selection reaching past the newest line' do
        line_id, = window.selection_anchor_at(window_row(2), 0)
        window.highlight_selection(line_id, 1, line_id + 1, 2)

        window.add_string('l6')

        expect(text_rows).to eq %w[l5 abcdef l6]
        expect(reverse_cells.drop(1)).to eq [[false] + [true] * 5, [true, true, false, false, false, false]]
      end

      it 'draws only the new row, not the rows already shown, when a line arrives' do
        window.call_log.clear

        window.add_string('l6')

        expect(window.call_log.select { |meth, _| meth == :setpos }).to eq [[:setpos, [window_row(2), 0]]]
        expect(window.call_log.count { |meth, _| meth == :clrtoeol }).to eq 1
      end

      it 'keeps the highlight through a resize that keeps the width, and as the next line arrives' do
        window.redraw_after_resize

        expect(text_rows).to eq %w[l4 l5 abcdef]
        expect(reverse_cells).to eq [[false] * 6, [false] * 6, [false, true, true, true, false, false]]

        window.call_log.clear
        window.add_string('l6')

        expect(text_rows).to eq %w[l5 abcdef l6]
        expect(reverse_cells).to eq [[false] * 6, [false, true, true, true, false, false], [false] * 6]
        # Only the new row is drawn: the rows shown already carry the highlight
        expect(window.call_log.count { |meth, _| meth == :clrtoeol }).to eq 1
      end

      it 'highlights the selection set through the attribute writers when the next line arrives' do
        line_id, = window.selection_start
        window.selection_end = [line_id, 6]

        window.add_string('l6')

        expect(text_rows).to eq %w[l5 abcdef l6]
        expect(reverse_cells[1]).to eq [false] + [true] * 5
      end

      it 'highlights a line that arrived while the attribute writers unset the selection, once it is set again' do
        line_id, = window.selection_start
        window.highlight_selection(line_id, 0, line_id + 2, 2)
        selection = [window.selection_start, window.selection_end]
        window.selection_start = nil
        window.selection_end = nil
        window.add_string('l6')

        window.selection_start, window.selection_end = selection
        window.add_string('l7')

        expect(text_rows).to eq %w[abcdef l6 l7]
        expect(reverse_cells).to eq [[true] * 6, [true, true] + [false] * 4, [true, true] + [false] * 4]
      end

      it 'highlights the rows a scroll drew while the attribute writers unset the selection, once it is set again' do
        selection = [window.selection_start, window.selection_end]
        window.selection_start = nil
        window.selection_end = nil
        window.scroll_lines(-2)
        window.scroll_lines(2)

        window.selection_start, window.selection_end = selection
        window.add_string('l6')

        expect(text_rows).to eq %w[l5 abcdef l6]
        expect(reverse_cells[1]).to eq [false, true, true, true, false, false]
      end
    end

    it 'highlights an arriving line that the selection starts on' do
      next_id = window.lines_appended + 1
      window.highlight_selection(next_id, 0, next_id, 1)

      window.add_string('l6')

      expect(text_rows).to eq %w[l4 l5 l6]
      expect(window.attrs_at(window_row(2), 0) & Curses::A_REVERSE).to eq Curses::A_REVERSE
      expect(window.attrs_at(window_row(2), 1) & Curses::A_REVERSE).to eq 0
    end

    it 'draws only the new row, not the rows already shown, when a line arrives with no selection' do
      window.call_log.clear

      window.add_string('l6')

      expect(window.call_log.select { |meth, _| meth == :setpos }).to eq [[:setpos, [window_row(2), 0]]]
      expect(window.call_log.count { |meth, _| meth == :clrtoeol }).to eq 1
    end
  end

  # Both windows have 3 text rows and start empty. While a highlight is
  # shown, a line arriving before the text area fills leaves the cursor
  # where a repaint of the whole text area would: at the start of the
  # bottom row.
  shared_examples 'a text area filling under a highlight' do
    # @return [Array<String>] the visible text-area rows
    def text_rows
      window.rows.drop(window.content_top)
    end

    # Highlight the first two characters of the line on the top text row.
    #
    # @return [void]
    def highlight_top_line
      line_id, = window.selection_anchor_at(window.content_top, 0)
      window.highlight_selection(line_id, 0, line_id, 2)
    end

    it 'leaves the cursor at the start of the blank bottom row when a line arrives' do
      window.add_string('l1')
      highlight_top_line

      window.add_string('l2x')

      expect(text_rows).to eq ['l1', 'l2x', '']
      expect(window.attrs_at(window.content_top, 0) & Curses::A_REVERSE).to eq Curses::A_REVERSE
      expect([window.cury, window.curx]).to eq [window.content_top + 2, 0]
    end

    it 'leaves the cursor after the new text when the line fills the text area' do
      %w[l1 l2].each { |line| window.add_string(line) }
      highlight_top_line

      window.add_string('l3x')

      expect(text_rows).to eq %w[l1 l2 l3x]
      expect([window.cury, window.curx]).to eq [window.content_top + 2, 3]
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

    context 'when the cap is lowered' do
      before { ['one two three four', 'l1', 'l2', 'l3'].each { |line| window.add_string(line) } }

      it 'moves a view showing only a dropped line onto the oldest line left' do
        window.scroll_lines(-window.content_height)

        window.max_buffer_size = 3

        expect(text_rows).to eq %w[l1 l2 l3]
        expect(window.buffer_pos).to eq 0
      end

      it 'redraws the lines left from the top row when they no longer fill the text area' do
        window.scroll_lines(-2)

        window.max_buffer_size = 2

        expect(text_rows).to eq ['l2', 'l3', '']
        expect(window.buffer_pos).to eq 0
      end

      it 'keeps the rows left of a selection that reached a dropped line highlighted and copies only them' do
        window.scroll_lines(-1)
        expect(text_rows).to eq ['  four', 'l1', 'l2']
        start_id, = window.selection_anchor_at(window.content_top, 0)
        end_id, = window.selection_anchor_at(window.content_top + 1, 2)
        window.highlight_selection(start_id, 0, end_id, 2)

        window.max_buffer_size = 3

        expect(text_rows).to eq %w[l1 l2 l3]
        expect(window.attrs_at(window.content_top, 0) & Curses::A_REVERSE).to eq Curses::A_REVERSE
        expect(window.attrs_at(window.content_top + 1, 0) & Curses::A_REVERSE).to eq 0
        expect(window.extract_selection(start_id, 0, end_id, 2)).to eq 'l1'
      end
    end
  end

  context 'with a text window' do
    let(:window) { build("<window class='text' top='0' left='0' height='3' width='21' value='main'/>") }

    it_behaves_like 'a line-buffer text area'
    it_behaves_like 'a text area filling under a highlight'
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
    it_behaves_like 'a text area filling under a highlight'

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

    it 'drops the oldest lines of a background tab when the cap is lowered' do
      window.switch_tab('combat')
      %w[c1 c2 c3 c4 c5 c6 c7].each { |line| window.add_string_to_tab('combat', line) }
      window.scroll_lines(-window.max_buffer_size)
      window.switch_tab('main')

      window.max_buffer_size = 4
      window.switch_tab('combat')

      expect(window.rows).to eq [' 1:main | 2:combat', 'c4', 'c5', 'c6']
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
