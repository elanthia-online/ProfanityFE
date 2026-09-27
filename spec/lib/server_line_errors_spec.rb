# frozen_string_literal: true

# Tests that an error while processing one server line is logged and the
# line skipped, instead of ending the session, while a lost connection still
# ends it through the normal disconnect path.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/window_manager'

RSpec.describe 'GameTextProcessor errors while processing a server line' do
  let(:event_bus) { EventBus.new }
  let(:wm) do
    Struct.new(:stream, :indicator, :progress, :countdown, :room,
               :command_window, :command_window_layout).new({ 'main' => Object.new }, {}, {}, {}, {}, nil, nil)
  end
  let(:state) do
    Struct.new(:need_prompt, :prompt_text, :skip_server_time_offset,
               :room_title, :blue_links, :room_window_only, :server_time_offset,
               :remote_url, :log_gags) do
      def update_terminal_title = nil
    end.new(false, '>', true, '', false, false, 0.0, false, false)
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
  let(:displayed) { [] }

  before do
    GagPatterns.load_defaults
    allow(IO).to receive(:select).and_return(nil)
    allow(ProfanityLog).to receive(:write)
    allow(processor).to receive(:show_disconnect_message)
    allow(processor).to receive(:exit)
  end

  # Feed lines through GameTextProcessor#run; a line given as an exception
  # is raised by gets instead, as a failing socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| line.is_a?(Exception) ? line : "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) do
      item = queue.shift
      raise item if item.is_a?(Exception)

      item&.dup
    end
    processor.run(server)
  end

  it 'logs a line whose window handler raises and keeps processing later lines' do
    event_bus.on(:stream_text) do |data|
      raise 'window exploded' if data[:text] == 'A goblin arrives.'

      displayed << data[:text] unless data[:text].empty?
    end

    receive_from_server('A goblin arrives.', 'You wave.')

    expect(displayed).to eq ['You wave.']
    expect(ProfanityLog).to have_received(:write)
      .with('game_text_processor', a_string_including('window exploded'), backtrace: anything)
  end

  it 'still ends the session through the disconnect path when the connection is lost' do
    event_bus.on(:stream_text) { |data| displayed << data[:text] unless data[:text].empty? }

    outcome = receive_from_server('You wave.', IOError.new('stream closed'), 'never read')

    expect(displayed).to eq ['You wave.']
    expect(outcome).to eq :disconnected
  end

  it 'reports a disconnect at end of stream' do
    expect(receive_from_server('You wave.')).to eq :disconnected
  end

  # Lich closing with client data still unread resets the connection
  # instead of closing it cleanly; that is still a normal disconnect.
  [Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED].each do |error_class|
    it "reports a disconnect, not a crash, when the connection ends with #{error_class}" do
      expect(receive_from_server('You wave.', error_class.new)).to eq :disconnected
      expect(ProfanityLog).to have_received(:write)
        .with('game_text_processor', a_string_including('disconnected', error_class.name))
    end
  end

  it 'reports a crash, logged with its backtrace, for any other error' do
    expect(receive_from_server(RuntimeError.new('reader exploded'))).to eq :crashed
    expect(ProfanityLog).to have_received(:write)
      .with('game_text_processor', 'reader exploded', backtrace: anything)
  end

  it 'leaves the disconnect notice and the exit to its caller' do
    receive_from_server('You wave.', Errno::ECONNRESET.new)

    expect(processor).not_to have_received(:show_disconnect_message)
    expect(processor).not_to have_received(:exit)
  end
end
