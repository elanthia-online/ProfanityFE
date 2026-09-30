# frozen_string_literal: true

# Tests that a burst of server lines whose last line is dropped (a gagged
# line, or the second of two blank lines) still reaches the terminal: the
# lines before it are flushed once no more server data is waiting, not
# left staged until the next server line.
#
# The real server loop reads a real socket pair, so IO.select sees what is
# actually waiting.

require_relative '../spec_helper'
require 'rexml/document'
require 'socket'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

# Load the REAL GagPatterns module (replaces the spec_helper stub)
original_verbose = $VERBOSE
$VERBOSE = nil
load File.expand_path('../../lib/gag_patterns.rb', __dir__)
$VERBOSE = original_verbose

RSpec.describe 'A server burst that ends in a dropped line' do
  before { GagPatterns.load_defaults }
  after { GagPatterns.load_defaults }

  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:event_bus) { EventBus.new }
  let(:window_manager) do
    LAYOUT['dropped'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='10' width='80' value='main'/>
      </layout>
    XML
    WindowManager.new(shared_state: state).tap do |wm|
      wm.load_layout('dropped')
      wm.subscribe_to_events(event_bus)
    end
  end
  let(:main) { window_manager.stream['main'] }
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: window_manager, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end
  let(:sockets) { UNIXSocket.pair }
  let(:client_end) { sockets.first }
  let(:game_end) { sockets.last }
  # The main window's text lines at each flush to the terminal.
  let(:flushed_screens) { [] }
  let(:reader) { Thread.new { processor.run(client_end) } }

  before do
    GagPatterns.add_general_pattern('^Tenuk strikes his heel against the ground')
    allow(Curses).to receive(:doupdate).and_wrap_original do |original|
      flushed_screens << main.rows.map(&:rstrip).reject(&:empty?)
      original.call
    end
    reader
  end

  after do
    game_end.close unless game_end.closed?
    reader.join(3) || reader.kill
    client_end.close unless client_end.closed?
  end

  # Send +data+ in one write, as one packet from the game.
  def game_sends(data)
    game_end.write(data)
  end

  # Wait (at most 3 s) until the terminal has been flushed +count+ times.
  def wait_for_flushes(count)
    deadline = Time.now + 3
    sleep 0.01 until flushed_screens.size >= count || Time.now > deadline
  end

  # End the connection and wait for the server loop to finish reading.
  def game_disconnects
    game_end.close
    reader.join(3)
  end

  it 'flushes a line whose burst ends in a gagged line' do
    game_sends("You notice a goblin lurking in the shadows.\r\nTenuk strikes his heel against the ground.\r\n")
    wait_for_flushes(1)
    game_disconnects

    expect(flushed_screens).to eq [['You notice a goblin lurking in the shadows.']]
  end

  it 'flushes a line whose burst ends in a second blank line' do
    game_sends("You notice a goblin lurking in the shadows.\r\n\r\n\r\n")
    wait_for_flushes(1)
    game_disconnects

    expect(flushed_screens).to eq [['You notice a goblin lurking in the shadows.']]
  end

  it 'flushes once, at the end, a burst with a gagged line in the middle' do
    game_sends("You notice a goblin lurking in the shadows.\r\nTenuk strikes his heel against the ground.\r\n" \
               "Ann smiles.\r\n")
    wait_for_flushes(1)
    game_disconnects

    expect(flushed_screens).to eq [['You notice a goblin lurking in the shadows.', 'Ann smiles.']]
  end

  it 'does not flush again for a gagged line after a flushed one' do
    game_sends("You notice a goblin lurking in the shadows.\r\n")
    wait_for_flushes(1)
    game_sends("Tenuk strikes his heel against the ground.\r\n")
    game_disconnects

    expect(flushed_screens).to eq [['You notice a goblin lurking in the shadows.']]
  end

  it 'flushes nothing for a dropped line with nothing staged' do
    game_sends("Tenuk strikes his heel against the ground.\r\n")
    game_disconnects

    expect(flushed_screens).to be_empty
  end
end
