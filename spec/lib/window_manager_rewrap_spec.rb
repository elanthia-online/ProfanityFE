# frozen_string_literal: true

# Tests what text and tabbed windows show after WindowManager#resize: the
# stored lines are re-wrapped to the new width and repainted. Windows are
# built from layout XML and draw onto the virtual screen
# (spec/support/virtual_screen.rb); the terminal width is stubbed.

require 'rexml/document'
require_relative '../../lib/window_manager'

RSpec.describe WindowManager, '#resize re-wrapping' do
  subject(:wm) { described_class.new }

  # The terminal starts 80 columns wide; windows are built on first use.
  before { allow(Curses).to receive(:cols).and_return(80) }

  # Build the layout and return the window serving the main stream. At
  # 80 columns the window is 20 wide (19 of text, wrapping at 18); at 48
  # columns it is 12 wide (wrapping at 10).
  def build(window_xml)
    LAYOUT['test'] = REXML::Document.new("<layout>#{window_xml}</layout>").root
    wm.load_layout('test')
    wm.stream['main']
  end

  # Change the terminal width and resize the windows.
  def resize_to(new_cols)
    allow(Curses).to receive(:cols).and_return(new_cols)
    wm.resize(nil)
  end

  # Cells drawn in reverse video anywhere in the window.
  def reversed_cells(window)
    (0...window.maxy).to_a.product((0...window.maxx).to_a).select do |y, x|
      window.attrs_at(y, x).anybits?(Curses::A_REVERSE)
    end
  end

  context 'with a text window' do
    let(:window) { build("<window class='text' top='0' left='0' height='3' width='cols/4' value='main'/>") }

    it 're-wraps a stored line to the narrower width' do
      window.add_string('one two three four')

      resize_to(48)

      expect(window.rows).to eq ['one two', '  three', '  four']
    end

    it 'joins a wrapped line back up at the wider width' do
      allow(Curses).to receive(:cols).and_return(48)
      window.add_string('one two three four')

      resize_to(80)

      expect(window.rows).to eq ['one two three four', '', '']
    end

    it 'keeps the line on the bottom row there when scrolled back' do
      (%w[l1 l2 l3 l4 l5] + ['one two three four']).each { |line| window.add_string(line) }
      window.scroll_lines(-2)
      expect(window.rows).to eq %w[l2 l3 l4]

      resize_to(48)

      expect(window.rows).to eq %w[l2 l3 l4]
      window.scroll_lines(window.buffer_pos)
      expect(window.rows).to eq ['one two', '  three', '  four']
    end

    it 'moves a view scrolled back to the oldest line down when widening leaves fewer rows' do
      allow(Curses).to receive(:cols).and_return(48)
      ['l1', 'one two three four', 'l2', 'l3'].each { |line| window.add_string(line) }
      window.scroll_lines(-window.maxy)
      expect(window.rows).to eq ['l1', 'one two', '  three']

      resize_to(80)

      expect(window.rows).to eq ['l1', 'one two three four', 'l2']
    end

    it 'stays on the newest lines when live' do
      (%w[l1 l2 l3] + ['one two three four']).each { |line| window.add_string(line) }

      resize_to(48)

      expect(window.rows).to eq ['one two', '  three', '  four']
      expect(window.buffer_pos).to eq 0
    end

    it 'clears the selection' do
      %w[l1 l2 l3].each { |line| window.add_string(line) }
      line_id, = window.selection_anchor_at(1, 0)
      window.highlight_selection(line_id, 0, line_id, 2)

      resize_to(48)

      expect(reversed_cells(window)).to be_empty
      expect(window.has_highlight?).to be false
      expect(window.rows).to eq %w[l1 l2 l3]
    end

    it 'keeps the selection when the width is unchanged' do
      %w[l1 l2 l3].each { |line| window.add_string(line) }
      line_id, = window.selection_anchor_at(1, 0)
      window.highlight_selection(line_id, 0, line_id, 2)

      resize_to(80)

      expect(reversed_cells(window)).to eq [[1, 0], [1, 1]]
    end

    it 'ends a drag in progress in the window' do
      %w[l1 l2 l3].each { |line| window.add_string(line) }
      SelectionManager.start_selection(window, 1, 0)

      resize_to(48)

      expect(SelectionManager.active_window).to be_nil
      expect(SelectionManager.selecting).to be false
    ensure
      SelectionManager.clear_selection
    end
  end

  context 'with a tabbed window' do
    # The tab bar on row 0 and 3 rows of text below it; 40 wide at 80
    # columns (wrapping at 38) and 24 wide at 48 (wrapping at 22), so the
    # tab bar fits at both widths.
    let(:window) do
      build("<window class='tabbed' top='0' left='0' height='4' width='cols/2' tabs='main,combat'/>")
    end

    let(:long_line) { 'one two three four five six seven' }

    # @return [Array<String>] the visible text rows below the tab bar
    def text_rows
      window.rows.drop(TabbedTextWindow::TAB_BAR_HEIGHT)
    end

    it 're-wraps the shown tab without leaving a cut-off line on the next row' do
      ['l1', long_line, 'l3'].each { |line| window.add_string(line) }

      resize_to(48)

      expect(text_rows).to eq ['one two three four', '  five six seven', 'l3']
    end

    it 're-wraps a background tab too' do
      window.add_string_to_tab('combat', long_line)

      resize_to(48)
      window.switch_tab('combat')

      expect(text_rows).to eq ['one two three four', '  five six seven', '']
    end

    it 'clears the selection' do
      %w[l1 l2 l3].each { |line| window.add_string(line) }
      line_id, = window.selection_anchor_at(2, 0)
      window.highlight_selection(line_id, 0, line_id, 2)

      resize_to(48)

      expect(reversed_cells(window).reject { |y, _x| y.zero? }).to be_empty
      expect(window.has_highlight?).to be false
    end
  end
end
