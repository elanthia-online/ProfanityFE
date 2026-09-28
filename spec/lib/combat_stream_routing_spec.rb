# frozen_string_literal: true

# Tests where text shows up after a combat stream block closes. While a combat
# block is open, a line carrying an unrecognized tag (such as DragonRealms'
# <crtrStatus/>) is kept in the combat window; once the block closes, such lines
# belong in main again. The lines below are driven through the real server loop
# into real windows built from layout XML, and the assertions are on what each
# window shows.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Combat stream routing' do
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }

  before do
    rows = %w[main combat].each_with_index.map do |streams, i|
      "<window class='text' top='#{i * 3}' left='0' height='3' width='60' value='#{streams}'/>"
    end
    LAYOUT['test'] = REXML::Document.new("<layout>#{rows.join}</layout>").root
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
    allow(IO).to receive(:select).and_return(nil)
    @processor.run(server)
  end

  def shown_in(stream)
    @wm.stream[stream].rows.reject(&:empty?)
  end

  it 'shows a creature line in main after the combat block closes with <popStream id="combat" />' do
    receive_from_server('<pushStream id="combat"/>You swing at a rat.',
                        '<popStream id="combat" />',
                        '<crtrStatus exist="1" hostile="1"/>A rat arrives.')

    expect(shown_in('combat')).to eq ['You swing at a rat.']
    expect(shown_in('main')).to eq ['A rat arrives.']
  end

  it 'shows a creature line in main after the combat block closes with a bare <popStream/>' do
    receive_from_server('<pushStream id="combat"/>You swing at a rat.',
                        '<popStream/>',
                        '<crtrStatus exist="1" hostile="1"/>A rat arrives.')

    expect(shown_in('combat')).to eq ['You swing at a rat.']
    expect(shown_in('main')).to eq ['A rat arrives.']
  end
end
