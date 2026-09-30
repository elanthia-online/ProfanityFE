# frozen_string_literal: true

# Where the room window shows the lines Lich adds after a room ("Room
# Exits:" with links, "Room Number:", "StringProcs:") when the room is
# longer than the window, or fits it, and what a click on Lich's exits
# sends. The game's exits and Lich's stay on screen: the sections below
# them are cut first, then the rows above them.
#
# These examples drove RoomWindow with raw Lich markup; they now go
# through the real server loop (GameTextProcessor#run) into a room window
# built from layout XML, 20 columns wide, and read its rows and
# RoomWindow#link_cmd_at.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe "Lich's room lines in the room window" do
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  # Color pair number of the color links are drawn in without a 'links'
  # preset.
  let(:pairs) { { LinkExtractor::DEFAULT_LINK_COLOR[0] => 1 } }

  before do
    allow(IO).to receive(:select).and_return(nil)
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    state.blue_links = true
  end

  # Build a room window +height+ rows high and 20 columns wide, and a
  # processor that feeds it.
  def load_layout(height)
    LAYOUT['lich-exits'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='10' width='80' value='main'/>
        <window class='room' top='10' left='0' height='#{height}' width='20' value='room'/>
      </layout>
    XML
    event_bus = EventBus.new
    @window_manager = WindowManager.new(shared_state: state)
    @window_manager.load_layout('lich-exits')
    @window_manager.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @window_manager, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
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

  def room = @window_manager.room['room']

  # What clicking each column of row +y+ would send.
  def clicks_on_row(y)
    (0...20).map { |x| room.link_cmd_at(y, x) }
  end

  # The room's description and exits components, then Lich's lines.
  def room_with_lich_lines(desc, *lich_lines)
    ["<component id='room desc'>#{desc}</component>",
     "<component id='room exits'>Go: <d>north</d>.<compass></compass></component>",
     *lich_lines]
  end

  # Description 3 rows, exits 1, Lich's exits 1, room number 1 and
  # stringprocs 1, in a window 4 rows high.
  context 'when the room is longer than the window' do
    before do
      load_layout(4)
      receive_from_server(*room_with_lich_lines('abcdefghijklmnopqrs tuvwxyzabcdefghijkl e', 'Room Number: 12',
                                                "Room Exits: <d cmd='go gate'>gate</d>", 'StringProcs: proc'))
    end

    it 'shows the game exits, then Lich exits, on the bottom rows, and cuts the sections below them' do
      expect(room.rows.map(&:rstrip)).to eq ['abcdefghijklmnopqrs', 'tuvwxyzabcdefghijkl', 'Go: north.', 'Room Exits: gate']
    end

    it 'sends the links of both exits where they are shown' do
      expect(clicks_on_row(2)).to eq [nil] * 4 + ['north'] * 5 + [nil] * 11
      expect(clicks_on_row(3)).to eq [nil] * 12 + ['go gate'] * 4 + [nil] * 4
    end
  end

  # Description 2 rows, exits 1, Lich's exits 1 and room number 1.
  it 'shows every section in order when the room fits the window' do
    load_layout(5)

    receive_from_server(*room_with_lich_lines('abcdefghijklmnopqrs tuv', 'Room Number: 12',
                                              "Room Exits: <d cmd='go gate'>gate</d>"))

    expect(room.rows.map(&:rstrip)).to eq ['abcdefghijklmnopqrs', 'tuv', 'Go: north.', 'Room Exits: gate', 'Room Number: 12']
  end
end
