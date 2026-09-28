# frozen_string_literal: true

# Tests the command a clicked link sends. Server lines are driven through the
# real server loop into a real text window built from layout XML, and the
# command is read back from the window at the column where the link is shown.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Link commands' do
  let(:event_bus) { EventBus.new }
  let(:state) do
    SharedState.new.tap do |s|
      s.skip_server_time_offset = true
      s.blue_links = true
    end
  end
  let(:window) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='text' top='0' left='0' height='3' width='90' value='main'/></layout>
    XML
    wm = WindowManager.new
    wm.load_layout('test')
    wm.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
    wm.stream['main']
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    allow(IO).to receive(:select).and_return(nil)
    @processor.run(server)
  end

  it 'sends the cmd of a link whose cmd is in single quotes' do
    window
    receive_from_server("Go through <d cmd='go door'>the door</d>.")

    expect(window.rows.first).to eq 'Go through the door.'
    expect(window.link_cmd_at(0, 11)).to eq 'go door'
  end

  it 'sends the cmd of a link whose cmd is in double quotes' do
    window
    # A line of DR's FLAG output, from a Lich XML session log.
    receive_from_server('  <d cmd="flag LogOff on">LogOff</d>             OFF  Do not show logoff messages.')

    expect(window.rows.first).to start_with '  LogOff'
    expect(window.link_cmd_at(0, 2)).to eq 'flag LogOff on'
  end
end
