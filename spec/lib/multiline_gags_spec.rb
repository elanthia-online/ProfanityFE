# frozen_string_literal: true

# What main shows around a multi-line gag (<gag start=… end=…>): the block
# is hidden from its starting line through its end line, or up to the next
# prompt when the gag has no end pattern; a block that never ends is let go
# after LineFilter::MULTILINE_GAG_MAX_LINES hidden lines.
#
# Lines are fed through the real server loop (GameTextProcessor#run) into a
# real main window built from layout XML; the assertions are on what main
# shows. (Gag logging and the stream tags a gagged line keeps are in
# gagged_lines_spec.rb.)

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

# Load the REAL GagPatterns module (replaces the spec_helper stub)
original_verbose = $VERBOSE
$VERBOSE = nil
load File.expand_path('../../lib/gag_patterns.rb', __dir__)
$VERBOSE = original_verbose

RSpec.describe 'Multi-line gags' do
  after { GagPatterns.load_defaults }

  # A real sanowret crystal block: a header, then the knowledge.
  let(:block_start) { 'Knowledge from your sanowret crystal about Arcana rings clear in your mind:' }
  let(:block_body) { 'Mana is the basic building block of magic.' }
  let(:block_end) { 'End of knowledge.' }
  # A prompt that differs from the one main starts with ('>'), so it shows.
  let(:prompt) { '<prompt time="1800000000">H&gt;</prompt>' }

  before do
    LAYOUT['gags'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='12' width='100' value='main'/>
      </layout>
    XML
    event_bus = EventBus.new
    @window_manager = WindowManager.new
    @window_manager.load_layout('gags')
    @window_manager.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @window_manager, shared_state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would (Lich ends every line with CRLF). The first prompt makes the
  # client send 'look', which this server accepts.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |*| nil }
    server.define_singleton_method(:flush) { nil }
    allow(IO).to receive(:select).and_return(nil)
    @processor.run(server)
  end

  # The lines main shows, blank rows left out.
  def shown_in_main
    @window_manager.stream['main'].rows.reject(&:empty?)
  end

  describe 'a gag that runs to the next prompt (no end pattern)' do
    before { GagPatterns.add_multiline_gag('^Knowledge from your sanowret crystal') }

    it 'shows every line while no block has started' do
      receive_from_server('You feel refreshed.', block_body)

      expect(shown_in_main).to eq ['You feel refreshed.', block_body]
    end

    it 'hides the line that starts a block' do
      receive_from_server('You gaze into your crystal.', block_start)

      expect(shown_in_main).to eq ['You gaze into your crystal.']
    end

    it 'hides the lines after the start until the prompt' do
      receive_from_server(block_start, block_body, 'It flows through all things.')

      expect(shown_in_main).to be_empty
    end

    it 'ends at the prompt, which shows, as do the lines after it' do
      receive_from_server(block_start, block_body, prompt, 'You feel refreshed.')

      expect(shown_in_main).to eq ['H>', 'You feel refreshed.']
    end

    it "lets a block go after #{LineFilter::MULTILINE_GAG_MAX_LINES} hidden lines, showing the lines after them" do
      hidden_lines = Array.new(LineFilter::MULTILINE_GAG_MAX_LINES) { |i| "Hidden line #{i + 1} of a runaway block." }

      receive_from_server(block_start, *hidden_lines, 'The first line shown again.', 'And the next.')

      expect(shown_in_main).to eq ['The first line shown again.', 'And the next.']
    end
  end

  describe 'a gag with an end pattern' do
    before { GagPatterns.add_multiline_gag('^Knowledge from your sanowret crystal', '^End of knowledge\.') }

    it 'hides the lines through the end line, and shows the lines after it' do
      receive_from_server(block_start, block_body, block_end, 'You feel refreshed.')

      expect(shown_in_main).to eq ['You feel refreshed.']
    end

    it 'does not end at a prompt, which it hides too' do
      receive_from_server(block_start, prompt, block_body, block_end)

      expect(shown_in_main).to be_empty
    end
  end
end
