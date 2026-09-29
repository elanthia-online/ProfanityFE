# frozen_string_literal: true

# The inline room lines ("You also see", "Also here:", "Obvious paths:")
# are room data only when the game sends them to main. The same words on
# another stream (a familiar's view, a script's window) are that stream's
# text. The lines are driven through the real server loop into windows
# built from layout XML.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Inline room lines on other streams' do
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }

  before do
    GagPatterns.load_defaults
    allow(IO).to receive(:select).and_return(nil)
  end

  # Build the windows from layout XML and a processor that feeds them.
  #
  # @param room_window [Boolean] whether the layout has a room window
  def load_layout(room_window: true)
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='6' width='60' value='main'/>
        <window class='text' top='6' left='0' height='4' width='60' value='familiar'/>
        #{"<window class='room' top='10' left='0' height='6' width='60' value='room'/>" if room_window}
        <window class='indicator' top='16' left='0' height='1' width='40' value='room players'/>
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

  def main_rows = @wm.stream['main'].rows.reject(&:empty?)
  def familiar_rows = @wm.stream['familiar'].rows.reject(&:empty?)
  def room_rows = @wm.room['room'].rows.reject(&:empty?)
  def players_indicator = @wm.indicator['room players'].rows.first.rstrip

  # A room as DR sends it on main.
  def town_square
    ['<style id="roomName" />[Town Square] (1)', '<style id=""/>You also see a bench.', 'Obvious paths: <d>north</d>.']
  end

  context 'with a room window' do
    before { load_layout }

    it 'leaves the room alone and shows the line in its window when a familiar sees exits' do
      receive_from_server(*town_square, '<pushStream id="familiar"/>Obvious paths: east, west.', '<popStream/>')

      expect(room_rows).to eq ['[Town Square] (1)', 'You also see a bench.', 'Obvious paths: north.']
      expect(familiar_rows).to eq ['Obvious paths: east, west.']
    end

    it 'keeps a familiar line in its window under --room-window-only' do
      state.room_window_only = true

      receive_from_server('<pushStream id="familiar"/>You also see a rat.', '<popStream/>')

      expect(familiar_rows).to eq ['You also see a rat.']
    end

    it 'still reads the room from lines on main' do
      receive_from_server(*town_square)

      expect(room_rows).to eq ['[Town Square] (1)', 'You also see a bench.', 'Obvious paths: north.']
    end
  end

  context 'without a room window' do
    before { load_layout(room_window: false) }

    it 'does not take a familiar "Also here:" line as the room players' do
      shown = players_indicator

      receive_from_server('<pushStream id="familiar"/>Also here: Bob.', '<popStream/>')

      expect(players_indicator).to eq shown
      expect(familiar_rows).to eq ['Also here: Bob.']
    end

    it 'takes an "Also here:" line pushed to the main stream as the room players' do
      receive_from_server('<pushStream id="main"/>Also here: Bob.', '<popStream/>')

      expect(players_indicator).to eq 'Bob'
    end
  end
end
