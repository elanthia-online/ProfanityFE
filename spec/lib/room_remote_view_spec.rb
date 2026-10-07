# frozen_string_literal: true

# A view of another room on main. DR's Locate (Moon Mage) shows the room
# of the person located as an inline view, as a LOOK would (roomName,
# roomDesc, "You also see", "Also here:", "Obvious paths:"), with no nav
# tag, subtitle or room components. It is not the player's room: it goes
# to the familiar window (main when the layout has none), as GemStone's
# familiar views do, and leaves the room window, the terminal title and
# the room players indicator alone. It is told apart by its room id: the
# roomName's (DR's showroomid, GemStone's ShowRoomID) isn't the last
# <nav rm='NNN'/>'s, which both games send on every room change.
#
# The Locate and LOOK lines are real (spec/fixtures/room_pipeline/
# dr_locate.xml: Fidon's log of 2026-10-07); the arrival before them is
# built in DR's format (the log starts after it), driven through the real
# server loop into windows built from layout XML.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'A view of another room (DR Locate)' do
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  # Every non-empty :stream_text emit, as [stream, text].
  let(:shown) { [] }
  let(:indicator_labels) { [] }

  let(:kweld_title) { "[Kweld Andu, Pathway's End] (1225103)" }
  let(:kweld_desc) do
    'Abruptly ending at a great wall of soil, this path must have washed away in a slide.  Thick grass, ' \
      'large trees, and all types of roots have all taken hold here, displaying the stability and age of ' \
      'the surrounding earth.'
  end
  # Fidon's LOOK at 13:10:36, after the Locate
  let(:kweld_look) do
    [%(<resource picture="0"/><style id="roomName" />#{kweld_title}),
     %(<style id=""/><preset id='roomDesc'>#{kweld_desc}</preset>  You also see a canvas tent and a dirt bank.),
     'Obvious paths: <d>east</d>.',
     '<compass><dir value="e"/></compass><prompt time="1791331836">&gt;</prompt>']
  end
  # Moving into Kweld Andu, in DR's format: nav tag, subtitle, components,
  # then the inline view
  let(:kweld_arrival) do
    ["<nav rm='1225103'/>",
     %(<streamWindow id='main' title='Story' subtitle=" - #{kweld_title}" location='center' target='drop'/>),
     %(<streamWindow id='room' title='Room' subtitle=" - #{kweld_title}" location='center' target='drop' ifClosed='' resident='true'/>),
     "<component id='room desc'>#{kweld_desc}</component>",
     "<component id='room objs'>You also see a canvas tent and a dirt bank.</component>",
     "<component id='room players'></component>",
     "<component id='room exits'>Obvious paths: <d>east</d>.<compass></compass></component>",
     "<component id='room extra'></component>",
     *kweld_look]
  end
  let(:remote_lines) do
    ['[Willow Walk, Willow Tree] (84081)',
     'The massive weeping willow tree for which the garden is named spreads its trailing branches toward the ' \
     'ground, veiling the area and swaying with every breath of passing breeze to both reveal and conceal.  ' \
     'Occasionally, the leaves part enough to allow a glimpse to the south of the Sorrow Garden in which the ' \
     'Empath Guild Leader stands, and the tall wrought-iron fence running between there and here.',
     'You also see a pine-trimmed home with an Elven ivy trellis along the path to the door, a white ' \
     'oak-shingled cottage with a weeping willow tree in the front yard, an ivy-covered hall with a crumbling ' \
     'brick chimney visible over the roof, a cozy blue stucco abode and a dark cedar frame house.',
     'Also here: Quilsilgas.',
     'Obvious paths: north, east, west.']
  end

  def load_layout(*windows)
    LAYOUT['test'] = REXML::Document.new("<layout>#{windows.join}</layout>").root
    @wm = WindowManager.new
    @wm.load_layout('test')
    @wm.subscribe_to_events(event_bus)
    event_bus.on(:stream_text) { |data| shown << [data[:stream], data[:text]] unless data[:text].empty? }
    event_bus.on(:indicator_update) { |data| indicator_labels << data[:label] if data[:id] == 'room players' }
    @processor = GameTextProcessor.new(
      window_mgr: @wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  let(:main_window) { "<window class='text' top='0' left='0' height='4' width='80' value='main'/>" }
  let(:room_window) { "<window class='room' top='4' left='0' height='12' width='80' value='room'/>" }
  let(:familiar_window) { "<window class='text' top='16' left='0' height='8' width='80' value='familiar'/>" }

  before { allow(IO).to receive(:select).and_return(nil) }

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would. The first prompt sends a LOOK to the server, which takes it.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |_command| nil }
    server.define_singleton_method(:flush) { nil }
    @processor.run(server)
  end

  def locate
    File.readlines(File.expand_path('../fixtures/room_pipeline/dr_locate.xml', __dir__), chomp: true)
  end

  def room_rows = @wm.room['room'].rows.map(&:rstrip).reject(&:empty?)
  def texts_on(stream) = shown.select { |s, _| s == stream }.map(&:last)

  context 'with a room window and a familiar window' do
    before { load_layout(main_window, room_window, familiar_window) }

    it 'shows the view in the familiar window, and leaves the room window and terminal title alone' do
      receive_from_server(*kweld_arrival)
      kweld_rows = room_rows
      expect(kweld_rows.first).to eq kweld_title
      shown.clear

      receive_from_server(*locate)

      expect(room_rows).to eq kweld_rows
      expect(texts_on('familiar')).to eq remote_lines
      expect(texts_on('main')).to eq ['You gesture.']
      expect(state.room_title).to eq "Kweld Andu, Pathway's End (1225103)"
    end

    it "doesn't put the located room's players in the room players indicator" do
      receive_from_server(*kweld_arrival)
      indicator_labels.clear

      receive_from_server(*locate)

      expect(indicator_labels).to be_empty
    end

    it 'ends the view at its exits line: a LOOK after it is the room window\'s again' do
      receive_from_server(*kweld_arrival, *locate)
      shown.clear

      receive_from_server(*kweld_look)

      expect(texts_on('familiar')).to be_empty
      expect(room_rows.first).to eq kweld_title
      expect(room_rows.last).to eq 'Obvious paths: east.'
    end

    it 'ends the view at its exits line when the prompt is on that line' do
      one_line_end = [*locate.first(4), %(#{locate[4]}<compass></compass><prompt time="1791331818">&gt;</prompt>)]
      receive_from_server(*kweld_arrival)
      kweld_rows = room_rows

      receive_from_server(*one_line_end)

      expect(room_rows).to eq kweld_rows
      expect(texts_on('familiar').last).to eq 'Obvious paths: north, east, west.'
    end

    it 'ends a view that never sends its exits line at the prompt' do
      receive_from_server(*kweld_arrival, *locate.first(4), '<prompt time="1791331818">&gt;</prompt>')
      shown.clear

      receive_from_server(*kweld_look)

      expect(texts_on('familiar')).to be_empty
      expect(texts_on('main')).to include(kweld_title)
    end

    it 'shows the next room after a move as usual' do
      willow_arrival = kweld_arrival.map { |line| line.gsub('1225103', '84081').gsub(kweld_title.sub(' (1225103)', ''), '[Willow Walk, Willow Tree]') }
      receive_from_server(*kweld_arrival, *locate, 'You go east.', *willow_arrival)

      expect(room_rows.first).to eq '[Willow Walk, Willow Tree] (84081)'
      expect(state.room_title).to eq 'Willow Walk, Willow Tree (84081)'
    end

    it "tells the view apart when Lich's ;display lichid puts its id in the roomName" do
      lich_locate = locate.map { |line| line.sub('Willow Tree] (84081)', 'Willow Tree - 1234] (84081)') }
      receive_from_server(*kweld_arrival)
      kweld_rows = room_rows

      receive_from_server(*lich_locate)

      expect(room_rows).to eq kweld_rows
      expect(texts_on('familiar').first).to eq '[Willow Walk, Willow Tree - 1234] (84081)'
    end

    # Without room ids the names decide: the view names a room other than
    # the last subtitle's.
    it "tells a view without the game's room id apart by its name" do
      plain_locate = locate.map { |line| line.sub(' (84081)', '') }
      receive_from_server(*kweld_arrival)
      kweld_rows = room_rows

      receive_from_server(*plain_locate)

      expect(room_rows).to eq kweld_rows
      expect(texts_on('familiar').first).to eq '[Willow Walk, Willow Tree]'
    end

    it "takes a view without the game's room id of a room named like the player's as the player's room" do
      same_name_locate = locate.map { |line| line.sub('[Willow Walk, Willow Tree] (84081)', "[Kweld Andu, Pathway's End]") }
      receive_from_server(*kweld_arrival, *same_name_locate)

      expect(texts_on('familiar')).to be_empty
      expect(room_rows.first).to eq "[Kweld Andu, Pathway's End]"
    end

    it "takes a room that comes with a nav tag but no subtitle as the player's room" do
      plain_locate = locate.map { |line| line.sub(' (84081)', '') }
      receive_from_server(*kweld_arrival, 'You go east.', "<nav rm='84081'/>", *plain_locate.drop(1))

      expect(texts_on('familiar')).to be_empty
      expect(room_rows.first).to eq '[Willow Walk, Willow Tree]'
    end

    it 'takes a view before any nav tag or subtitle as the player\'s room' do
      receive_from_server(*locate)

      expect(texts_on('familiar')).to be_empty
      expect(room_rows.first).to eq '[Willow Walk, Willow Tree] (84081)'
    end
  end

  # Lich's ;display uid with ;display roomid title (Fidon's settings)
  # rewrites every roomName before the front-end gets it (lich-5 games.rb,
  # DragonRealms#modify_room_display): it drops the game's " (NNN)" and
  # adds " - <Lich id> - (u<nav id>)" inside the brackets, the ids of the
  # room the player is in (Map.current, XMLData.room_id), whatever room
  # the line names. The room subtitle reaches Profanity as the game sent
  # it. Fidon's log of 13:38 (dr_locate_after_move.xml): north to the
  # Hermit's Shacks, south to the Burial Ground, then a Locate of Ytterby,
  # in the Hermit's Shacks.
  context "when Lich's ;display uid rewrites the roomName" do
    before { load_layout(main_window, room_window, familiar_window) }

    # The Lich ids of the two rooms: the Burial Ground's is in the process
    # title of Fidon's client (2026-10-07 13:56), the Hermit's Shacks' made up
    let(:lich_ids) { { '230008' => '7380', '230007' => '2072' } }

    # The fixture's lines as Lich sends them on with those settings
    def lich_rewritten(lines, nav: nil)
      lines.map do |line|
        nav = line[/<nav rm='(\d+)'/, 1] || nav
        next line unless line.include?('<style id="roomName" />')

        line.sub(/\] \((?:\d+|\*\*)\)/, ']').sub(']') { " - #{lich_ids.fetch(nav)} - (u#{nav})]" }
      end
    end

    def after_move = lich_rewritten(File.readlines(
                                      File.expand_path('../fixtures/room_pipeline/dr_locate_after_move.xml', __dir__), chomp: true
                                    ))

    it 'shows the Locate view in the familiar window, though Lich gave it the ids of the room the player is in' do
      receive_from_server(*after_move)

      expect(room_rows.first).to eq '[Bosque Deriel, Burial Ground - 2072 - (u230007)]'
      expect(room_rows.last).to eq 'Obvious paths: north, southeast.'
      expect(texts_on('familiar')).to match [
        "[Bosque Deriel, Hermit's Shacks - 2072 - (u230007)]",
        a_string_starting_with('Here on the route between the sacred sites of the Observatory'),
        "Also here: Exsanguinator Nelis, Death's Messenger Gnarta, Quilsilgas and Druid Ytterby.",
        'Obvious paths: north, south.'
      ]
      expect(state.room_title).to eq 'Bosque Deriel, Burial Ground - 2072 - (u230007)'
    end

    it "takes a LOOK in the player's room, Lich's ids in its name, as the player's room" do
      look = lich_rewritten(["<nav rm='230007'/>",
                             '<resource picture="0"/><style id="roomName" />[Bosque Deriel, Burial Ground] (230007)',
                             %(<style id=""/><preset id='roomDesc'>You come upon an Elven burial ground.</preset>),
                             'Obvious paths: <d>north</d>, <d>southeast</d>.',
                             '<prompt time="1791333520">&gt;</prompt>'])
      receive_from_server(*after_move)
      shown.clear

      receive_from_server(*look.drop(1))

      expect(texts_on('familiar')).to be_empty
      expect(room_rows.first).to eq '[Bosque Deriel, Burial Ground - 2072 - (u230007)]'
      expect(room_rows).to include('You come upon an Elven burial ground.')
    end

    # Fidon's client started at 13:56:43, after the last move, and Lich sends
    # it no nav tag or subtitle until the next one: its first prompt sends a
    # LOOK (PromptTracker), and the Locate comes after that
    # (dr_locate_after_restart.xml, the log of 13:56 from the client's start;
    # its roomName as the process title showed it).
    def after_restart = lich_rewritten(File.readlines(
                                         File.expand_path('../fixtures/room_pipeline/dr_locate_after_restart.xml', __dir__), chomp: true
                                       ), nav: '230007')

    it 'shows a Locate view in the familiar window before the first move, from the LOOK sent at the first prompt' do
      receive_from_server(*after_restart)

      expect(room_rows.first).to eq '[Bosque Deriel, Burial Ground - 2072 - (u230007)]'
      expect(room_rows.last).to eq 'Obvious paths: north, southeast.'
      expect(texts_on('familiar').first).to eq "[Bosque Deriel, Hermit's Shacks - 2072 - (u230007)]"
      expect(texts_on('familiar').last).to eq 'Obvious paths: north, south.'
      expect(state.room_title).to eq 'Bosque Deriel, Burial Ground - 2072 - (u230007)'
    end

    it "leaves a view before that LOOK's to the room window" do
      locate_first = after_restart.drop(after_restart.index { |line| line.include?('You gesture.') })
      receive_from_server(*locate_first)

      expect(texts_on('familiar')).to be_empty
      expect(room_rows.first).to eq "[Bosque Deriel, Hermit's Shacks - 2072 - (u230007)]"
    end
  end

  context 'without a familiar window' do
    before { load_layout(main_window, room_window) }

    it 'shows the view in main, and leaves the room window alone' do
      receive_from_server(*kweld_arrival)
      kweld_rows = room_rows
      shown.clear

      receive_from_server(*locate)

      expect(room_rows).to eq kweld_rows
      expect(texts_on('main')).to eq ['You gesture.', *remote_lines]
    end
  end

  context 'without a room window' do
    before { load_layout(main_window, familiar_window) }

    it 'shows the view in the familiar window, and leaves the terminal title and players indicator alone' do
      receive_from_server(*kweld_arrival)
      indicator_labels.clear
      shown.clear

      receive_from_server(*locate)

      # Without a room window nothing splits the description from the
      # "You also see" after it: the line shows as DR sends it.
      desc_line = "#{remote_lines[1]}  #{remote_lines[2]}"
      expect(texts_on('familiar')).to eq [remote_lines[0], desc_line, *remote_lines.drop(3)]
      expect(texts_on('main')).to eq ['You gesture.']
      expect(state.room_title).to eq "Kweld Andu, Pathway's End (1225103)"
      expect(indicator_labels).to be_empty
    end
  end
end
