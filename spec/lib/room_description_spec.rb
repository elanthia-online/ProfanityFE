# frozen_string_literal: true

# The room description reaches the room window two ways: the 'room desc'
# component, sent with every room change, and a roomDesc preset or style
# on the inline lines after the roomName, which DR leaves out when room
# descriptions are off (brief mode) and on a brief LOOK. The inline lines
# must not wipe the description the component delivered for the same
# room, and a new room must not keep the old room's. The lines are real DR
# lines (Gnarta's and Catheroine's logs, long descriptions shortened),
# driven through the real server loop into windows built from layout XML.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Room description' do
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }

  before do
    allow(IO).to receive(:select).and_return(nil)
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='6' width='80' value='main'/>
        <window class='room' top='6' left='0' height='12' width='80' value='room'/>
      </layout>
    XML
    @wm = WindowManager.new
    @wm.load_layout('test')
    @wm.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    @processor.run(server)
  end

  def room_rows = @wm.room['room'].rows.map(&:rstrip).reject(&:empty?)

  # The component block DR sends on arriving in a room: +desc+ and +objs+
  # are the component texts ('' for an empty component).
  def room_components(subtitle, desc, exits, objs: '')
    [
      "<streamWindow id='room' title='Room' subtitle=\" - #{subtitle}\" location='center' target='drop' ifClosed='' resident='true'/>",
      "<component id='room desc'>#{desc}</component>",
      "<component id='room objs'>#{objs}</component>",
      "<component id='room players'></component>",
      "<component id='room exits'>#{exits}<compass></compass></component>",
      "<component id='room extra'></component>"
    ]
  end

  # The inline lines of a room without a description (brief mode, or a
  # brief LOOK): the roomName, then the line the style closes on.
  def brief_inline(name, after_style, exits)
    ["<resource picture=\"0\"/><style id=\"roomName\" />#{name}", "<style id=\"\"/>#{after_style}", exits,
     '<prompt time="1787783856">&gt;</prompt>']
  end

  let(:edge_name) { "[The Edge of the Forest, Before the Dragon's Breath] (2030003)" }
  let(:edge_desc) do
    'The lushness of the forest begins to form a living wall, the leaves of the towering trees tinted with ' \
      'the dark hue of brightly-polished scales.  The path to the north dwindles into the more sinister area ' \
      'of the harsh mountains.'
  end
  let(:edge_exits) { 'Obvious paths: <d>southwest</d>.' }
  let(:edge_rows) do
    ["[The Edge of the Forest, Before the Dragon's Breath] (2030003)",
     'The lushness of the forest begins to form a living wall, the leaves of the',
     'towering trees tinted with the dark hue of brightly-polished scales.  The path',
     'to the north dwindles into the more sinister area of the harsh mountains.',
     'Obvious paths: southwest.']
  end
  let(:edge_room) { room_components(edge_name, edge_desc, edge_exits) + brief_inline(edge_name, '  ', edge_exits) }

  let(:rest_name) { "[Fayrin's Rest, Telgi Mod'Sunhin] (2105206)" }
  let(:rest_exits) { 'Obvious paths: <d>northeast</d>, <d>west</d>.' }

  context 'when the inline lines carry no description' do
    it 'keeps the component description when the roomName is followed by a blank style line' do
      receive_from_server(*edge_room)

      expect(room_rows).to eq edge_rows
    end

    it 'keeps it when the style closes on the "You also see" line' do
      name = "[Fayrin's Rest, Anloraten Crossing] (2105202)"
      desc = 'It is not much of a meeting place for roads and their travelers: a broad lane wandering through ' \
             'an impressive forest.'
      exits = 'Obvious paths: <d>north</d>, <d>east</d>, <d>southeast</d>, <d>southwest</d>.'
      objs = 'You also see a signpost and a wooden bench.'

      receive_from_server(*room_components(name, desc, exits, objs: objs), *brief_inline(name, "  #{objs}", exits))

      expect(room_rows).to eq [
        "[Fayrin's Rest, Anloraten Crossing] (2105202)",
        'It is not much of a meeting place for roads and their travelers: a broad lane',
        'wandering through an impressive forest.',
        'You also see a signpost and a wooden bench.',
        'Obvious paths: north, east, southeast, southwest.'
      ]
    end

    it 'keeps it on a brief LOOK in the same room, which sends no components' do
      receive_from_server(*edge_room, 'You will no longer see room descriptions.', *brief_inline(edge_name, '  ', edge_exits))

      expect(room_rows).to eq edge_rows
    end

    it 'shows the next room\'s description after a move' do
      rest_desc = 'The forest is shady here, beneath towering oaks that spread their branches.'

      receive_from_server(*edge_room, 'You run southwest.', "<nav rm='2105206'/>",
                          *room_components(rest_name, rest_desc, rest_exits), *brief_inline(rest_name, '  ', rest_exits))

      expect(room_rows).to eq [rest_name, rest_desc, 'Obvious paths: northeast, west.']
    end
  end

  context 'when the room changes' do
    it 'drops the old description for a room whose desc component is empty' do
      receive_from_server(*edge_room, 'You run southwest.', "<nav rm='2105206'/>",
                          *room_components(rest_name, '', rest_exits), *brief_inline(rest_name, '  ', rest_exits))

      expect(room_rows).to eq [rest_name, 'Obvious paths: northeast, west.']
    end

    it 'drops the old description for a room that arrives without components' do
      receive_from_server(*edge_room, 'You run southwest.', *brief_inline(rest_name, '  ', rest_exits))

      expect(room_rows).to eq [rest_name, 'Obvious paths: northeast, west.']
    end
  end

  it 'shows an inline roomDesc in place of the component description' do
    inline_desc = 'In the darkness, the forms of ancient trees appear to coalesce into a single malevolent entity.'

    receive_from_server(*room_components(edge_name, edge_desc, edge_exits),
                        "<resource picture=\"0\"/><style id=\"roomName\" />#{edge_name}",
                        "<style id=\"\"/><preset id='roomDesc'>#{inline_desc}</preset>  ", edge_exits)

    expect(room_rows).to eq [
      edge_name,
      'In the darkness, the forms of ancient trees appear to coalesce into a single',
      'malevolent entity.',
      'Obvious paths: southwest.'
    ]
  end
end
