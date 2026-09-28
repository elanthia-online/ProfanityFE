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
      window.scroll(-2)

      expect(window.drag_auto_scroll(window.maxy - 1)).to be true
      expect(text_rows).to eq %w[l2 l3 l4]
    end

    it 'does not scroll when a drag stays inside the text area' do
      expect(window.drag_auto_scroll(window_row(1))).to be false
    end

    it 'keeps the scrolled-back view in place as new lines arrive' do
      window.scroll(-1)

      window.add_string('l6')

      expect(text_rows).to eq %w[l2 l3 l4]
      expect(window.buffer_pos).to eq 2
    end

    it 'keeps a highlight on its text when the view scrolls' do
      line_id, = window.selection_anchor_at(window_row(1), 0)
      window.highlight_selection(line_id, 0, line_id, 2)

      window.scroll(-1)

      expect(text_rows).to eq %w[l2 l3 l4]
      expect(window.attrs_at(window_row(1), 0) & Curses::A_REVERSE).to eq 0
      expect(window.attrs_at(window_row(2), 0) & Curses::A_REVERSE).to eq Curses::A_REVERSE
    end
  end

  context 'with a text window' do
    let(:window) { build("<window class='text' top='0' left='0' height='3' width='21' value='main'/>") }

    it_behaves_like 'a line-buffer text area'
  end

  context 'with a tabbed window' do
    let(:window) { build("<window class='tabbed' top='0' left='0' height='4' width='21' tabs='main,combat'/>") }

    it_behaves_like 'a line-buffer text area'

    it 'keeps each tab its own lines and shows them on switching' do
      window.add_string_to_tab('combat', 'c1')

      window.switch_tab('combat')

      expect(window.rows).to eq [' 1:main | 2:combat', 'c1', '', '']
    end
  end
end
