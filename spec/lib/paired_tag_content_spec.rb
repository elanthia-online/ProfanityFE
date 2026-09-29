# frozen_string_literal: true

# What the hand and spell indicators and the prompt show for a paired tag
# (<right>, <left>, <spell>, <prompt>) whose start tag has a quoted
# attribute value holding a >. The content starts after the whole start
# tag, not at the first > inside the value. The lines are driven through
# the real server loop into real windows built from layout XML.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Paired tag content' do
  before { GagPatterns.load_defaults }

  let(:event_bus) { EventBus.new }
  let(:window_manager) do
    WindowManager.new.tap do |wm|
      LAYOUT['paired'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='10' width='80' value='main'/>
          <window class='indicator' top='23' left='0' height='1' width='20' label=' ' value='left'/>
          <window class='indicator' top='23' left='25' height='1' width='20' label=' ' value='right'/>
          <window class='indicator' top='23' left='50' height='1' width='20' label=' ' value='spell'/>
        </layout>
      XML
      wm.load_layout('paired')
      wm.subscribe_to_events(event_bus)
    end
  end
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: window_manager,
      shared_state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |*| nil }
    server.define_singleton_method(:flush) { nil }
    allow(IO).to receive(:select).and_return(nil)
    processor.run(server)
  end

  # What an indicator shows, trailing blanks removed.
  def shown(id)
    window_manager.indicator[id].rows.first.rstrip
  end

  def main_rows
    window_manager.stream['main'].rows.map(&:rstrip).reject(&:empty?)
  end

  it 'shows the item in a hand whose noun holds a >' do
    receive_from_server('<right exist="1" noun="a>b">sword</right>', "<left exist='2' noun='x>y'>shield</left>")

    expect([shown('left'), shown('right')]).to eq %w[shield sword]
  end

  it 'shows the spell whose start tag has a value holding a >' do
    receive_from_server('<spell id="x>y">Fire</spell>')

    expect(shown('spell')).to eq 'Fire'
  end

  it 'shows the prompt whose start tag has a value holding a >' do
    receive_from_server('<prompt time="1" s="a>b">H&gt;</prompt>')

    expect(main_rows).to eq ['H>']
  end

  it 'shows the same for the same tags without a > in their values' do
    receive_from_server('<right exist="1" noun="ab">sword</right>', '<spell id="xy">Fire</spell>',
                        '<prompt time="1" s="ab">H&gt;</prompt>')

    expect([shown('right'), shown('spell'), main_rows]).to eq ['sword', 'Fire', ['H>']]
  end
end
