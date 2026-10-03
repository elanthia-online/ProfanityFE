# frozen_string_literal: true

# The room description reaches the room window two ways: the 'room desc'
# component, sent with every room change, and a roomDesc preset or style
# on the inline lines after the roomName, which DR leaves out when room
# descriptions are off (FLAG DESCRIPTION OFF: brief mode, and a LOOK in
# it). The room window follows that setting, as it did before #194: an
# inline view (roomName to "Obvious paths/exits:") without a roomDesc
# clears the description, on a move (though the component of the same
# burst sent one) and in place; one with a roomDesc shows the
# description. A burst whose components come without an inline view keeps
# the component's description. The lines are real DR lines (spec/fixtures/
# room_pipeline: Mahtra's and Quilsilgas's logs of 2026-10-03; inline
# Gnarta's and Catheroine's, long descriptions shortened), driven through
# the real server loop into windows built from layout XML.

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
        <window class='room' top='6' left='0' height='30' width='80' value='room'/>
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

  # The lines of a fixture in spec/fixtures/room_pipeline.
  def fixture(name)
    File.readlines(File.expand_path("../fixtures/room_pipeline/#{name}.xml", __dir__), chomp: true)
  end

  def room_rows = @wm.room['room'].rows.map(&:rstrip).reject(&:empty?)

  # Mahtra's log: a move into the Ice Grottos with descriptions on, then
  # FLAG DESCRIPTION OFF and ON in place, each followed by the room's
  # inline view (DR sends no components with it).
  let(:grotto_title) { "[Jeol'gelvmoraen, Ice Grottos] (4217406)" }
  let(:grotto_desc_rows) do
    ['The expansive pale blue passage of glittering ice seems to stretch on forever,',
     'as if viewed from within the heart of a faceted diamond.  Like the inner fire',
     'of a gem, a luster refracts from the polished surface of the ice, bathing the',
     'area in a shifting hue of color.  Small bits of fabric, bone, and frost-covered',
     'wood fill the deep crevices of ice that wind around the cavern, the sign',
     'someone or something inhabits this seemingly barren cavern.']
  end
  let(:grotto_exits) { 'Obvious exits: northeast, east, southeast.' }

  context 'with room descriptions on' do
    it 'shows the description on a move' do
      receive_from_server(*fixture('dr_desc_on_move'))

      expect(room_rows).to eq [
        grotto_title, *grotto_desc_rows,
        'You also see a large pewter bar, a plague spawn, a pair of copper cufflinks,',
        "some ju'ladan oil, a cobalt-blue muslin gamantang, a jeol moradu (immobile), a",
        'jeol moradu, a jeol moradu (dead), a jeol moradu, a jeol moradu, a jeol moradu,',
        'a jeol moradu and some junk.',
        'Also here: Master of Shadows Barrask and Shadow Priest Promithius.',
        grotto_exits
      ]
    end

    it 'shows it again in place when they are turned back on' do
      receive_from_server(*fixture('dr_desc_on_move'), *fixture('dr_desc_off_look'), *fixture('dr_desc_on_look'))

      expect(room_rows).to start_with(grotto_title, *grotto_desc_rows)
      expect(room_rows).to end_with(grotto_exits)
    end
  end

  context 'with room descriptions off' do
    it 'clears the description in place when they are turned off after a move' do
      receive_from_server(*fixture('dr_desc_on_move'), *fixture('dr_desc_off_look'))

      expect(room_rows).to eq [
        grotto_title,
        'You also see a large pewter bar, a plague spawn, a pair of copper cufflinks,',
        "some ju'ladan oil, a cobalt-blue muslin gamantang, a jeol moradu (immobile), a",
        'jeol moradu, a jeol moradu, a jeol moradu, a jeol moradu, a jeol moradu and',
        'some junk.',
        'Also here: Master of Shadows Barrask and Shadow Priest Promithius.',
        grotto_exits
      ]
    end

    it 'clears it again when they are turned off a second time' do
      receive_from_server(*fixture('dr_desc_on_move'), *fixture('dr_desc_off_look'), *fixture('dr_desc_on_look'),
                          *fixture('dr_desc_off_look'))

      expect(room_rows).to eq [
        grotto_title,
        'You also see a large pewter bar, a plague spawn, a pair of copper cufflinks,',
        "some ju'ladan oil, a cobalt-blue muslin gamantang, a jeol moradu (immobile), a",
        'jeol moradu, a jeol moradu, a jeol moradu, a jeol moradu, a jeol moradu and',
        'some junk.',
        'Also here: Master of Shadows Barrask and Shadow Priest Promithius.',
        grotto_exits
      ]
    end

    # Quilsilgas's log: on every move DR sends the room desc component with
    # the description, and the inline view without one.
    it "shows no description after a brief-mode move, though the move's desc component sent one" do
      moves = fixture('dr_brief_moves')
      first_move = moves.take(moves.index('You go north.'))

      receive_from_server(*first_move)
      expect(room_rows).to eq ['[Bosque Deriel, Burial Ground] (230007)', 'Obvious paths: north, southeast.']

      receive_from_server(*moves.drop(first_move.size))
      expect(room_rows).to eq ["[Bosque Deriel, Hermit's Shacks] (230008)", 'Also here: Holdigor and Druid Ytterby.',
                               'Obvious paths: north, south.']
    end

    it 'clears a description shown with descriptions on at the next brief-mode move' do
      receive_from_server(*fixture('dr_desc_on_move'), *fixture('dr_brief_moves'))

      expect(room_rows).to eq ["[Bosque Deriel, Hermit's Shacks] (230008)", 'Also here: Holdigor and Druid Ytterby.',
                               'Obvious paths: north, south.']
    end
  end

  # The same move's components, with the inline lines left out (a layout or
  # game that sends none): no inline view decides the description.
  context 'when a burst has room components but no inline view' do
    it "keeps the component's description" do
      receive_from_server(*fixture('dr_brief_moves'), *fixture('dr_components_without_inline'))

      expect(room_rows).to eq [
        '[Bosque Deriel, Burial Ground] (230007)',
        'You come upon an Elven burial ground in the shade of sacred groves.  The graves',
        'are almost impossible to distinguish from the surrounding forest growth, save',
        'for a slight elevation, greener cover, and saplings planted at their heads to',
        'commemorate the departed soul.  The forest nomads also come here, and leave',
        'their dead in the trees, to be stripped by scavenger birds.',
        'Obvious paths: north, southeast.'
      ]
    end
  end

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
  # LOOK in it): the roomName, then the line the style closes on.
  def brief_inline(name, after_style, exits)
    ["<resource picture=\"0\"/><style id=\"roomName\" />#{name}", "<style id=\"\"/>#{after_style}", exits,
     '<prompt time="1787783856">&gt;</prompt>']
  end

  # The inline lines of a room with a description.
  def full_inline(name, desc, exits)
    ["<resource picture=\"0\"/><style id=\"roomName\" />#{name}", "<style id=\"\"/><preset id='roomDesc'>#{desc}</preset>  ",
     exits, '<prompt time="1787783856">&gt;</prompt>']
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
  # A move into the room with descriptions on
  let(:edge_room) { room_components(edge_name, edge_desc, edge_exits) + full_inline(edge_name, edge_desc, edge_exits) }

  let(:rest_name) { "[Fayrin's Rest, Telgi Mod'Sunhin] (2105206)" }
  let(:rest_exits) { 'Obvious paths: <d>northeast</d>, <d>west</d>.' }

  context 'when a brief-mode view has another shape' do
    it 'clears the description when the style closes on the "You also see" line' do
      name = "[Fayrin's Rest, Anloraten Crossing] (2105202)"
      desc = 'It is not much of a meeting place for roads and their travelers: a broad lane wandering through ' \
             'an impressive forest.'
      exits = 'Obvious paths: <d>north</d>, <d>east</d>, <d>southeast</d>, <d>southwest</d>.'
      objs = 'You also see a signpost and a wooden bench.'

      receive_from_server(*room_components(name, desc, exits, objs: objs), *brief_inline(name, "  #{objs}", exits))

      expect(room_rows).to eq [
        "[Fayrin's Rest, Anloraten Crossing] (2105202)",
        'You also see a signpost and a wooden bench.',
        'Obvious paths: north, east, southeast, southwest.'
      ]
    end

    it "drops the old room's description for a room whose desc component is empty" do
      receive_from_server(*edge_room, 'You run southwest.',
                          *room_components(rest_name, '', rest_exits), *brief_inline(rest_name, '  ', rest_exits))

      expect(room_rows).to eq [rest_name, 'Obvious paths: northeast, west.']
    end

    it "drops the old room's description for a room that arrives without components" do
      receive_from_server(*edge_room, 'You run southwest.', *brief_inline(rest_name, '  ', rest_exits))

      expect(room_rows).to eq [rest_name, 'Obvious paths: northeast, west.']
    end
  end

  # A view without a roomDesc that clears the description a component
  # delivered leaves the component owning nothing, so a later view's
  # roomDesc shows. Neither case is in the logs.
  context 'when a view clears the description a component delivered' do
    # Two views with no prompt between
    it 'shows the description of a later view in the burst with a roomDesc' do
      receive_from_server(*room_components(edge_name, edge_desc, edge_exits),
                          *brief_inline(edge_name, '  ', edge_exits).take(3),
                          *full_inline(edge_name, edge_desc, edge_exits))

      expect(room_rows).to eq edge_rows
    end

    # A prompt and a room desc component before the clearing view's exits
    # text, on its line (DR sends no such line): the component belongs to
    # the next burst, and the view clears what it showed, so the next
    # burst doesn't own it either and a LOOK shows its own description.
    it 'shows a LOOK description after a view cleared one delivered after the prompt on its line' do
      cleared = brief_inline(edge_name, '  ', edge_exits).take(3)
      cleared[-1] = "<prompt time=\"1787783856\">&gt;</prompt><component id='room desc'>Another description.</component>" \
                    "#{cleared[-1]}"

      receive_from_server(*room_components(edge_name, edge_desc, edge_exits), *cleared,
                          *full_inline(edge_name, edge_desc, edge_exits))

      expect(room_rows).to eq edge_rows
    end
  end

  context 'when the inline lines carry a description that differs from the component' do
    let(:inline_desc) { 'In the darkness, the forms of ancient trees appear to coalesce into a single malevolent entity.' }
    let(:inline_desc_rows) do
      [edge_name,
       'In the darkness, the forms of ancient trees appear to coalesce into a single',
       'malevolent entity.',
       'Obvious paths: southwest.']
    end

    it "keeps the component's description when the inline one comes in the same burst" do
      receive_from_server(*room_components(edge_name, edge_desc, edge_exits), *full_inline(edge_name, inline_desc, edge_exits))

      expect(room_rows).to eq edge_rows
    end

    it 'shows the inline description of a LOOK after the prompt' do
      receive_from_server(*edge_room, *full_inline(edge_name, inline_desc, edge_exits))

      expect(room_rows).to eq inline_desc_rows
    end
  end
end
