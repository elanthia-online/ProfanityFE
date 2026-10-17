# frozen_string_literal: true

# Tests how GameTextProcessor treats blank lines from the game. By default
# no interior blank row is shown. With blank lines turned on (+.blanklines+
# on, or +blank_lines: true+), a blank line between two lines of main text
# is shown (held until the next line of text arrives); a prompt discards a
# held blank, so no empty row comes before a prompt. A blank line right after
# movement is not held. A blank line is still where a pending prompt is shown
# (except after movement, where the prompt is skipped too), on or off.

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
    server.define_singleton_method(:puts) { |_command| nil }
    server.define_singleton_method(:flush) { self }
    processor.run(server)
  end

  it 'is off by default: no blank line between two lines of game text' do
    receive_from_server('A goblin arrives.', '', 'You wave.')

    expect(shown).to eq ['A goblin arrives.', 'You wave.']
  end

  it 'drops a run of blank lines by default' do
    receive_from_server('A goblin arrives.', '', '', '', 'You wave.')

    expect(shown).to eq ['A goblin arrives.', 'You wave.']
  end

  context 'with blank lines turned on' do
    before { processor.blank_lines_enabled = true }

    it 'shows a blank line between two lines of game text' do
      receive_from_server('A goblin arrives.', '', 'You wave.')

      expect(shown).to eq ['A goblin arrives.', '', 'You wave.']
    end

    it 'shows the blank line only when the next line of text arrives' do
      receive_from_server('A goblin arrives.', '')

      expect(shown).to eq ['A goblin arrives.']
    end

    it 'shows one blank line for a run of blank lines' do
      receive_from_server('A goblin arrives.', '', '', '', 'You wave.')

      expect(shown).to eq ['A goblin arrives.', '', 'You wave.']
    end

    it 'shows no blank line before a prompt that changed' do
      receive_from_server('A goblin arrives.', '', '<prompt time="2">H&gt;</prompt>')

      expect(shown).to eq ['A goblin arrives.', 'PROMPT H>']
    end

    it 'shows no blank line before a prompt that is shown with the next text' do
      receive_from_server('A goblin arrives.', '', '<prompt time="2">&gt;</prompt>', 'You wave.')

      expect(shown).to eq ['A goblin arrives.', 'PROMPT >', 'You wave.']
    end

    it 'does not show a blank line held before a changed prompt once the next text arrives' do
      receive_from_server('A goblin arrives.', '', '<prompt time="2">H&gt;</prompt>', 'You wave.')

      expect(shown).to eq ['A goblin arrives.', 'PROMPT H>', 'You wave.']
    end

    it 'keeps a blank line held for the game\'s copy of a stream line, which is dropped' do
      wm.stream['thoughts'] = Object.new
      main_texts = []
      event_bus.on(:stream_text) { |data| main_texts << data[:text] if data[:stream] == 'main' }

      receive_from_server('Hello.', '<pushStream id="thoughts"/>You hear Bob think, "Hi."', '<popStream/>', '',
                          'You hear Bob think, "Hi."', 'Next.')

      expect(main_texts).to eq ['Hello.', '', 'Next.']
    end
  end

  context 'with blank lines turned off' do
    before { processor.blank_lines_enabled = false }

    it 'is how a processor is built for the saved setting' do
      off = GameTextProcessor.new(
        window_mgr: wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
        xml_escapes: {}, event_bus: event_bus, blank_lines: false
      )
      allow(off).to receive(:show_disconnect_message)
      queue = ["A goblin arrives.\r\n", "\r\n", "You wave.\r\n"]
      server = Object.new
      server.define_singleton_method(:gets) { queue.shift&.dup }

      off.run(server)

      expect(shown).to eq ['A goblin arrives.', 'You wave.']
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
