# frozen_string_literal: true

# Tests how GameTextProcessor treats blank lines from the game: they are
# not displayed, but a blank line is still where a pending prompt is shown
# (except after movement, where the prompt is skipped too).

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'GameTextProcessor blank lines from the game' do
  let(:event_bus) { EventBus.new }
  let(:wm) do
    Struct.new(:stream, :indicator, :progress, :countdown, :room,
               :command_window, :command_window_layout).new({ 'main' => Object.new }, {}, {}, {}, {}, nil, nil)
  end
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: wm,
      shared_state: state,
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end
  let(:shown) { [] }

  before do
    GagPatterns.load_defaults
    allow(IO).to receive(:select).and_return(nil)
    allow(processor).to receive(:show_disconnect_message)
    allow(processor).to receive(:exit)
    event_bus.on(:stream_text) { |data| shown << data[:text] }
    event_bus.on(:add_prompt) { |data| shown << "PROMPT #{data[:text]}" }
  end

  # Feed raw lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    processor.run(server)
  end

  it 'does not display a blank line between two lines of game text' do
    receive_from_server('A goblin arrives.', '', 'You wave.')

    expect(shown).to eq ['A goblin arrives.', 'You wave.']
  end

  it 'still shows a pending prompt where the blank line was' do
    state.need_prompt = true

    receive_from_server('', 'You wave.')

    expect(shown).to eq ['PROMPT >', 'You wave.']
  end

  it 'shows neither the blank line nor the prompt that follows movement' do
    receive_from_server('You walk north.', '<prompt time="1">&gt;</prompt>', '', 'A goblin arrives.')

    expect(shown).not_to include('', a_string_starting_with('PROMPT'))
    expect(shown).to include('You walk north.', 'A goblin arrives.')
  end
end
