# frozen_string_literal: true

# Tests RoomWindow as a user sees it: the window is built from layout XML by
# WindowManager and draws onto the virtual screen (spec/support/virtual_screen.rb).
# Clicks are checked with link_cmd_at at the cells where a link's text is shown.

require 'rexml/document'
require_relative '../../../lib/window_manager'

RSpec.describe RoomWindow do
  # Color pair number per foreground color, so a cell's color can be read
  # back from its attributes.
  let(:pairs) { { LinkExtractor::DEFAULT_LINK_COLOR[0] => 1 } }

  # A room window 5 rows high and 10 columns wide; room text wraps at the
  # full width.
  let(:height) { 5 }
  let(:window) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='room' top='0' left='0' height='#{height}' width='10'/></layout>
    XML
    window_manager = WindowManager.new(shared_state: SharedState.new.tap { |state| state.blue_links = true })
    window_manager.load_layout('test')
    window_manager.room['room']
  end

  before do
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
  end

  # Row and column where +text+ is shown on the window.
  def screen_position(text)
    y = window.rows.index { |row| row.include?(text) }
    raise "#{text.inspect} is not on screen: #{window.rows.inspect}" unless y

    [y, window.rows[y].index(text)]
  end

  # What clicking each character of +text+ where it is shown would send.
  def clicks_on(text)
    y, x = screen_position(text)
    (x...(x + text.length)).map { |col| window.link_cmd_at(y, col) }.uniq
  end

  def show_room(desc, desc_links: [], exits: 'Go: north.', exit_links: [{ start: 4, end: 9, cmd: 'north' }])
    window.update_desc(desc, links: desc_links)
    window.update_exits(exits, links: exit_links)
    window.render
  end

  describe 'word wrap' do
    it 'wraps at the last space that fits and starts the next row with the next word' do
      show_room('abc defgh ijk')

      expect(window.rows).to eq ['abc defgh', 'ijk', 'Go: north.', '', '']
    end

    it 'puts the next word on the next row when a word ends exactly at the right edge' do
      show_room('abcdefghij klm nop')

      expect(window.rows).to eq ['abcdefghij', 'klm nop', 'Go: north.', '', '']
    end

    it 'continues a word longer than the width on the next row' do
      show_room('abcdefghijkl mn')

      expect(window.rows).to eq ['abcdefghij', 'kl mn', 'Go: north.', '', '']
    end

    it 'starts the next row with the next word when a double space falls at a break' do
      show_room('abc defgh  ijk')

      expect(window.rows).to eq ['abc defgh', 'ijk', 'Go: north.', '', '']
    end

    it 'starts the next section on the row after a section that fills the width' do
      show_room('abc defghi')

      expect(window.rows).to eq ['abc defghi', 'Go: north.', '', '', '']
    end
  end

  describe 'links' do
    it 'sends the link shown on the row after a run of spaces wider than the window, which takes no row' do
      show_room("ab#{' ' * 22}cd", desc_links: [{ start: 24, end: 26, cmd: 'look cd' }])

      expect(window.rows).to eq ['ab', '  cd', 'Go: north.', '', '']
      expect(clicks_on('cd')).to eq ['look cd']
    end

    it 'sends the link shown under the pointer on the row after a word that ends at the right edge' do
      show_room('abcdefghij klm nop', desc_links: [{ start: 15, end: 18, cmd: 'look nop' }])

      expect(clicks_on('nop')).to eq ['look nop']
    end

    it 'sends the link shown under the pointer in the next section' do
      show_room('abcdefghij klm nop', desc_links: [{ start: 15, end: 18, cmd: 'look nop' }])

      expect(clicks_on('north')).to eq ['north']
    end

    it 'sends nothing from the text next to a link' do
      show_room('abcdefghij klm nop', desc_links: [{ start: 15, end: 18, cmd: 'look nop' }])

      expect(clicks_on('klm')).to eq [nil]
      expect(clicks_on('Go:')).to eq [nil]
    end

    it 'draws a wrapped link in the link color where it is shown' do
      show_room('abcdefghij klm nop', desc_links: [{ start: 15, end: 18, cmd: 'look nop' }])

      y, x = screen_position('nop')
      expect((x...(x + 3)).map { |col| window.attrs_at(y, col) >> 8 }.uniq).to eq [1]
    end
  end

  # What clicking each cell of row +y+ would send.
  def clicks_on_row(y)
    (0...10).map { |x| window.link_cmd_at(y, x) }
  end

  # The cells of row +y+ drawn in the link color.
  def link_colored_on_row(y)
    (0...10).select { |x| window.attrs_at(y, x) >> 8 == 1 }
  end

  describe 'a room longer than the window' do
    # The room needs 4 rows (description 3, exits 1) and the window has 3.
    context 'with room for the exits' do
      let(:height) { 3 }

      before { show_room('abcdefghij klmnopqrst e', desc_links: [{ start: 22, end: 23, cmd: 'look e' }]) }

      it 'shows the exits on the bottom row below the first rows of the description' do
        expect(window.rows).to eq ['abcdefghij', 'klmnopqrst', 'Go: north.']
      end

      it 'sends the exit link shown under the pointer on the bottom row, and nothing beside it' do
        expect(clicks_on_row(2)).to eq [nil, nil, nil, nil, 'north', 'north', 'north', 'north', 'north', nil]
      end

      it 'sends a link from exactly the cells drawn in the link color' do
        expect((0...3).map { |y| (0...10).select { |x| window.link_cmd_at(y, x) } })
          .to eq((0...3).map { |y| link_colored_on_row(y) })
        expect(link_colored_on_row(2)).to eq [4, 5, 6, 7, 8]
      end
    end

    # Description 2 rows, exits 1, room number 1 and stringprocs 1, in a
    # window 4 rows high.
    context 'only because of the sections below the exits' do
      let(:height) { 4 }

      before do
        window.update_desc('abcdefghij klm')
        window.update_room_number('Room: 12')
        window.update_stringprocs('proc')
        window.update_exits('Go: north.', links: [{ start: 4, end: 9, cmd: 'north' }])
        window.render
      end

      it 'cuts the sections below the exits first' do
        expect(window.rows).to eq ['abcdefghij', 'klm', 'Go: north.', 'Room: 12']
      end
    end

    # The exits need 4 rows ('Go:', 'north,', 'south,', 'east.') and the
    # window has 2.
    context 'with exits longer than the window' do
      let(:height) { 2 }

      before do
        show_room('abc def', exits: 'Go: north, south, east.',
                             exit_links: [{ start: 4, end: 9, cmd: 'north' }, { start: 11, end: 16, cmd: 'south' },
                                          { start: 18, end: 22, cmd: 'east' }])
      end

      it 'shows the first rows of the exits' do
        expect(window.rows).to eq ['Go:', 'north,']
      end

      it 'sends the exit links where they are shown' do
        expect(clicks_on_row(0)).to eq [nil] * 10
        expect(clicks_on_row(1)).to eq ['north'] * 5 + [nil] * 5
      end
    end
  end

  # The server loop draws the window once per flush (spec/lib/room_renders_spec.rb):
  # a part only changes what the window holds.
  describe 'a room part' do
    it 'changes nothing on screen until the window is rendered' do
      window.update_title('[Hall]')
      window.update_exits('Go: north.')
      window.update_lich_exits('Also: gate')
      window.update_room_number('Room: 12')
      window.update_stringprocs('proc')
      expect(window.rows).to all(eq '')

      window.render

      expect(window.rows).to eq ['[Hall]', 'Go: north.', 'Also: gate', 'Room: 12', 'proc']
    end
  end
end
