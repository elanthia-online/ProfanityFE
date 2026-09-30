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
  # The room window's rows at every flush to the terminal: the server
  # loop's (Curses.doupdate) and the disconnect notice's
  # (CursesRenderer.render).
  let(:shown) { [] }

  before do
    allow(Curses).to receive(:doupdate).and_wrap_original do |original|
      shown << room.rows.reject(&:empty?)
      original.call
    end
    allow(CursesRenderer).to receive(:render).and_wrap_original do |original, &block|
      original.call(&block)
      shown << room.rows.reject(&:empty?)
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
  # only after the last; otherwise nothing is waiting after any line. With
  # +closed+, the server closes the connection after the last line: a
  # closed socket reads as ready, so the loop doesn't flush after it.
  def receive_from_server(*lines, burst:, closed: false)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    # The first prompt sends a LOOK
    server.define_singleton_method(:puts) { |*| nil }
    server.define_singleton_method(:flush) { nil }
    allow(IO).to receive(:select) { (burst && !queue.empty?) || (closed && queue.empty?) ? [[server], [], []] : nil }
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

  it "draws Lich's room lines once when sent with the prompt in one write, and at each flush when apart" do
    receive_from_server(*room_change, burst: true)
    before = room_draws

    receive_from_server('Room Number: 1234 - (u230008)', 'Room Exits: go gate', 'StringProcs: go path',
                        '<prompt time="1787793484">&gt;</prompt>', burst: true)

    expect(room_draws - before).to eq 1
    expect(shown.last).to eq room_rows + ['Room Exits: go gate', 'Room Number: 1234 - (u230008)', 'StringProcs: go path']

    shown.clear
    receive_from_server('Room Number: 5678 - (u230009)', 'Room Exits: climb wall', 'StringProcs: go door', burst: false)

    expect(shown).to eq [
      room_rows + ['Room Exits: go gate', 'Room Number: 5678 - (u230009)', 'StringProcs: go path'],
      room_rows + ['Room Exits: climb wall', 'Room Number: 5678 - (u230009)', 'StringProcs: go path'],
      room_rows + ['Room Exits: climb wall', 'Room Number: 5678 - (u230009)', 'StringProcs: go door']
    ]
  end

  # A room as plain lines only, as a LOOK or a move with room
  # descriptions off sends it: the room is drawn at the flush after its
  # exits line, which commits it. An exits line on its own changes only
  # the exits.
  it 'draws a room sent only as plain lines at the flush after its exits line, and a lone exits line too' do
    rows = ['[Crossing, Town Green] (1234)', 'Grass and a fountain.', 'You also see a goblin.']
    receive_from_server('<resource picture="0"/><style id="roomName" />[Crossing, Town Green] (1234)',
                        %(<style id=""/><preset id='roomDesc'>Grass and a fountain.</preset>  ) +
                          'You also see <pushBold/>a goblin<popBold/>.',
                        'Obvious exits: east, west.', burst: false)

    expect(shown.last).to eq rows + ['Obvious exits: east, west.']

    receive_from_server('Obvious exits: east, west, up.', burst: false)

    expect(shown.last).to eq rows + ['Obvious exits: east, west, up.']
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
    # components, and for the players component after the plain lines: not
    # for the room extra component, nor for the plain exits line, whose
    # commit sends nothing the components didn't already show
    expect(room_draws - before).to eq 6
  end

  # Lich's lines follow the room they were sent after: the next room's
  # commit (its plain exits line) clears them, and the window is drawn
  # without them at that line's flush, though the commit sends nothing
  # else. Characterization (passes on the base by design): before the
  # commit asked for a render only when it cleared Lich's lines, it always
  # asked.
  it "draws the window without the last room's Lich lines at the flush after the next room's exits line" do
    lich = ['Room Exits: go gate', 'Room Number: 1234 - (u230008)']
    receive_from_server(*room_change, lich.last, lich.first, '<prompt time="1787793484">&gt;</prompt>', burst: true)
    shown.clear

    receive_from_server(*room_change, burst: false)

    # A flush after every line up to the roomName line still shows them;
    # the plain exits line's flush and the next don't
    expect(shown).to eq Array.new(7, room_rows + lich) + Array.new(2, room_rows)
  end

  it "doesn't draw the window for the plain exits line of a room after the one whose Lich lines it cleared" do
    receive_from_server(*room_change, 'Room Exits: go gate', '<prompt time="1787793484">&gt;</prompt>', burst: true)
    receive_from_server(*room_change, burst: false)
    before = room_draws

    receive_from_server(*room_change, burst: false)

    # As for a room without Lich's lines (see above)
    expect(room_draws - before).to eq 6
  end

  # The flush that follows the last burst is the disconnect notice's: the
  # room is drawn there with every part that burst sent.
  describe 'when the server closes the connection right after a burst' do
    it "draws Lich's room lines on the disconnect notice's flush" do
      receive_from_server(*room_change, burst: true)

      receive_from_server('Room Number: 1234 - (u230008)', 'Room Exits: go gate',
                          '<prompt time="1787793484">&gt;</prompt>', burst: true, closed: true)
      processor.show_disconnect_message

      expect(shown.last).to eq room_rows + ['Room Exits: go gate', 'Room Number: 1234 - (u230008)']
    end

    it "draws a room component that came after the exits on the disconnect notice's flush" do
      receive_from_server(*room_change, burst: true)

      receive_from_server("<component id='room players'>Also here: Bob.</component>",
                          '<prompt time="1787793484">&gt;</prompt>', burst: true, closed: true)
      processor.show_disconnect_message

      expect(shown.last).to eq room_rows.first(2) + ['Also here: Bob.', room_rows.last]
    end
  end
end
