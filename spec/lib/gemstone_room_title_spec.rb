# frozen_string_literal: true

# GemStone's room titles show as DragonRealms shows its own (AUDIT §0.2,
# decisions of 2026-10-03: both games display the same way). With
# ShowRoomID on, GemStone sends the room's id after a dash in the room
# subtitle (" - Sanctum Tower, First Floor - 4216031") and after the
# brackets in the roomName ("[Sanctum Tower, First Floor] (4216031)").
# Both show "[Sanctum Tower, First Floor] (4216031)" in the room window's
# title row and "Sanctum Tower, First Floor (4216031)" in the terminal
# title, and name the same room for the new-room test of a subtitle.
#
# The lines are trimmed from real GemStone logs (gs_move.xml and
# gs_death_room.xml in spec/fixtures/room_pipeline) and fed through the
# real server loop into windows built from layout XML.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/games'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'GemStone room title' do
  let(:event_bus) { EventBus.new }
  let(:state) do
    SharedState.new.tap do |s|
      s.skip_server_time_offset = true
      s.char_name = 'Mahtra'
    end
  end
  let(:game_rules) { Games::GemStone }
  # Everything written to the terminal (the title escapes).
  let(:terminal) { [] }

  before do
    allow(IO).to receive(:select).and_return(nil)
    allow(Process).to receive(:setproctitle)
    expect(Process).not_to receive(:spawn)
    allow($stdout).to receive(:write) { |text| terminal << text }
    allow($stdout).to receive(:flush)
    LAYOUT['gs_title'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='8' width='120' value='main'/>
        <window class='room' top='8' left='0' height='8' width='120' value='room'/>
        <window class='indicator' top='16' left='0' height='1' width='60' value='room'/>
      </layout>
    XML
    @wm = WindowManager.new(shared_state: state)
    @wm.load_layout('gs_title')
    @wm.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus, game_rules: game_rules
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would (Lich ends every line with CRLF).
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |_command| nil }
    server.define_singleton_method(:flush) { nil }
    @processor.run(server)
  end

  # The lines of a fixture in spec/fixtures/room_pipeline.
  def fixture(name)
    File.readlines(File.expand_path("../fixtures/room_pipeline/#{name}.xml", __dir__), chomp: true)
  end

  # The room window's rows, blank rows left out.
  def room_rows = @wm.room['room'].rows.map(&:rstrip).reject(&:empty?)

  # The room window's title row: its first row, unless that is another
  # field (a description, objects or exits).
  def title_row
    first = room_rows.first
    first if first&.start_with?('[')
  end

  # Every terminal title written (OSC 0), in order.
  def terminal_titles = terminal.join.scan(/\e\]0;(.*?)\a/).flatten

  def terminal_title = terminal_titles.last

  # The room as a terminal title names it: what follows the prompt.
  def titled_room(title) = title&.[](/\[(?:[^:\]]*:)?(.*)\]\z/, 1)

  def room_indicator = @wm.indicator['room'].rows.first.rstrip

  # The room streamWindow line GemStone sends, with +subtitle+ (as sent,
  # XML-escaped) in place of the real one.
  def stream_window(subtitle)
    %(<streamWindow id='room' title='Room' subtitle="#{subtitle}" location='center' target='drop' ifClosed='' resident='true'/>)
  end

  # A roomName line as GemStone sends it, with +name+ (as sent) in place
  # of the real one.
  def room_name(name)
    ["<resource picture=\"0\"/><style id=\"roomName\" />#{name}", '<style id=""/>  ',
     'Obvious exits: <a exist="-11223064" coord="2524,1864" noun="up">up</a>']
  end

  describe 'a move that sends the subtitle and the roomName (Tysong)' do
    let(:move) { fixture('gs_move') }

    it 'shows the room id after the bracketed name in the title row' do
      receive_from_server(move.first)

      expect(title_row).to eq '[Sanctum Tower, First Floor] (4216031)'
    end

    # On the base, the row read "[Sanctum Tower, First Floor - 4216031]"
    # until the roomName replaced it, and the terminal title changed with
    # it. (The empty room pop hides the row for a few lines: a separate
    # fix, REPORT F3.)
    it 'shows one title row, terminal title and room indicator after every line of the move' do
      seen = move.map do |line|
        receive_from_server(line)
        [title_row, titled_room(terminal_title), room_indicator]
      end

      expect(seen.map(&:first).compact.uniq).to eq ['[Sanctum Tower, First Floor] (4216031)']
      expect(seen.map { |s| s.drop(1) }.uniq).to eq [['Sanctum Tower, First Floor (4216031)'] * 2]
    end

    it 'names the room one way in every terminal title written' do
      receive_from_server(*move)

      expect(terminal_titles.map { |t| titled_room(t) }.uniq).to eq ['Sanctum Tower, First Floor (4216031)']
    end

    it 'shows the whole room as the components and the roomName describe it' do
      receive_from_server(*move)

      expect(room_rows).to eq ['[Sanctum Tower, First Floor] (4216031)',
                               'Drastically unfurling from the narrow halls, the arc-shaped room expands into a sizeable foyer.',
                               'You also see a pale scaled shaper and a long acacia runestaff capped with a carved ivory serpent.',
                               'Obvious exits: southeast, southwest, up']
    end

    # The rule reads the title's form, not the game: a title is parsed the
    # same whichever game's rules are in use.
    [Games::DragonRealms, Games::BOTH_GAMES].each do |rules|
      context "with #{rules.is_a?(Module) ? rules.name : 'both games\''} rules" do
        let(:game_rules) { rules }

        it 'shows the same title row and terminal title for the subtitle' do
          receive_from_server(move.first)

          expect([title_row, terminal_title]).to eq ['[Sanctum Tower, First Floor] (4216031)',
                                                     'Mahtra [Sanctum Tower, First Floor (4216031)]']
        end
      end
    end
  end

  # The death room's id is negative (main session's call: the minus is
  # part of the id).
  describe 'the death room (Pickasso)' do
    let(:death) { fixture('gs_death_room') }

    it 'shows the negative room id after the bracketed name in the title row' do
      receive_from_server(death.first)

      expect(title_row).to eq '[The Darkness Within] (-4216801)'
    end

    it 'names the room with its negative id in the terminal title at the DEAD prompt' do
      receive_from_server(*death)

      expect(terminal_title).to eq 'Mahtra [DEAD:The Darkness Within (-4216801)]'
    end
  end

  # Every way a GemStone title reaches ProfanityFE gives the same title
  # (real names; the pushStream subtitle and the room title component are
  # forms GemStone doesn't send, parsed like the rest).
  describe 'every carrier' do
    {
      'the room streamWindow subtitle' => [%(<streamWindow id='room' title='Room' subtitle=" - Darbo Phoop's, Consignment - 160014" location='center' target='drop' ifClosed='' resident='true'/>)],
      'the room pushStream subtitle'   => [%(<pushStream id='room' subtitle=" - Darbo Phoop's, Consignment - 160014"/>),
                                           "<compDef id='room exits'>Obvious exits: <d>out</d></compDef>"],
      'the roomName'                   => ['<resource picture="0"/><style id="roomName" />[Darbo Phoop&apos;s, Consignment] (160014)',
                                           '<style id=""/>  ', 'Obvious exits: <a exist="-11231170" coord="2524,1864" noun="out">out</a>'],
      'the room title component'       => ["<component id='room title'> - Darbo Phoop&apos;s, Consignment - 160014</component>",
                                           'Obvious exits: <a exist="-11231170" coord="2524,1864" noun="out">out</a>']
    }.each do |carrier, lines|
      it "shows \"[Darbo Phoop's, Consignment] (160014)\" when sent by #{carrier}" do
        receive_from_server(*lines)

        expect([title_row, terminal_title]).to eq ["[Darbo Phoop's, Consignment] (160014)", "Mahtra [Darbo Phoop's, Consignment (160014)]"]
      end
    end
  end

  describe 'what counts as a room id' do
    {
      # A real pit fall (REPORT F3) and a room without ShowRoomID.
      ' - Subterrain, Pit - 4216057'   => ['[Subterrain, Pit] (4216057)', 'Subterrain, Pit (4216057)'],
      ' - Subterrain, Pit'             => ['[Subterrain, Pit]', 'Subterrain, Pit'],
      # Spaces around the title and the dash.
      ' - Subterrain, Pit - 4216057  ' => ['[Subterrain, Pit] (4216057)', 'Subterrain, Pit (4216057)'],
      ' - Subterrain, Pit  -  4216057' => ['[Subterrain, Pit] (4216057)', 'Subterrain, Pit (4216057)'],
      # Only the last dash and id: an earlier one stays in the name.
      ' - A - 12 - 4216057'            => ['[A - 12] (4216057)', 'A - 12 (4216057)'],
      # Not an id after a dash: all name.
      ' - Subterrain, Pit -4216057'    => ['[Subterrain, Pit -4216057]', 'Subterrain, Pit -4216057'],
      ' - Subterrain, Pit - 4216057a'  => ['[Subterrain, Pit - 4216057a]', 'Subterrain, Pit - 4216057a'],
      ' - Subterrain, Pit - 42 16057'  => ['[Subterrain, Pit - 42 16057]', 'Subterrain, Pit - 42 16057'],
      ' - Subterrain, Pit - --4216057' => ['[Subterrain, Pit - --4216057]', 'Subterrain, Pit - --4216057'],
      ' - Subterrain, Pit - '          => ['[Subterrain, Pit -]', 'Subterrain, Pit -'],
      # A name that is a number has no id.
      ' - 4216057'                     => ['[4216057]', '4216057'],
      # A bracketed name keeps what follows it as sent (DragonRealms'
      # titles, and Lich's room ids in GemStone's roomName).
      ' - [Subterrain, Pit] - 4216057' => ['[Subterrain, Pit] - 4216057', 'Subterrain, Pit - 4216057'],
      ' - [Subterrain, Pit - 4216057]' => ['[Subterrain, Pit - 4216057]', 'Subterrain, Pit - 4216057']
    }.each do |sent, (row, room)|
      it "shows the subtitle #{sent.inspect} as #{row.inspect}" do
        receive_from_server(stream_window(sent))

        expect([title_row, terminal_title, room_indicator]).to eq [row, "Mahtra [#{room}]", room]
      end
    end

    # Lich's forms of GemStone's roomName (;display lichid, ;display uid)
    # put its own id in the brackets or after them: shown as Lich sends
    # them.
    {
      '[Sanctum Tower, First Floor - 1234] (4216031)' => ['[Sanctum Tower, First Floor - 1234] (4216031)', 'Sanctum Tower, First Floor - 1234 (4216031)'],
      '[Sanctum Tower, First Floor] (u4216031)'       => ['[Sanctum Tower, First Floor] (u4216031)', 'Sanctum Tower, First Floor (u4216031)']
    }.each do |sent, (row, room)|
      it "shows Lich's roomName #{sent.inspect} as sent" do
        receive_from_server(*room_name(sent))

        expect([title_row, terminal_title]).to eq [row, "Mahtra [#{room}]"]
      end
    end

    # An empty name is no title, as "[] (1234)" is: the row hides, and the
    # terminal title and the room indicator keep naming the last room.
    [' -  - 4216057', ' -  - -4216801', ' -   -   4216057'].each do |sent|
      it "hides the title row for the empty name in #{sent.inspect}, keeping the last room's terminal title" do
        receive_from_server(stream_window(' - Subterrain, Pit - 4216057'), stream_window(sent))

        expect([title_row, terminal_title, room_indicator]).to eq [nil, 'Mahtra [Subterrain, Pit (4216057)]', 'Subterrain, Pit (4216057)']
      end
    end
  end

  # A subtitle names a new room, and clears the exits and objects, when it
  # differs both from the last subtitle and from the title row shown (#229).
  # GemStone's subtitle and roomName now give the same row for a room.
  describe 'the new-room test of a subtitle' do
    let(:move) { fixture('gs_move') }
    # The move's inline view alone: what a LOOK in the room shows.
    let(:look) { move.drop(6) }

    it 'clears nothing when the first subtitle names the room a LOOK showed' do
      receive_from_server(*look)

      receive_from_server(move.first)

      expect(room_rows).to eq ['[Sanctum Tower, First Floor] (4216031)',
                               'Drastically unfurling from the narrow halls, the arc-shaped room expands into a sizeable foyer.',
                               'You also see a pale scaled shaper and a long acacia runestaff capped with a carved ivory serpent.',
                               'Obvious exits: southeast, southwest, up']
    end

    # Characterization (passes on the base too): another room's subtitle
    # clears the exits its burst hasn't sent yet.
    it "clears the last room's exits for a subtitle that names another room" do
      receive_from_server(*look)

      receive_from_server(fixture('gs_death_room').first)

      expect(room_rows.drop(1)).to eq ['A bloody haze obscures the surroundings, spinning in dizzy spirals.  All is not right with the world.']
    end
  end
end
