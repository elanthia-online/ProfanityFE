# frozen_string_literal: true

# Tests that GameTextProcessor#run survives non-ASCII bytes from the server.
# Socket reads are BINARY while gag and highlight patterns from the settings
# file are UTF-8; matching one against the other used to raise
# Encoding::CompatibilityError and end the session.

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

RSpec.describe 'GameTextProcessor server text encoding' do
  before { GagPatterns.load_defaults }
  after { GagPatterns.load_defaults }

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
  let(:displayed) { [] }

  before do
    event_bus.on(:stream_text) { |data| displayed << data[:text] unless data[:text].empty? }
    allow(IO).to receive(:select).and_return(nil)
    allow(processor).to receive(:show_disconnect_message)
    allow(processor).to receive(:exit)
  end

  # Feed lines through GameTextProcessor#run as BINARY strings, the way
  # TCPSocket#gets returns them.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n".b }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift }
    processor.run(server)
  end

  it 'keeps processing after a non-ASCII line when a gag pattern is non-ASCII' do
    GagPatterns.add_general_pattern('^Bob says — hi')

    receive_from_server('You see a café sign.', 'You wave.')

    expect(displayed).to eq(['You see a café sign.', 'You wave.'])
  end

  it 'keeps processing after a non-ASCII line when a highlight pattern is non-ASCII' do
    HIGHLIGHT[/café/] = ['ff0000', nil, nil]

    receive_from_server('You see a café sign.', 'You wave.')

    expect(displayed).to eq(['You see a café sign.', 'You wave.'])
  end

  it 'replaces invalid UTF-8 bytes instead of failing' do
    receive_from_server("A broken \xFF byte.", 'You wave.')

    expect(displayed).to eq(["A broken � byte.", 'You wave.'])
  end
end
