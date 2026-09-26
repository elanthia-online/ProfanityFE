# frozen_string_literal: true

# Tests how GameTextProcessor treats lines dropped by general and multi-line
# gags: the text is hidden but stream tags are still processed, so a gag
# cannot leave routing stuck on a side stream; and with --log-gags every
# gagged line is written to the log in full.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/window_manager'

# Load the REAL GagPatterns module (replaces the spec_helper stub)
original_verbose = $VERBOSE
$VERBOSE = nil
load File.expand_path('../../lib/gag_patterns.rb', __dir__)
$VERBOSE = original_verbose

RSpec.describe 'GameTextProcessor gagged lines' do
  before { GagPatterns.load_defaults }
  after { GagPatterns.load_defaults }

  let(:event_bus) { EventBus.new }
  let(:wm) do
    Struct.new(:stream, :indicator, :progress, :countdown, :room,
               :command_window, :command_window_layout).new(
                 { 'main' => Object.new, 'percWindow' => Object.new, 'whispers' => Object.new }, {}, {}, {}, {}, nil, nil
               )
  end
  let(:state) do
    Struct.new(:need_prompt, :prompt_text, :skip_server_time_offset,
               :room_title, :blue_links, :room_window_only, :server_time_offset,
               :remote_url, :log_gags) do
      def update_terminal_title = nil
    end.new(false, '>', true, '', false, false, 0.0, false, true)
  end
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: wm,
      shared_state: state,
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end
  let(:gag_log) { [] }
  let(:displayed) { [] }

  before do
    allow(ProfanityLog).to receive(:write) { |context, message, **| gag_log << message if context == 'gag' }
    event_bus.on(:stream_text) { |data| displayed << [data[:stream], data[:text]] unless data[:text].empty? }
  end

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

  describe 'stream tags on a gagged line' do
    # Sequence from a real DragonRealms log: the spell window closes on the
    # same line as a creature death message that the user gags.
    it 'still closes the spell window when the gagged line carries <popStream/>' do
      GagPatterns.add_general_pattern("^(?:<.*>)?(?:The|A|An) (?:elder )?Adan'f blademaster")

      receive_from_server('<pushStream id="percWindow"/>Bloodthorns  (44 roisaen)',
                          "<popStream/>An elder Adan'f blademaster falls to the ground with a crash.",
                          'The forces within the hanger cause the weapon to explode in a spray of red mist!')

      expect(displayed).to eq([
                                ['percWindow', 'Bloodthorns (44 roisaen)'],
                                ['main', 'The forces within the hanger cause the weapon to explode in a spray of red mist!']
                              ])
    end

    it 'keeps a gagged push/pop pair balanced and shows neither line' do
      GagPatterns.add_general_pattern('Ytterby whispers,</preset> "Done!"$')

      receive_from_server('<pushStream id="whispers"/><preset id="whisper">Ytterby whispers,</preset> "Done!"',
                          '<popStream/><preset id="whisper">Ytterby whispers,</preset> "Done!"',
                          'You wave.')

      expect(displayed).to eq([['main', 'You wave.']])
    end

    it 'still closes the stream when a multi-line gag block spans the <popStream/>' do
      GagPatterns.add_multiline_gag('^Knowledge from your sanowret crystal', '^End of knowledge\.')

      receive_from_server('<pushStream id="percWindow"/>Bloodthorns  (44 roisaen)',
                          'Knowledge from your sanowret crystal about Arcana rings clear in your mind:',
                          '<popStream/>Mana is the basic building block of magic.',
                          'End of knowledge.',
                          'You wave.')

      expect(displayed.last).to eq(['main', 'You wave.'])
    end
  end

  describe 'with --log-gags' do
    it 'logs a line dropped by a general gag, with the pattern that matched' do
      GagPatterns.add_general_pattern('^A warm breeze')

      receive_from_server('A warm breeze blows through the area.')

      expect(gag_log).to eq(['general /^A warm breeze/ "A warm breeze blows through the area."'])
      expect(displayed).to be_empty
    end

    it 'flags a gagged line that carried a stream tag' do
      GagPatterns.add_general_pattern('^(?:<.*>)?A storm bull')

      receive_from_server('<popStream/>A storm bull charges in!')

      expect(gag_log).to eq(['general STREAM-TAG /^(?:<.*>)?A storm bull/ "<popStream/>A storm bull charges in!"'])
    end

    it 'logs every line suppressed by a multi-line gag, but not the prompt that ends it' do
      GagPatterns.add_multiline_gag('^Knowledge from your sanowret crystal')

      receive_from_server('Knowledge from your sanowret crystal about Arcana rings clear in your mind:',
                          'Mana is the basic building block of magic.',
                          '<prompt time="1">&gt;</prompt>')

      header = 'multiline /^Knowledge from your sanowret crystal/ ' \
               '"Knowledge from your sanowret crystal about Arcana rings clear in your mind:"'
      body = 'multiline /^Knowledge from your sanowret crystal/ "Mana is the basic building block of magic."'
      expect(gag_log).to eq([header, body])
    end

    it 'shortens long gag patterns to their first 80 characters' do
      long_pattern = "^A warm breeze|#{'x' * 100}"
      GagPatterns.add_general_pattern(long_pattern)

      receive_from_server('A warm breeze blows through the area.')

      expect(gag_log.first).to start_with("general /#{long_pattern[0, 80]}.../ ")
    end

    it 'logs nothing without --log-gags, but still gags the line' do
      state.log_gags = false
      GagPatterns.add_general_pattern('^A warm breeze')

      receive_from_server('A warm breeze blows through the area.')

      expect(gag_log).to be_empty
      expect(displayed).to be_empty
    end
  end
end
