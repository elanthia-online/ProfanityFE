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
  let(:window) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='room' top='0' left='0' height='5' width='10'/></layout>
    XML
    window_manager = WindowManager.new
    window_manager.load_layout('test')
    window_manager.room['room'].tap { |room| room.links_enabled = true }
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
end
