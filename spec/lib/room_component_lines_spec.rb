# frozen_string_literal: true

# What the room window and the room players indicator show for a room
# component line (<component id='room objs'>, 'room players', 'room
# exits') that arrives on its own, outside a full room entry: the clean
# text, the links a click opens, creatures in the monsterbold color, and,
# without a room window, the players in the 'room players' indicator with
# their highlights.
#
# Lines are fed through the real server loop (GameTextProcessor#run) into
# real windows built from layout XML; the assertions are on what those
# windows show on the virtual screen (spec/support/virtual_screen.rb) and
# on RoomWindow#link_cmd_at, which answers a click.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Room component lines' do
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  # Color pair number per foreground color, so a cell's color can be read
  # back from its attributes. 444444 and ffff00 are the room players
  # indicator's off and on colors (fg='444444,ffff00' in the layouts
  # below).
  let(:pairs) { { 'ff0000' => 1, '00ff00' => 2, 'ffff00' => 3, '444444' => 4 } }

  before do
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, _bg| pairs.fetch(fg, 0) }
  end

  # Build the windows of a layout and a processor that feeds them.
  #
  # @param windows_xml [String] the layout's <window> elements
  # @return [void]
  def load_layout(windows_xml)
    LAYOUT['rooms'] = REXML::Document.new("<layout>#{windows_xml}</layout>").root
    event_bus = EventBus.new
    @window_manager = WindowManager.new(shared_state: state)
    @window_manager.load_layout('rooms')
    @window_manager.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @window_manager, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would (Lich ends every line with CRLF).
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    allow(IO).to receive(:select).and_return(nil)
    @processor.run(server)
  end

  # The window's row showing +text+, and the column it starts at.
  def locate(window, text)
    y = window.rows.index { |row| row.include?(text) }
    raise "#{text.inspect} not shown: #{window.rows.reject(&:empty?).inspect}" unless y

    [y, window.row(y).index(text)]
  end

  # The color of each character of +text+ where +window+ shows it: a
  # foreground color, nil when uncolored, or an Array when mixed.
  def color_of(window, text)
    y, x = locate(window, text)
    colors = (x...(x + text.length)).map { |col| pairs.key(window.attrs_at(y, col) >> 8) }.uniq
    colors.size == 1 ? colors.first : colors
  end

  # The color the room players indicator draws its label in: that of its
  # first cell, where the label starts (a blank label is one space).
  def indicator_color
    pairs.key(@window_manager.indicator['room players'].attrs_at(0, 0) >> 8)
  end

  describe 'with a room window' do
    before do
      load_layout(<<~XML)
        <window class='text' top='0' left='0' height='8' width='120' value='main'/>
        <window class='room' top='10' left='0' height='10' width='120' value='room'/>
        <window class='indicator' top='23' left='0' height='1' width='40' label=' ' value='room players'
                fg='444444,ffff00'/>
      XML
    end

    let(:room) { @window_manager.room['room'] }

    # The rows the room window shows, blank rows left out.
    def room_rows
      room.rows.reject(&:empty?)
    end

    # The link command a click on each character of +text+ in the room
    # window opens (nil where there is no link), without repeats.
    def commands_under(text)
      y, x = locate(room, text)
      (x...(x + text.length)).map { |col| room.link_cmd_at(y, col) }.uniq
    end

    it 'shows a players component in the room window' do
      receive_from_server("<component id='room players'>Also here: Quilsilgas and Dark Summoner Vlachodimos.</component>")

      expect(room_rows).to eq ['Also here: Quilsilgas and Dark Summoner Vlachodimos.']
    end

    it 'shows an objects component in the room window' do
      receive_from_server("<component id='room objs'>You also see <pushBold/>a goblin<popBold/> and a sword.</component>")

      expect(room_rows).to eq ['You also see a goblin and a sword.']
    end

    it 'clears the players from the room window when an empty players component arrives' do
      receive_from_server("<component id='room players'>Also here: Mahtra.</component>")
      expect(room_rows).to eq ['Also here: Mahtra.']

      receive_from_server("<component id='room players'></component>")

      expect(room_rows).to be_empty
    end

    it 'turns the room players indicator off when an empty players component arrives' do
      receive_from_server("<component id='room players'>Also here: Mahtra.</component>")
      expect(indicator_color).to eq 'ffff00'

      receive_from_server("<component id='room players'></component>")

      expect(@window_manager.indicator['room players'].rows.first.rstrip).to eq ''
      expect(indicator_color).to eq '444444'
    end

    describe 'an objects component with links and a creature (GemStone XML)' do
      let(:objects_line) do
        <<~'XML'.chomp
          <component id='room objs'>  You also see the <a exist="173594154" noun="disk">Pandin disk</a>, a <a exist="26164" noun="fissure">narrow fissure</a>, the <a exist="-2078" noun="Lodge">Wayside Lodge</a> and<b> <pushBold/>a <a exist="-477668" noun="assistant">dwarven blacksmith assistant</a><popBold/></b>.</component>
        XML
      end

      before { PRESET['monsterbold'] = ['ff0000', nil] }

      it 'shows the objects without their markup' do
        receive_from_server(objects_line)

        expect(room_rows).to eq ['You also see the Pandin disk, a narrow fissure, the Wayside Lodge and a dwarven blacksmith assistant.']
      end

      it "opens each object's link when its name is clicked, and nothing between the names" do
        state.blue_links = true

        receive_from_server(objects_line)

        expect(commands_under('Pandin disk')).to eq ['look #173594154']
        expect(commands_under('narrow fissure')).to eq ['look #26164']
        expect(commands_under('Wayside Lodge')).to eq ['look #-2078']
        expect(commands_under('dwarven blacksmith assistant')).to eq ['look #-477668']
        expect(commands_under(', a ')).to eq [nil]
      end

      it 'draws the creature in the monsterbold color, and only the creature' do
        receive_from_server(objects_line)

        # The game bolds "a dwarven blacksmith assistant", article included
        expect(color_of(room, 'a dwarven blacksmith assistant')).to eq 'ff0000'
        expect(color_of(room, 'the Wayside Lodge and ')).to be_nil
      end

      it 'keeps the links of objects shown with links off, so they work once links are turned on' do
        state.blue_links = false
        receive_from_server(objects_line)

        # What .links does: turn links on and draw the room window again
        state.blue_links = true
        room.render

        expect(commands_under('Pandin disk')).to eq ['look #173594154']
      end
    end

    it "opens each player's link when the name is clicked (GemStone XML)" do
      state.blue_links = true

      receive_from_server(<<~'XML'.chomp)
        <component id='room players'>Also here: <a exist="-10987185" noun="Pandin">Pandin</a>, <a exist="-11184851" noun="Nexuspickbot">Nexuspickbot</a>, Grand Lord <a exist="-10995777" noun="Treeze">Treeze</a></component>
      XML

      expect(room_rows).to eq ['Also here: Pandin, Nexuspickbot, Grand Lord Treeze']
      expect(commands_under('Pandin')).to eq ['look #-10987185']
      expect(commands_under('Nexuspickbot')).to eq ['look #-11184851']
      expect(commands_under('Treeze')).to eq ['look #-10995777']
      expect(commands_under('Grand Lord ')).to eq [nil]
    end

    it 'shows exits without the compass markup, and opens the exit when it is clicked (GemStone XML)' do
      state.blue_links = true

      receive_from_server(<<~'XML'.chomp)
        <component id='room exits'>Obvious paths: <a exist="-11230837" coord="2524,1864" noun="out">out</a><compass><dir value="out"/></compass></component>
      XML

      expect(room_rows).to eq ['Obvious paths: out']
      expect(commands_under('out')).to eq ['look #-11230837']
    end
  end

  describe 'without a room window: the room players indicator' do
    # It is drawn in its "on" color (ffff00) while it shows players.
    before do
      load_layout(<<~XML)
        <window class='text' top='0' left='0' height='8' width='80' value='main'/>
        <window class='indicator' top='23' left='0' height='1' width='40' label=' ' value='room players'
                fg='444444,ffff00'/>
      XML
    end

    let(:indicator) { @window_manager.indicator['room players'] }

    # What the indicator shows, trailing blanks removed.
    def indicator_label
      indicator.rows.first.rstrip
    end

    it 'shows the name of the player a players component lists' do
      receive_from_server("<component id='room players'>Also here: Cithrin</component>")

      expect(indicator_label).to eq 'Cithrin'
      expect(color_of(indicator, 'Cithrin')).to eq 'ffff00'
    end

    it 'shows every player when the players line ends with a period' do
      receive_from_server("<component id='room players'>Also here: Bob and Alice.</component>")

      expect(indicator_label).to eq 'Bob, Alice'
    end

    it 'turns off when an empty players component arrives' do
      receive_from_server("<component id='room players'>Also here: Cithrin</component>")
      expect(indicator_color).to eq 'ffff00'

      receive_from_server("<component id='room players'></component>")

      expect(indicator_label).to eq ''
      expect(indicator_color).to eq '444444'
    end

    it 'colors a name a highlight matches' do
      HIGHLIGHT[/Cithrin/] = ['ff0000', nil, nil]

      receive_from_server("<component id='room players'>Also here: Cithrin</component>")

      expect(color_of(indicator, 'Cithrin')).to eq 'ff0000'
    end

    it 'colors a highlighted name where it stands in the list of names' do
      HIGHLIGHT[/Navesi/] = ['00ff00', nil, nil]

      receive_from_server("<component id='room players'>Also here: Cithrin and Navesi</component>")

      expect(indicator_label).to eq 'Cithrin, Navesi'
      expect(color_of(indicator, 'Navesi')).to eq '00ff00'
      expect(color_of(indicator, 'Cithrin, ')).to eq 'ffff00'
    end

    it 'does not color a name a highlight matches only part of' do
      HIGHLIGHT[/ith/] = ['ff0000', nil, nil]

      receive_from_server("<component id='room players'>Also here: Cithrin</component>")

      expect(color_of(indicator, 'Cithrin')).to eq 'ffff00'
    end
  end
end
