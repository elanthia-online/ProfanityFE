# frozen_string_literal: true

# What the user sees of a room for each way DragonRealms, GemStone and Lich
# send it. A room reaches ProfanityFE by two carriers:
#
# - components: the room streamWindow's subtitle, then <component id='room
#   desc'>, 'room objs', 'room players', 'room exits' and 'room extra',
#   sent on every move and whenever a part changes;
# - inline lines: the roomName style, the roomDesc preset or style, and the
#   "You also see" / "Also here:" / "Obvious paths:" lines, sent on a move
#   and on every LOOK (without a description in brief mode), plus the
#   lines Lich adds after them ("Room Number:", "Room Exits:",
#   "StringProcs:").
#
# Characterization: these examples pin what today's code shows for real
# lines (spec/fixtures/room_pipeline/, trimmed from DR logs) and for
# synthetic Lich and GemStone lines, so the room pipeline can be rebuilt
# without changing what the user sees. The examples marked pending
# describe the correct behaviour for bugs the rebuild fixes (spec policy:
# AUDIT §0.2).
#
# Lines are fed through the real server loop (GameTextProcessor#run) into
# windows built from layout XML. The assertions read the virtual screen:
# the room window's rows with the color of each cell and the command a
# click on it sends (RoomWindow#link_cmd_at), the main window's rows, the
# room players indicator, and the terminal title (SharedState#room_title).

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Room carriers' do
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  # Color pair number per foreground color, so a cell's color can be read
  # back from its attributes, and the name the room screen gives it.
  let(:pairs) { { 'ff0000' => 1, '00ff00' => 2, 'ffff00' => 3, '444444' => 4, '5555ff' => 5, '00ffff' => 6 } }
  let(:color_names) do
    { 'ff0000' => 'red', '00ff00' => 'green', 'ffff00' => 'yellow', '444444' => 'grey', '5555ff' => 'link',
      '00ffff' => 'cyan' }
  end

  before do
    allow(IO).to receive(:select).and_return(nil)
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, _bg| pairs.fetch(fg, 0) }
    # Nothing here may reach the desktop (a browser or a clipboard tool).
    expect(Process).not_to receive(:spawn)
    # DR's creatures are bold; the room window draws them in this color.
    PRESET['monsterbold'] = ['ff0000', nil]
    state.blue_links = true
  end

  # Build the windows of a layout and a processor that feeds them. The
  # windows overlap: each keeps its own rows on the virtual screen, and
  # tall windows keep whole rooms in view.
  #
  # @param room_window [Boolean] whether the layout has a room window
  # @param room_attrs [String] extra attributes of the room window
  # @param extra [String] extra <window> elements
  def load_layout(room_window: true, room_attrs: '', extra: '')
    LAYOUT['carriers'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='40' width='100' value='main'/>
        #{"<window class='room' top='1' left='0' height='30' width='100' value='room' #{room_attrs}/>" if room_window}
        <window class='indicator' top='2' left='0' height='1' width='60' label=' ' value='room players' fg='444444,ffff00'/>
        #{extra}
      </layout>
    XML
    event_bus = EventBus.new
    @window_manager = WindowManager.new(shared_state: state)
    @window_manager.load_layout('carriers')
    @window_manager.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @window_manager, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would (Lich ends every line with CRLF). The first prompt sends a LOOK
  # to the server, which takes it.
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

  # The room window's rows as the user sees them, blank rows left out:
  # "{text:color}" where cells are drawn in a color (named in
  # +color_names+), "[text](cmd)" where a click sends +cmd+ and the cells
  # are drawn in the link color ("[text:color](cmd)" in another color).
  def room_screen
    room = @window_manager.room['room']
    room.rows.each_index.filter_map do |y|
      next if room.row(y).strip.empty?

      runs = room.row(y).rstrip.each_char.with_index.chunk_while do |(_, a), (_, b)|
        cell(room, y, a) == cell(room, y, b)
      end
      runs.map { |chars| markup(chars.map(&:first).join, *cell(room, y, chars.first.last)) }.join
    end
  end

  # The color name and link command of a room window cell.
  def cell(room, y, x)
    [color_names[pairs.key(room.attrs_at(y, x) >> 8)], room.link_cmd_at(y, x)]
  end

  # One run of equal cells in {#room_screen}'s notation.
  def markup(text, color, cmd)
    if cmd
      color == 'link' ? "[#{text}](#{cmd})" : "[#{text}:#{color}](#{cmd})"
    elsif color
      "{#{text}:#{color}}"
    else
      text
    end
  end

  # The main window's rows, blank rows and trailing blanks left out.
  def main_rows = @window_manager.stream['main'].rows.map(&:rstrip).reject(&:empty?)

  # The room players indicator's label and the color it is drawn in.
  def indicator
    window = @window_manager.indicator['room players']
    [window.rows.first.rstrip, color_names[pairs.key(window.attrs_at(0, 0) >> 8)]]
  end

  let(:full_move_room) do
    ['[Kaal Utewg, Understory] (4219301)',
     'The faint path leading into the forest vanishes within the ghostly mist that snakes its way around',
     'gnarled and twisted tree trunks.  Night reigns unchallenged.',
     'You also see {a fuligin umbral moth:red}, a fuligin moth antenna, a sloping path framed by craggy trees,',
     '{a fuligin umbral moth:red}, some knee-high cotton boots and some junk.',
     'Also here: Randomly Bias Dartwin.',
     'Obvious paths: [northeast](northeast), [east](east), [southeast](southeast).']
  end

  describe 'a DR move: subtitle, components, the inline view, compass, a trailing players component' do
    it 'shows the room with its creatures and exit links, and every line in main' do
      load_layout

      receive_from_server(*fixture('dr_full_move'))

      expect(room_screen).to eq full_move_room
      expect(main_rows).to eq [
        '[Kaal Utewg, Understory] (4219301)',
        'The faint path leading into the forest vanishes within the ghostly mist that snakes its way',
        'around gnarled and twisted tree trunks.  Night reigns unchallenged.',
        'You also see a fuligin umbral moth, a fuligin moth antenna, a sloping path framed by craggy',
        'trees, a fuligin umbral moth, some knee-high cotton boots and some junk.',
        'Also here: Randomly Bias Dartwin.',
        'Obvious paths: northeast, east, southeast.'
      ]
      expect(indicator).to eq %w[Dartwin yellow]
      expect(state.room_title).to eq 'Kaal Utewg, Understory (4219301)'
    end

    it 'shows no link cells with links off' do
      state.blue_links = false
      load_layout

      receive_from_server(*fixture('dr_full_move'))

      expect(room_screen.last).to eq 'Obvious paths: northeast, east, southeast.'
    end

    it 'drops the room lines from main under --room-window-only' do
      state.room_window_only = true
      load_layout

      receive_from_server(*fixture('dr_full_move'))

      expect(room_screen).to eq full_move_room
      expect(main_rows).to be_empty
    end

    it 'shows every line in main without a room window, and the players in the indicator' do
      load_layout(room_window: false)

      receive_from_server(*fixture('dr_full_move'))

      expect(main_rows).to eq [
        '[Kaal Utewg, Understory] (4219301)',
        'The faint path leading into the forest vanishes within the ghostly mist that snakes its way',
        '  around gnarled and twisted tree trunks.  Night reigns unchallenged.  You also see a fuligin',
        '  umbral moth, a fuligin moth antenna, a sloping path framed by craggy trees, a fuligin umbral',
        '  moth, some knee-high cotton boots and some junk.',
        'Also here: Randomly Bias Dartwin.',
        'Obvious paths: northeast, east, southeast.'
      ]
      expect(indicator).to eq %w[Dartwin yellow]
      expect(state.room_title).to eq 'Kaal Utewg, Understory (4219301)'
    end
  end

  describe 'an inline room without components' do
    let(:room) do
      ['[Kaal Utewg, Old Growth] (4219307)',
       'In the darkness, the forms of ancient trees appear to coalesce into a single malevolent entity.',
       'You also see {a void-black umbral moth:red}, a steep trail leading downhill, {a void-black umbral moth:red} and',
       'some junk.',
       'Obvious paths: [northeast](northeast), [east](east), [southeast](southeast).']
    end

    it 'shows the room from the inline lines, and every line in main' do
      load_layout

      receive_from_server(*fixture('dr_inline_only'))

      expect(room_screen).to eq room
      expect(main_rows).to eq [
        'You will now see room descriptions.',
        '>',
        '[Kaal Utewg, Old Growth] (4219307)',
        'In the darkness, the forms of ancient trees appear to coalesce into a single malevolent entity.',
        'You also see a void-black umbral moth, a steep trail leading downhill, a void-black umbral moth',
        'and some junk.',
        'Obvious paths: northeast, east, southeast.'
      ]
      expect(indicator).to eq ['', 'grey']
      expect(state.room_title).to eq 'Kaal Utewg, Old Growth (4219307)'
    end

    it 'drops the room lines from main under --room-window-only' do
      state.room_window_only = true
      load_layout

      receive_from_server(*fixture('dr_inline_only'))

      expect(room_screen).to eq room
      expect(main_rows).to eq ['You will now see room descriptions.']
    end

    it 'shows every line in main without a room window' do
      load_layout(room_window: false)

      receive_from_server(*fixture('dr_inline_only'))

      expect(main_rows).to eq [
        'You will now see room descriptions.',
        '>',
        '[Kaal Utewg, Old Growth] (4219307)',
        'In the darkness, the forms of ancient trees appear to coalesce into a single malevolent entity.',
        '  You also see a void-black umbral moth, a steep trail leading downhill, a void-black umbral moth',
        '  and some junk.',
        'Obvious paths: northeast, east, southeast.'
      ]
      expect(state.room_title).to eq 'Kaal Utewg, Old Growth (4219307)'
    end
  end

  describe 'a brief-mode move and a brief LOOK (no inline description)' do
    let(:room) do
      ["[The Edge of the Forest, Before the Dragon's Breath] (2030003)",
       'The lushness of the forest begins to form a living wall, the leaves of the towering trees tinted',
       'with the dark hue of brightly-polished scales.',
       'Obvious paths: [southwest](southwest).']
    end

    it "keeps the component's description" do
      load_layout

      receive_from_server(*fixture('dr_brief_move'))

      expect(room_screen).to eq room
      expect(main_rows).to eq [
        "[The Edge of the Forest, Before the Dragon's Breath] (2030003)",
        'Obvious paths: southwest.',
        '>',
        'You will no longer see room descriptions.',
        '>',
        "[The Edge of the Forest, Before the Dragon's Breath] (2030003)",
        'Obvious paths: southwest.'
      ]
    end

    it 'drops the room lines from main under --room-window-only' do
      state.room_window_only = true
      load_layout

      receive_from_server(*fixture('dr_brief_move'))

      expect(room_screen).to eq room
      expect(main_rows).to eq ['>', 'You will no longer see room descriptions.']
    end
  end

  describe 'a move with only the desc and extra components' do
    it 'fills the objects and exits from the inline lines, and keeps the component description' do
      load_layout

      receive_from_server(*fixture('dr_partial_components'))

      expect(room_screen).to eq [
        '[Undergondola, Narrow Path] (2280067)',
        'Widening and flattening out, the steep climb begins to level into a narrow path up the',
        'mountainside.  Tall purple lupine blossoms line the trail, their fragrance mingling with the crisp',
        'mountain air in a refreshing pause on an arduous journey.',
        'You also see a stone wall.',
        'Obvious paths: [up](up), [down](down).'
      ]
      expect(main_rows).to eq ['[Undergondola, Narrow Path] (2280067)', 'You also see a stone wall.', 'Obvious paths: up, down.']
    end
  end

  describe 'a LOOK with newer objects than the last objs component' do
    it "shows the LOOK's objects" do
      load_layout

      receive_from_server(*fixture('dr_look_newer_objects'))

      expect(room_screen).to eq [
        "[Jeol'gelvmoraen, Ice Grottos] (4217405)",
        'Lined in an immense layer of ice, the cavern expands outward into chamber after endless chamber.',
        'You also see {a jeol moradu:red}, a huge bronze bar, {a jeol moradu:red} (prone), ' \
        '{a jeol moradu:red} (dead), {a jeol:red}',
        '{moradu:red}, a pair of burlap slippers, a small pewter bar, {a jeol moradu:red} and some junk.',
        'Also here: Shadow Priest Promithius and Monster Gorkus.',
        'Obvious exits: [north](north), [northeast](northeast), [east](east), [southwest](southwest), ' \
        '[west](west), [northwest](northwest).'
      ]
      expect(indicator).to eq ['Promithius, Gorkus', 'yellow']
    end
  end

  describe 'a LOOK after a trailing players component' do
    it "shows the LOOK's own players line" do
      load_layout

      receive_from_server(*fixture('dr_look_after_players'))

      expect(room_screen[3..4]).to eq [
        'Also here: Holdigor who is emanating a benevolent holy aura, Paintress Catheroine who is blurred by',
        'hazy afterimages, Traveler Fidon who is awash in Xibar-blue light, Meraud\'s Hand Evro who is'
      ]
    end

    it "keeps the indicator's names, which the statuses don't change" do
      load_layout

      receive_from_server(*fixture('dr_look_after_players'))

      expect(indicator).to eq ['Holdigor, Catheroine, Fidon, Evro, Mahtra, Quilsilgas, Ytter', 'yellow']
      expect(main_rows.last(4)).to eq [
        'Also here: Holdigor who is emanating a benevolent holy aura, Paintress Catheroine who is blurred',
        'by hazy afterimages, Traveler Fidon who is awash in Xibar-blue light, Meraud\'s Hand Evro who is',
        'emanating a bright holy aura, Emerald Knight Mahtra, Quilsilgas and Druid Ytterby.',
        'Obvious paths: north, south.'
      ]
    end
  end

  describe "DR's cut-short objs component, then the full inline list in the same move" do
    it 'shows the full inline list, with every creature' do
      load_layout

      receive_from_server(*fixture('dr_cut_short_objs'))

      expect(room_screen.drop(3)).to eq [
        'You also see a small lavender kunzite, a small moss-green bloodstone, a small yellow-green',
        'alexandrite, a small periwinkle sapphire, a small banded red-orange sunstone, a huge cinnamon piece',
        'of amber, a huge orange morganite, a small green-yellow bloodstone, a small blue moonstone, a large',
        'cinnamon quartz, a large grey hematite, a tiny silver nugget, a small pewter bar, a large pewter',
        'bar, a massive covellite nugget, a medium bronze bar, a massive bronze bar, a small steel bar, a',
        'massive brass bar, an Imperial dira, {an ice archon:red}, {an ice archon:red}, {an ice archon:red}, ' \
        '{an ice archon:red}, {an:red}',
        '{ice archon:red}, {a pile of broken ice:red} (dead), {an ice archon:red}, {an ice archon:red}, ' \
        '{an ice archon:red}, {a pile of:red}',
        '{broken ice:red} (dead), {an ice archon:red}, {an ice archon:red}, {an ice archon:red}, a medium ' \
        'cinnamon carnelian, a huge',
        'oravir nugget, an embroidery needle, a wooden hairbrush, an Immortal Meraud card, a steep cliff',
        'leading sharply upward, a steep ledge leading sharply downward, {an ice archon:red}, {an ice archon:red}, a',
        'small yellow beryl, a large green chrysoprase, {an ice archon:red} and some junk.',
        'Also here: Innocent Bystander Rubeis, Eternal Judgement Vladmirr, Philosopher Gallifreius and Siege',
        'General Maekthar.',
        'Obvious paths: none.'
      ]
    end
  end

  describe 'a LOOK after "flag showroomid off"' do
    it 'shows the title without the room number, in the room window and the terminal title' do
      load_layout

      receive_from_server(*fixture('dr_showroomid_off'))

      expect(room_screen.first).to eq "[Bosque Deriel, Hermit's Shacks]"
      expect(state.room_title).to eq "Bosque Deriel, Hermit's Shacks"
    end
  end

  describe 'two room changes in one prompt cycle' do
    it 'shows the second room' do
      load_layout

      receive_from_server(*fixture('dr_two_moves_one_cycle'))

      expect(room_screen).to eq [
        "[Bosque Deriel, Hermit's Shacks] (230008)",
        'Here on the route between the sacred sites of the Observatory and the Faery Ring is a semi-circular',
        'clearing.',
        'You also see a floating vessel of flaring crimson light.',
        "Also here: Holdigor, Inquisitor Eylise, War 'Tog Draze and Quilsilgas.",
        'Obvious paths: [north](north), [south](south).'
      ]
      expect(indicator).to eq ['Holdigor, Eylise, Draze, Quilsilgas', 'yellow']
      expect(state.room_title).to eq "Bosque Deriel, Hermit's Shacks (230008)"
    end
  end

  describe "Lich's lines" do
    let(:prompt) { '<prompt time="1">&gt;</prompt>' }

    # A DR move with a description, then the given roomName text.
    def move(title, desc: "<preset id='roomDesc'>Desc of A.</preset>  ")
      ["<streamWindow id='room' title='Room' subtitle=\" - [A] (1)\" location='center' target='drop' ifClosed='' resident='true'/>",
       "<component id='room desc'>Desc of A.</component>", "<component id='room objs'></component>",
       "<component id='room players'></component>",
       "<component id='room exits'>Obvious paths: <d>north</d>.<compass></compass></component>",
       "<component id='room extra'></component>",
       "<resource picture=\"0\"/><style id=\"roomName\" />#{title}", "<style id=\"\"/>#{desc}", 'Obvious paths: <d>north</d>.']
    end

    let(:plain_lines) { ['Room Number: 1234 - (u230008)', 'Room Exits: go gate, climb ladder', 'StringProcs: go path'] }
    let(:linked_lines) do
      ['<output class="mono"/>Room Number: 1234<output class=""/>',
       "Room Exits: <d cmd='go gate'>go gate</d>, <d cmd='climb wall &amp; rope'>climb</d>",
       "StringProcs: <d cmd=';go2 7'>Town</d>"]
    end

    it 'shows Room Exits under the exits, then Room Number and StringProcs' do
      load_layout

      receive_from_server(*move('[A] (1)'), *plain_lines, prompt)

      expect(room_screen).to eq ['[A] (1)', 'Desc of A.', 'Obvious paths: [north](north).',
                                 'Room Exits: go gate, climb ladder', 'Room Number: 1234 - (u230008)', 'StringProcs: go path']
      expect(main_rows).to eq ['[A] (1)', 'Desc of A.', 'Obvious paths: north.',
                               'Room Number: 1234 - (u230008)', 'Room Exits: go gate, climb ladder', 'StringProcs: go path']
    end

    it "makes Room Exits' links clickable, and shows StringProcs as text" do
      load_layout

      receive_from_server(*move('[A] (1)'), *linked_lines, prompt)

      expect(room_screen).to eq ['[A] (1)', 'Desc of A.', 'Obvious paths: [north](north).',
                                 'Room Exits: [go gate](go gate), [climb](climb wall &amp; rope)', 'Room Number: 1234',
                                 'StringProcs: Town']
    end

    it 'decodes entities in the text of Room Exits' do
      load_layout

      receive_from_server(*move('[A] (1)'), "Room Exits: <d cmd='climb'>climb wall &amp; rope</d>", prompt)

      expect(room_screen.last).to eq 'Room Exits: [climb wall & rope](climb)'
    end

    # Characterization: no link decodes entities in its cmd attribute (the
    # main window's and the room components' links don't either), so a
    # click sends the attribute as the game wrote it.
    it "sends a Room Exits link's cmd with its entities as written" do
      load_layout

      receive_from_server(*move('[A] (1)'), "Room Exits: <d cmd='climb wall &amp; rope'>climb</d>", prompt)

      expect(room_screen.last).to eq 'Room Exits: [climb](climb wall &amp; rope)'
    end

    # Characterization (passes on the base by design): the room window
    # keeps the links of a room read while .links is off, so they work
    # once .links is turned on.
    it 'makes the links of a room read with links off clickable once links are turned on' do
      state.blue_links = false
      load_layout

      receive_from_server('<resource picture="0"/><style id="roomName" />[A] (1)',
                          '<style id=""/>  You also see <a exist="1" noun="box">a box</a>.', 'Obvious paths: <d>north</d>.',
                          "Room Exits: <d cmd='go gate'>go gate</d>")
      shown_with_links_off = room_screen
      state.blue_links = true
      @window_manager.room['room'].render

      expect(shown_with_links_off).to eq ['[A] (1)', 'You also see a box.', 'Obvious paths: north.', 'Room Exits: go gate']
      expect(room_screen).to eq ['[A] (1)', 'You also see [a box](look #1).', 'Obvious paths: [north](north).',
                                 'Room Exits: [go gate](go gate)']
    end

    it 'shows the linked lines as text with links off' do
      state.blue_links = false
      load_layout

      receive_from_server(*move('[A] (1)'), *linked_lines, prompt)

      expect(room_screen.last(3)).to eq ['Room Exits: go gate, climb', 'Room Number: 1234', 'StringProcs: Town']
    end

    it 'drops them from main under --room-window-only' do
      state.room_window_only = true
      load_layout

      receive_from_server(*move('[A] (1)'), *linked_lines, prompt)

      expect(room_screen.last(3)).to eq ['Room Exits: [go gate](go gate), [climb](climb wall &amp; rope)',
                                         'Room Number: 1234', 'StringProcs: Town']
      expect(main_rows).to be_empty
    end

    it 'shows them in main without a room window' do
      load_layout(room_window: false)

      receive_from_server(*move('[A] (1)'), *linked_lines, prompt)

      expect(main_rows).to eq ['[A] (1)', 'Desc of A.', 'Obvious paths: north.', 'Room Number: 1234',
                               'Room Exits: go gate, climb', 'StringProcs: Town']
    end

    it "shows a Lich room id in the title row, and names the terminal title the same (';display roomid title')" do
      load_layout

      receive_from_server(*move('[A - 55] (1)'), prompt)

      expect(room_screen).to eq ['[A - 55] (1)', 'Desc of A.', 'Obvious paths: [north](north).']
      expect(state.room_title).to eq 'A - 55 (1)'
    end

    it "keeps the component's description on a brief move with a Lich room id in the title" do
      load_layout

      receive_from_server(*move('[A - 55] (1)', desc: '  '), prompt)

      expect(room_screen).to eq ['[A - 55] (1)', 'Desc of A.', 'Obvious paths: [north](north).']
    end

    # Lich (at least since v5.11.0) sends the room's uid alone with
    # ';display uid' on and ';display lichid' off, and "(**)" in a room
    # without a uid; ';display mono' wraps the line. Up to v5.19, with both
    # on in an unmapped room, the missing lich id leaves " - (u230008)".
    # Lich sends the line before Room Exits.
    { 'the uid' => '(u230008)', 'no uid' => '(**)', 'no lich id' => ' - (u230008)' }.each do |room, id|
      plain = "Room Number: #{id}"
      { 'plain' => plain, 'mono' => %(<output class="mono"/>#{plain}<output class=""/>) }.each do |form, line|
        it "shows a uid-only Room Number (#{room}, #{form}) under the exits, and in main" do
          load_layout

          receive_from_server(*move('[A] (1)'), line, 'Room Exits: go gate', prompt)

          expect(room_screen).to eq ['[A] (1)', 'Desc of A.', 'Obvious paths: [north](north).',
                                     'Room Exits: go gate', "Room Number: #{id}"]
          expect(main_rows).to eq ['[A] (1)', 'Desc of A.', 'Obvious paths: north.', "Room Number: #{id}",
                                   'Room Exits: go gate']
        end

        it "drops a uid-only Room Number (#{room}, #{form}) from main under --room-window-only" do
          state.room_window_only = true
          load_layout

          receive_from_server(*move('[A] (1)'), line, 'Room Exits: go gate', prompt)

          expect(room_screen.last(2)).to eq ['Room Exits: go gate', "Room Number: #{id}"]
          expect(main_rows).to be_empty
        end
      end
    end

    it 'takes a Room Number line only when text follows the colon (--room-window-only)' do
      state.room_window_only = true
      load_layout

      receive_from_server(*move('[A] (1)'), 'Room Number:', prompt)

      expect(room_screen).to eq ['[A] (1)', 'Desc of A.', 'Obvious paths: [north](north).']
      expect(main_rows).to eq ['Room Number:']

      receive_from_server(*move('[B] (2)'), 'Room Number: (**)', prompt)

      expect(room_screen).to eq ['[B] (2)', 'Desc of A.', 'Obvious paths: [north](north).', 'Room Number: (**)']
      expect(main_rows).to eq ['Room Number:']
    end
  end

  describe 'GemStone lines (synthetic): links on every part, a roomDesc style after text' do
    let(:lines) do
      ["<streamWindow id='room' title='Room' subtitle=\" - [Wayside Inn, Lobby]\" location='center' target='drop' ifClosed='' resident='true'/>",
       "<component id='room desc'>A cozy <a exist=\"-1\" noun=\"fire\">fire</a> warms the lobby.</component>",
       "<component id='room objs'>You also see a <a exist=\"-2\" noun=\"bench\">bench</a> and <pushBold/>a <a exist=\"-3\" noun=\"rat\">rat</a><popBold/>.</component>",
       "<component id='room players'>Also here: <a exist=\"-4\" noun=\"Bob\">Bob</a>.</component>",
       "<component id='room exits'>Obvious paths: <a exist=\"-5\" noun=\"out\">out</a><compass><dir value=\"out\"/></compass></component>",
       "<style id='roomName'/>[Wayside Inn, Lobby]<style id=''/>",
       "Some text. <style id='roomDesc'/>A cozy <a exist=\"-1\" noun=\"fire\">fire</a> warms the lobby.<style id=''/>  " \
       "You also see a <a exist=\"-2\" noun=\"bench\">bench</a> and <pushBold/>a <a exist=\"-3\" noun=\"rat\">rat</a><popBold/>.",
       "Also here: <a exist=\"-4\" noun=\"Bob\">Bob</a>.",
       "Obvious paths: <a exist=\"-5\" noun=\"out\">out</a>",
       '<prompt time="1">&gt;</prompt>']
    end

    it 'shows the room with its links and creature, and the lines in main' do
      load_layout

      receive_from_server(*lines)

      expect(room_screen).to eq [
        '[Wayside Inn, Lobby]',
        'A cozy [fire](look #-1) warms the lobby.',
        'You also see a [bench](look #-2) and {a :red}[rat](look #-3).',
        'Also here: [Bob](look #-4).',
        'Obvious paths: [out](look #-5)'
      ]
      expect(main_rows).to eq ['[Wayside Inn, Lobby]', 'Some text. A cozy fire warms the lobby.', 'You also see a bench and a rat.',
                               'Also here: Bob.', 'Obvious paths: out']
      # The players component delivered the players: the indicator keeps its
      # link's color, which the inline line doesn't have.
      expect(indicator).to eq %w[Bob link]
      expect(state.room_title).to eq 'Wayside Inn, Lobby'
    end

    it "keeps the links of the inline players line" do
      load_layout

      receive_from_server(*lines)

      expect(room_screen[3]).to eq 'Also here: [Bob](look #-4).'
    end

    it 'drops the room lines from main under --room-window-only, with the text before the style' do
      state.room_window_only = true
      load_layout

      receive_from_server(*lines)

      expect(main_rows).to be_empty
    end

    it 'shows every line in main without a room window' do
      load_layout(room_window: false)

      receive_from_server(*lines)

      expect(main_rows).to eq ['[Wayside Inn, Lobby]', 'Some text. A cozy fire warms the lobby.  You also see a bench and a rat.',
                               'Also here: Bob.', 'Obvious paths: out']
      expect(indicator).to eq %w[Bob yellow]
    end
  end

  describe 'latent bugs the rebuild fixes (none occurs in the corpus)' do
    let(:inline_room) { ['<resource picture="0"/><style id="roomName" />[A] (1)', '<style id=""/>  '] }

    it 'P3: draws the bold creatures of an objs component without a monsterbold preset' do
      PRESET.delete('monsterbold')
      PRESET['creature'] = ['00ff00', nil]
      load_layout(room_attrs: "creatures-preset='creature'")

      receive_from_server("<component id='room objs'>You also see <pushBold/>a rat<popBold/> and a box.</component>")

      expect(room_screen).to eq ['You also see {a rat:green} and a box.']
    end

    # Characterization: the inline path already took bold spans for
    # creatures whatever color bold is drawn in.
    it 'draws the bold creatures of an inline LOOK without a monsterbold preset' do
      PRESET.delete('monsterbold')
      PRESET['creature'] = ['00ff00', nil]
      load_layout(room_attrs: "creatures-preset='creature'")

      receive_from_server(*inline_room, '  You also see <pushBold/>a rat<popBold/> and a box.', 'Obvious paths: <d>north</d>.')

      expect(room_screen[1]).to eq 'You also see {a rat:green} and a box.'
    end

    # Characterization: an empty bold span names no creature.
    it 'takes no creature from an empty bold span in an objs component' do
      load_layout

      receive_from_server("<component id='room objs'>You also see <pushBold/> <popBold/>a box and <pushBold/>a rat<popBold/>.</component>")

      expect(room_screen).to eq ['You also see  a box and {a rat:red}.']
    end

    # Characterization: a creature is its bold span's text without the
    # spaces around it.
    it 'takes a bold span that starts with a space in an objs component for the creature without it' do
      load_layout

      receive_from_server("<component id='room objs'>You also see<pushBold/> a rat<popBold/>.</component>")

      expect(room_screen).to eq ['You also see {a rat:red}.']
    end

    # The component's text starts inside the bold span, on spaces the row
    # leaves out; the creature is still the span's text (it was lost).
    it 'takes a bold span over the leading spaces of an objs component for a creature' do
      load_layout

      receive_from_server("<component id='room objs'><pushBold/>  a rat<popBold/> and a tall rat.</component>")

      expect(room_screen).to eq ['{a rat:red} and a tall rat.']
    end

    it "P3b: doesn't take a preset in monsterbold's color inside an objs component for a creature" do
      PRESET['speech'] = ['ff0000', nil]
      load_layout

      receive_from_server("<component id='room objs'>You also see <preset id='speech'>a box</preset> and <pushBold/>a rat<popBold/>.</component>")

      expect(room_screen).to eq ['You also see a box and {a rat:red}.']
    end

    it "P3b: doesn't take a highlight in monsterbold's color inside an objs component for a creature" do
      PRESET['creature'] = ['00ff00', nil]
      HIGHLIGHT[/a box/] = ['ff0000', nil, nil]
      # A layout with a window for the room objs stream (as the commented-out
      # line in the live settings has) applies highlights to its text.
      load_layout(room_attrs: "creatures-preset='creature'",
                  extra: "<window class='text' top='3' left='0' height='3' width='100' value='room objs'/>")

      receive_from_server("<component id='room objs'>You also see a box and <pushBold/>a rat<popBold/>.</component>")

      expect(room_screen).to eq ['You also see {a box:red} and {a rat:green}.']
    end

    it 'P4: pairs nested inline links by nesting, the innermost winning' do
      load_layout

      receive_from_server(*inline_room, "  You also see <d cmd='a'>x<d cmd='b'>y</d>z</d> and a box.", 'Obvious paths: <d>north</d>.')

      expect(room_screen[1]).to eq 'You also see [x](a)[y](b)[z](a) and a box.'
    end

    it 'P4b: decodes entities in the inline objects' do
      load_layout

      receive_from_server(*inline_room, '  You also see a &lt;red&gt; box.', 'Obvious paths: <d>north</d>.')

      expect(room_screen[1]).to eq 'You also see a <red> box.'
      expect(main_rows[1]).to eq 'You also see a <red> box.'
    end

    it 'keeps the links of players a component delivered, over the inline line of the same burst (GemStone)' do
      load_layout

      receive_from_server("<component id='room exits'>Obvious paths: out</component>",
                          "<component id='room players'>Also here: <a exist=\"-4\" noun=\"Bob\">Bob</a>.</component>",
                          *inline_room, 'Also here: Bob.', 'Obvious paths: out')

      expect(room_screen).to eq ['[A] (1)', 'Also here: [Bob](look #-4).', 'Obvious paths: out']
    end

    it 'keeps the links of a description a component delivered when the inline commit follows (GemStone)' do
      load_layout

      receive_from_server(%(<component id='room desc'>A <a exist="7" noun="gate">gate</a> here.</component>),
                          *inline_room, 'Obvious paths: out')

      expect(room_screen).to eq ['[A] (1)', 'A [gate](look #7) here.', 'Obvious paths: out']
    end

    it 'keeps the creatures of objects a component delivered when the inline commit follows' do
      load_layout

      receive_from_server("<component id='room exits'>Obvious paths: out</component>",
                          "<component id='room objs'>You also see <pushBold/>a rat<popBold/>.</component>",
                          *inline_room, 'Obvious paths: out')

      expect(room_screen).to eq ['[A] (1)', 'You also see {a rat:red}.', 'Obvious paths: out']
    end

    it 'shows no prompt text on an exits line that ends with the prompt' do
      load_layout

      receive_from_server(*inline_room, 'Obvious paths: <d>north</d>.<prompt time="1">&gt;</prompt>')

      expect(room_screen).to eq ['[A] (1)', 'Obvious paths: [north](north).']
    end
  end
end
