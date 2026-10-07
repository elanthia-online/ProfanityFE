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

    # Without room ids nothing tells a view of another room from a LOOK:
    # it is read as the player's room, as before.
    it "takes a view without the game's room id as the player's room" do
      plain_locate = locate.map { |line| line.sub(' (84081)', '') }
      receive_from_server(*kweld_arrival, *plain_locate)

      expect(texts_on('familiar')).to be_empty
      expect(room_rows.first).to eq '[Willow Walk, Willow Tree]'
    end

    it 'takes a view before any nav tag as the player\'s room' do
      receive_from_server(*locate)

      expect(texts_on('familiar')).to be_empty
      expect(room_rows.first).to eq '[Willow Walk, Willow Tree] (84081)'
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
