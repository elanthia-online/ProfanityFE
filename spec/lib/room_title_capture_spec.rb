# frozen_string_literal: true

# Tests what the user sees when a roomName style or roomDesc preset carries
# no text. The lines are driven through the real server loop into real
# windows built from layout XML: the room window's rows, the terminal
# title's room part (SharedState#room_title) and the main window.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Room title capture' do
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

  # A room as DR sends it: the roomName style opens on the title's line and
  # closes at the start of the next one.
  def town_square
    ['<resource picture="0"/><style id="roomName" />[Town Square] (1)', '<style id=""/>  ',
     'You also see a bench.', 'Obvious paths: <d>north</d>.']
  end

  context 'with a room window' do
    before { load_layout }

    it 'shows the title of a room whose roomName style has text' do
      receive_from_server(*town_square)

      expect(room_rows.first).to eq '[Town Square] (1)'
      expect(state.room_title).to eq 'Town Square (1)'
    end

    it 'does not take the next line as the title when the roomName style is empty' do
      receive_from_server(*town_square,
                          '<resource picture="0"/><style id="roomName" /><style id=""/>',
                          'A goblin arrives.',
                          'You also see a rock.', 'Obvious paths: <d>south</d>.')

      expect(room_rows).not_to include(a_string_including('goblin'))
      expect(room_rows.first).to eq 'You also see a rock.'
      expect(state.room_title).to eq 'Town Square (1)'
      expect(main_rows).to include 'A goblin arrives.'
    end

    it 'does not take the next line as the title when an empty roomName style closes on its own line' do
      receive_from_server(*town_square, '<resource picture="0"/><style id="roomName" />', '<style id=""/>',
                          'A goblin arrives.', 'You also see a rock.', 'Obvious paths: <d>south</d>.')

      expect(room_rows.first).to eq 'You also see a rock.'
      expect(state.room_title).to eq 'Town Square (1)'
    end

    it 'still takes a title that comes on the line after the roomName style, before the style closes' do
      receive_from_server('<resource picture="0"/><style id="roomName" />', '[Town Square] (1)', '<style id=""/>  ',
                          'You also see a bench.', 'Obvious paths: <d>north</d>.')

      expect(room_rows.first).to eq '[Town Square] (1)'
      expect(state.room_title).to eq 'Town Square (1)'
    end

    it 'does not take the objects after an empty roomDesc preset as the description' do
      receive_from_server('<resource picture="0"/><style id="roomName" />[Bailey Wall] (2)',
                          %(<style id=""/><preset id='roomDesc'></preset>  You also see a sign.),
                          'Obvious paths: <d>out</d>.')

      expect(room_rows).to eq ['[Bailey Wall] (2)', 'You also see a sign.', 'Obvious paths: out.']
    end

    it 'does not take the next line as the description when the roomDesc preset is empty' do
      receive_from_server('<resource picture="0"/><style id="roomName" />[Bailey Wall] (2)',
                          %(<style id=""/><preset id='roomDesc'></preset>),
                          'A goblin arrives.', 'You also see a sign.', 'Obvious paths: <d>out</d>.')

      expect(room_rows).to eq ['[Bailey Wall] (2)', 'You also see a sign.', 'Obvious paths: out.']
      expect(main_rows).to include 'A goblin arrives.'
    end

    it 'still takes a description that comes on the line after the roomDesc preset, before it closes' do
      receive_from_server('<resource picture="0"/><style id="roomName" />[Bailey Wall] (2)',
                          %(<style id=""/><preset id='roomDesc'>), 'A tiny building.',
                          '</preset>  You also see a sign.', 'Obvious paths: <d>out</d>.')

      expect(room_rows).to eq ['[Bailey Wall] (2)', 'A tiny building.', 'You also see a sign.', 'Obvious paths: out.']
    end

    it 'still shows the next line in main with --room-window-only' do
      state.room_window_only = true

      receive_from_server('<resource picture="0"/><style id="roomName" /><style id=""/>', 'A goblin arrives.')

      expect(main_rows).to eq ['A goblin arrives.']
    end
  end

  context 'without a room window' do
    before { load_layout(room_window: false) }

    it 'does not put the next line in the terminal title when the roomName style is empty' do
      receive_from_server(*town_square, '<resource picture="0"/><style id="roomName" /><style id=""/>',
                          'A goblin arrives.')

      expect(state.room_title).to eq 'Town Square (1)'
      expect(main_rows).to include 'A goblin arrives.'
    end
  end
end
