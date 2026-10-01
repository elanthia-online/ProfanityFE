# frozen_string_literal: true

# Text and tabbed windows whose text area is one column wide, as a user
# sees them: built from layout XML by WindowManager and drawn onto the
# virtual screen (spec/support/virtual_screen.rb). A layout width of 2
# leaves one column of text beside the scrollbar column, so every
# character of a line gets its own row and fills the window's only
# column, the bottom row's included.

require 'rexml/document'
require_relative '../../../lib/window_manager'

RSpec.describe 'A window one column wide' do
  # @param xml [String] the layout's window element
  # @return [WindowManager] a manager with the layout loaded
  def load(xml)
    LAYOUT['test'] = REXML::Document.new("<layout>#{xml}</layout>").root
    WindowManager.new.tap { |manager| manager.load_layout('test') }
  end

  context 'with a text window four rows high' do
    let(:window) { load("<window class='text' top='0' left='0' height='4' width='2' value='main'/>").stream['main'] }

    it 'has one column of text' do
      expect(window.maxx).to eq 1
    end

    it 'shows the newest lines on consecutive rows, the newest at the bottom' do
      %w[a b c d e f].each { |line| window.add_string(line) }

      expect(window.rows).to eq %w[c d e f]
    end

    it 'shows the same rows after a repaint' do
      %w[a b c d e f].each { |line| window.add_string(line) }

      window.repaint

      expect(window.rows).to eq %w[c d e f]
    end

    it 'keeps the top row on a repaint when the lines just fill the window' do
      %w[a b c d].each { |line| window.add_string(line) }

      window.repaint

      expect(window.rows).to eq %w[a b c d]
    end

    it 'shows each character of a long line on its own row' do
      window.add_string('abcdef')

      expect(window.rows).to eq %w[c d e f]
    end

    it 'keeps a blank line as an empty row between its neighbours' do
      ['a', '', 'b', 'c', 'd'].each { |line| window.add_string(line) }

      expect(window.rows).to eq ['', 'b', 'c', 'd']
    end

    it 'shows older rows when scrolled back and the newest again when scrolled forward' do
      %w[a b c d e f g h].each { |line| window.add_string(line) }

      window.scroll_lines(-2)
      expect(window.rows).to eq %w[c d e f]

      window.scroll_lines(2)
      expect(window.rows).to eq %w[e f g h]
    end

    it 'keeps blank rows in place when scrolled back and forward across them' do
      ['a', 'b', 'c', 'd', '', 'e', '', 'f', 'g', 'h'].each { |line| window.add_string(line) }

      window.scroll_lines(-4)
      expect(window.rows).to eq ['c', 'd', '', 'e']

      window.scroll_lines(2)
      expect(window.rows).to eq ['', 'e', '', 'f']
    end

    it 'keeps the highlighted text on its row' do
      %w[a b c d].each { |line| window.add_string(line) }
      first_id = window.lines_appended - 3

      window.highlight_selection(first_id, 0, first_id, 1)

      expect(window.rows).to eq %w[a b c d]
      expect(window.attrs_at(0, 0)).to be_anybits(Curses::A_REVERSE)
    end
  end

  context 'when a terminal resize leaves a text window one column wide' do
    # Six columns wide (five of text) on an 84-column terminal, two on the
    # 80 columns specs run at.
    let(:window_manager) do
      allow(Curses).to receive(:cols).and_return(84)
      load("<window class='text' top='0' left='0' height='4' width='cols-78' value='main'/>")
    end
    let(:window) { window_manager.stream['main'] }

    it 'shows the newest characters on consecutive rows' do
      %w[ab cd ef].each { |line| window.add_string(line) }
      allow(Curses).to receive(:cols).and_return(80)

      window_manager.resize(nil)

      expect(window.maxx).to eq 1
      expect(window.rows).to eq %w[c d e f]
    end
  end

  context 'with a tabbed window five rows high' do
    let(:window) { load("<window class='tabbed' top='0' left='0' height='5' width='2' tabs='main'/>").stream['main'] }

    it 'shows the newest lines on consecutive rows below the tab bar' do
      %w[a b c d e f].each { |line| window.add_string(line) }

      expect(window.rows).to eq ['', 'c', 'd', 'e', 'f']
    end

    it 'shows the same rows after a repaint' do
      %w[a b c d e f].each { |line| window.add_string(line) }

      window.repaint

      expect(window.rows).to eq ['', 'c', 'd', 'e', 'f']
    end

    it 'keeps the top text row on a repaint when the lines just fill the window' do
      %w[a b c d].each { |line| window.add_string(line) }

      window.repaint

      expect(window.rows).to eq ['', 'a', 'b', 'c', 'd']
    end
  end

  context 'with a tabbed window two rows high' do
    # One text row: ncurses refuses a one-row scroll region, so the
    # region is the whole window, tab bar included.
    let(:window) { load("<window class='tabbed' top='0' left='0' height='2' width='2' tabs='main'/>").stream['main'] }

    it 'keeps the tab bar on the top row and shows the newest line below it' do
      %w[a b].each { |line| window.add_string(line) }

      expect(window.rows).to eq ['', 'b']
      expect(window.attrs_at(0, 0)).to be_anybits(Curses::A_REVERSE)
    end
  end
end
