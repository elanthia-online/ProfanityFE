# frozen_string_literal: true

# Pins how roomName/roomDesc styled text is captured for the room window
# and the terminal title: which text a capture takes, and what still shows
# in main. Some of it is quirky (text before a roomName on the same line
# joins the title; a roomDesc preset flushes the text before it and a
# roomDesc style doesn't); these specs keep it as it is. The lines are
# driven through the real server loop into windows built from layout XML.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Room capture' do
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }

  before { allow(IO).to receive(:select).and_return(nil) }

  # Build the windows from layout XML and a processor that feeds them.
  #
  # @param room_window [Boolean] whether the layout has a room window
  def load_layout(room_window: true)
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='6' width='60' value='main'/>
        #{"<window class='room' top='6' left='0' height='6' width='60' value='room'/>" if room_window}
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
  def room_rows = @wm.room['room'].rows.reject(&:empty?)

  # The title doesn't start with its bracket, so RoomTitle takes all of it
  # as the room's name and brackets it.
  describe 'text before a roomName style on the same line' do
    let(:lines) { ['You arrive.<style id="roomName" />[Town Square]<style id=""/>', 'Obvious exits: north.'] }

    it 'joins the room title, and still shows in main' do
      load_layout

      receive_from_server(*lines)

      expect(room_rows).to eq ['[You arrive.[Town Square]]', 'Obvious exits: north.']
      expect(state.room_title).to eq 'You arrive.[Town Square]'
      expect(main_rows).to eq ['You arrive.[Town Square]', 'Obvious exits: north.']
    end

    it 'is dropped from main with the title under --room-window-only' do
      load_layout
      state.room_window_only = true

      receive_from_server(*lines)

      expect(room_rows.first).to eq '[You arrive.[Town Square]]'
      expect(main_rows).to be_empty
    end

    it 'joins the terminal title without a room window' do
      load_layout(room_window: false)

      receive_from_server(*lines)

      expect(state.room_title).to eq 'You arrive.[Town Square]'
      expect(main_rows).to eq ['You arrive.[Town Square]', 'Obvious exits: north.']
    end
  end

  describe 'text before a roomDesc on the same line' do
    let(:preset) { ["Before. <preset id='roomDesc'>A room.</preset>", 'Obvious paths: north.'] }
    let(:style) { ["Before. <style id='roomDesc'/>A room.<style id=''/>", 'Obvious paths: north.'] }

    context 'with a room window' do
      before { load_layout }

      it 'is flushed on its own by a roomDesc preset' do
        receive_from_server(*preset)

        expect(room_rows).to eq ['A room.', 'Obvious paths: north.']
        expect(main_rows).to eq ['Before.', 'A room.', 'Obvious paths: north.']
      end

      it 'is not flushed by a roomDesc style: it goes out with the description' do
        receive_from_server(*style)

        expect(room_rows).to eq ['A room.', 'Obvious paths: north.']
        expect(main_rows).to eq ['Before. A room.', 'Obvious paths: north.']
      end

      it 'stays in main after a roomDesc preset under --room-window-only' do
        state.room_window_only = true

        receive_from_server(*preset)

        expect(main_rows).to eq ['Before.']
      end

      it 'is dropped from main with a roomDesc style description under --room-window-only' do
        state.room_window_only = true

        receive_from_server(*style)

        expect(main_rows).to be_empty
      end
    end

    context 'without a room window' do
      before { load_layout(room_window: false) }

      it 'is not flushed by a roomDesc preset' do
        receive_from_server(*preset)

        expect(main_rows).to eq ['Before. A room.', 'Obvious paths: north.']
      end

      it 'is not flushed by a roomDesc style' do
        receive_from_server(*style)

        expect(main_rows).to eq ['Before. A room.', 'Obvious paths: north.']
      end
    end
  end

  it 'does not end a roomName capture at a preset close inside it' do
    load_layout
    state.room_window_only = true

    receive_from_server(%(<style id="roomName" />[Town <preset id='speech'>Square</preset>]<style id=""/>), 'Obvious exits: north.')

    expect(room_rows.first).to eq '[Town Square]'
    expect(state.room_title).to eq 'Town Square'
    expect(main_rows).to be_empty
  end

  it 'ends a roomDesc style capture at any preset close inside it' do
    load_layout
    state.room_window_only = true

    receive_from_server(%(<style id='roomDesc'/>A <preset id='speech'>b</preset> c.<style id=''/>), 'Obvious paths: north.')

    expect(room_rows).to eq ['A b c.', 'Obvious paths: north.']
    expect(main_rows).to eq [' c.']
  end
end
