# frozen_string_literal: true

# Tests TextWindow as a user sees it: windows are built from layout XML by
# WindowManager and draw onto the virtual screen (spec/support/virtual_screen.rb).

require 'rexml/document'
require_relative '../../../lib/window_manager'

RSpec.describe TextWindow do
  # A text window 3 rows high and 12 columns wide. The builder keeps one
  # column for the scrollbar, so text wraps at 10 characters.
  let(:window) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='text' top='0' left='0' height='3' width='12' value='main'/></layout>
    XML
    window_manager = WindowManager.new
    window_manager.load_layout('test')
    window_manager.stream['main']
  end

  it 'shows the newest lines at the bottom once the window is full' do
    %w[l1 l2 l3 l4 l5].each { |line| window.add_string(line) }

    expect(window.rows).to eq %w[l3 l4 l5]
  end

  it 'wraps a long line to the window width and indents the continuation' do
    window.add_string('one two three four')

    expect(window.rows).to eq ['one two', '  three', '  four']
  end

  it 'shows older lines when scrolled back and returns to the newest lines' do
    %w[l1 l2 l3 l4 l5].each { |line| window.add_string(line) }
    window.add_string('one two three four')

    window.scroll(-2)
    expect(window.rows).to eq ['l4', 'l5', 'one two']

    window.scroll(2)
    expect(window.rows).to eq ['one two', '  three', '  four']
  end

  it 'draws the first line of a new window on the top row' do
    window.add_string('l1')

    expect(window.rows).to eq ['l1', '', '']
  end

  it 'draws a blank line as an empty row between its neighbours' do
    ['l1', '', 'l2'].each { |line| window.add_string(line) }

    expect(window.rows).to eq ['l1', '', 'l2']
  end

  it 'keeps blank lines as empty rows once the window scrolls' do
    ['l1', '', 'l2', '', 'l3'].each { |line| window.add_string(line) }

    expect(window.rows).to eq ['l2', '', 'l3']
  end

  it 'puts the first line after the startup blank fill on the bottom row' do
    window.maxy.times { window.add_string "\n".dup }
    %w[l1 l2].each { |line| window.add_string(line) }

    expect(window.rows).to eq ['', 'l1', 'l2']
  end

  it 'copies the text shown on the row the user selects when a blank line follows it' do
    ['l1', '', 'l2'].each { |line| window.add_string(line) }
    row = window.rows.index('l1')

    line_id, = window.selection_anchor_at(row, 0)

    expect(window.extract_selection(line_id, 0, line_id, 2)).to eq 'l1'
  end

  it 'leaves every row in place when a line after a blank line is highlighted' do
    ['l1', '', 'l2'].each { |line| window.add_string(line) }
    shown = window.rows
    line_id, = window.selection_anchor_at(shown.index('l2'), 0)

    window.highlight_selection(line_id, 0, line_id, 2)

    expect(window.rows).to eq shown
    expect(window.attrs_at(shown.index('l2'), 0) & Curses::A_REVERSE).to eq Curses::A_REVERSE
  end

  it 'opens the link shown on the row the user clicks when a blank line follows it' do
    window.add_string('go north', [{ start: 3, end: 8, cmd: 'north' }])
    window.add_string('')
    window.add_string('l2')
    row = window.rows.index('go north')

    expect(window.link_cmd_at(row, 4)).to eq 'north'
  end

  it 'removes the reverse-video highlight when the selection is cleared' do
    %w[l1 l2 l3].each { |line| window.add_string(line) }
    line_id, = window.selection_anchor_at(1, 0)
    window.highlight_selection(line_id, 0, line_id, 2)

    window.clear_highlight

    reversed = (0...window.maxy).to_a.product((0...window.maxx).to_a).select do |y, x|
      window.attrs_at(y, x).anybits?(Curses::A_REVERSE)
    end
    expect(reversed).to be_empty
    expect(window.rows).to eq %w[l1 l2 l3]
  end

  it 'shows a full page of older lines after scrolling back by the whole window height' do
    %w[l1 l2 l3 l4 l5 l6 l7 l8 l9].each { |line| window.add_string(line) }

    window.scroll(-window.maxy)

    expect(window.rows).to eq %w[l4 l5 l6]
  end

  context 'when the buffer is full and the user has scrolled back to its oldest lines' do
    # Same window, but keeping only 6 lines.
    let(:window) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout><window class='text' top='0' left='0' height='3' width='12' value='main' buffer-size='6'/></layout>
      XML
      window_manager = WindowManager.new
      window_manager.load_layout('test')
      window_manager.stream['main']
    end

    before do
      %w[l1 l2 l3 l4 l5 l6].each { |line| window.add_string(line) }
      window.scroll(-window.maxy)
    end

    it 'moves the view past the evicted oldest line and draws the next line on the bottom row' do
      window.add_string('l7')

      expect(window.rows).to eq %w[l2 l3 l4]
    end

    it 'shows the newest lines after scrolling back down past the new lines' do
      %w[l7 l8].each { |line| window.add_string(line) }

      window.scroll(window.maxy)

      expect(window.rows).to eq %w[l6 l7 l8]
    end
  end
end
