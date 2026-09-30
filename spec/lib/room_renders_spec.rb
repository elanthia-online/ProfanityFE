# frozen_string_literal: true

# How often the room window is drawn while a room arrives, and what the
# screen shows at each flush.
#
# The room parts only change what the window holds; the window is drawn
# once at the flush that follows them (ServerReader#flush_if_idle). Lines
# already waiting when a line is done are part of the same burst, so a
# whole room that arrives at once is drawn once; lines that arrive apart
# are each drawn at their own flush, as before.
#
# Lines are fed through the real server loop (GameTextProcessor#run) into
# windows built from layout XML. A draw of the room window is counted from
# the virtual screen's call log: every draw clears the window first.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Room window renders' do
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:event_bus) { EventBus.new }
  let(:window_manager) do
    LAYOUT['room-renders'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='10' width='80' value='main'/>
        <window class='room' top='10' left='0' height='8' width='80'/>
      </layout>
    XML
    WindowManager.new(shared_state: state).tap do |wm|
      wm.load_layout('room-renders')
      wm.subscribe_to_events(event_bus)
    end
  end
  let(:room) { window_manager.room['room'] }
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: window_manager, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end
  # The room window's rows at every flush to the terminal.
  let(:shown) { [] }

  before do
    allow(Curses).to receive(:doupdate).and_wrap_original do |original|
      shown << room.rows.reject(&:empty?)
      original.call
    end
  end

  # A DragonRealms move as the game sends it (from a real session, the
  # description shortened): the room components, then the same room as
  # plain lines, then the prompt.
  let(:room_change) do
    [
      %(<streamWindow id='room' title='Room' subtitle=" - [Seord Kerwaith, Mountainside] (4217140)" ) +
        %(location='center' target='drop' ifClosed='' resident='true'/>),
      "<component id='room desc'>Night covers the narrow gorge.</component>",
      "<component id='room objs'></component>",
      "<component id='room players'></component>",
      "<component id='room exits'>Obvious paths: <d>northeast</d>, <d>southwest</d>.<compass></compass></component>",
      "<component id='room extra'></component>",
      '<resource picture="0"/><style id="roomName" />[Seord Kerwaith, Mountainside] (4217140)',
      '<style id=""/>  ',
      'Obvious paths: <d>northeast</d>, <d>southwest</d>.',
      %(<compass><dir value="ne"/><dir value="sw"/></compass><component id='room players'></component>),
      '<prompt time="1787793483">&gt;</prompt>'
    ]
  end
  let(:room_rows) do
    ['[Seord Kerwaith, Mountainside] (4217140)', 'Night covers the narrow gorge.',
     'Obvious paths: northeast, southwest.']
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would (Lich ends every line with CRLF). With +burst+, every line but
  # the last is followed by one already waiting, so the screen is flushed
  # only after the last; otherwise nothing is waiting after any line.
  def receive_from_server(*lines, burst:)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    # The first prompt sends a LOOK
    server.define_singleton_method(:puts) { |*| nil }
    server.define_singleton_method(:flush) { nil }
    allow(IO).to receive(:select) { burst && !queue.empty? ? [[server], [], []] : nil }
    processor.run(server)
  end

  # How many times the room window has been drawn so far.
  def room_draws
    room.call_log.count { |meth, _| meth == :erase }
  end

  it 'draws a room that arrives in one burst once, whole, at the flush after it' do
    before = room_draws

    receive_from_server(*room_change, burst: true)

    expect(room_draws - before).to eq 1
    expect(shown).to eq [room_rows]
  end

  it "draws Lich's room lines, sent with the prompt in one write, once" do
    receive_from_server(*room_change, burst: true)
    before = room_draws

    receive_from_server('Room Number: 1234 - (u230008)', 'Room Exits: go gate', 'StringProcs: go path',
                        '<prompt time="1787793484">&gt;</prompt>', burst: true)

    expect(room_draws - before).to eq 1
    expect(shown.last).to eq room_rows + ['Room Exits: go gate', 'Room Number: 1234 - (u230008)', 'StringProcs: go path']
  end

  it 'draws a room that arrives line by line at each flush that changes it, and not for the room extra' do
    before = room_draws

    receive_from_server(*room_change, burst: false)

    # A flush after every line that changed something (not the roomName
    # line or the line closing its style): the room grows part by part as
    # before
    expect(shown).to eq [
      room_rows.first(1),
      room_rows.first(2),
      room_rows.first(2),
      room_rows.first(2),
      room_rows,
      room_rows,
      room_rows,
      room_rows,
      room_rows
    ]
    # Drawn for the subtitle, the desc, objs, players and exits
    # components, and for the plain exits line and the players component
    # after it: not for the room extra component
    expect(room_draws - before).to eq 7
  end
end
