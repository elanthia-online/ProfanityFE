# frozen_string_literal: true

# Tests how GameTextProcessor rewrites GemStone death cries on the death
# stream into the compact "HH:MM Name AREA" line shown in the death window.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'GameTextProcessor death stream (GemStone)' do
  let(:event_bus) { EventBus.new }
  let(:wm) do
    Struct.new(:stream, :indicator, :progress, :countdown, :room,
               :command_window, :command_window_layout).new(
                 { 'main' => Object.new, 'death' => Object.new }, {}, {}, {}, {}, nil, nil
               )
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

  def death_window_lines
    displayed.select { |stream, _| stream == 'death' }.map(&:last)
  end

  it 'shows a "may just be going home on his shield" death as "HH:MM Bob RED"' do
    receive_from_server('<pushStream id="death"/> * Bob may just be going home on his shield!', '<popStream/>')

    expect(death_window_lines).to contain_exactly(match(/\A\d\d:\d\d Bob RED\z/))
  end

  it 'shows a rough-start "bit the dust" death as "HH:MM Bob WL"' do
    receive_from_server('<pushStream id="death"/> * Bob is off to a rough start!  He just bit the dust!', '<popStream/>')

    expect(death_window_lines).to contain_exactly(match(/\A\d\d:\d\d Bob WL\z/))
  end
end
