# frozen_string_literal: true

# The room players indicator in a layout with no room window. DR sends the
# players twice per LOOK: inline on main ("Also here: ..." after the room
# description) and in a <component id='room players'> line. The lines are
# real ones from a DR log (2026-09-26).

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Room players indicator without a room window' do
  before { GagPatterns.load_defaults }

  let(:event_bus) { EventBus.new }
  let(:window_manager) do
    WindowManager.new.tap do |wm|
      LAYOUT['players'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='10' width='80' value='main'/>
          <window class='indicator' top='22' left='0' height='1' width='40' value='room players' fg='&grey;,&cyan;'/>
        </layout>
      XML
      wm.load_layout('players')
      wm.subscribe_to_events(event_bus)
    end
  end
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: window_manager,
      shared_state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end
  let(:indicator) { window_manager.indicator['room players'] }

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    allow(IO).to receive(:select).and_return(nil)
    allow(processor).to receive(:show_disconnect_message)
    allow(processor).to receive(:exit)
    processor.run(server)
  end

  # How many times the indicator was drawn since the log was last cleared.
  def indicator_draws
    indicator.call_log.count { |meth, _| meth == :clrtoeol }
  end

  it 'draws the indicator once for a room players component' do
    indicator.call_log.clear

    receive_from_server("<component id='room players'>Also here: Acolyte Tenuk and Death's Messenger Gnarta (hiding).</component>")

    expect([indicator.rows.first.rstrip, indicator_draws]).to eq ['Tenuk, Gnarta', 1]
  end

  it 'draws the indicator once per players line of a LOOK and shows the inline line in main once' do
    indicator.call_log.clear

    receive_from_server(
      '<style id="roomName" />[Himineldar Shel, Mountain Road] (4401502)',
      "<style id=\"\"/><preset id='roomDesc'>Night falls quickly upon the region.</preset>",
      'Also here: Vellenor who has a stony visage.',
      'Obvious paths: <d>southeast</d>, <d>northwest</d>.',
      "<compass><dir value=\"se\"/><dir value=\"nw\"/></compass><component id='room players'>Also here: Vellenor who has a stony visage.</component>"
    )

    main_rows = window_manager.stream['main'].rows.map(&:rstrip)
    expect([indicator.rows.first.rstrip, indicator_draws]).to eq ['Vellenor', 2]
    expect(main_rows.count('Also here: Vellenor who has a stony visage.')).to eq 1
  end
end
