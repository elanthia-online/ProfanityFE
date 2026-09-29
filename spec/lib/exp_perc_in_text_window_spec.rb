# frozen_string_literal: true

# Tests a layout that lists the exp and percWindow streams in a text or
# tabbed window instead of giving them an exp or spell window: their
# lines show there like any other stream's, driven through the real
# server loop (GameTextProcessor#run) with lines as DragonRealms sends
# them, and nothing is logged as an error.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'The exp and percWindow streams in a text window' do
  let(:event_bus) { EventBus.new }
  let(:wm) { WindowManager.new }
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
  let(:errors) { [] }

  # A spell update, a skill update on the same line as main text and a
  # roundtime, and a skill removal (an empty exp component).
  let(:session) do
    [
      '<clearStream id="percWindow"/>',
      '<pushStream id="percWindow"/>Finesse  (18 roisaen)',
      'Noumena  (27 roisaen)',
      '<popStream/>You wave.',
      "You nod.<roundTime value='1790390560'/><component id='exp Utility'><preset id='whisper'>" \
      '         Utility: 1700 87% perusing      0.46     </preset></component>',
      "<component id='exp Arcana'></component>",
      'You smile.',
    ]
  end

  before do
    GagPatterns.load_defaults
    allow(ProfanityLog).to receive(:write) { |context, message, **| errors << "#{context}: #{message}" }
  end

  def load(windows)
    LAYOUT['exp-perc'] = REXML::Document.new("<layout>#{windows}</layout>").root
    wm.load_layout('exp-perc')
    wm.subscribe_to_events(event_bus)
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

  def visible_rows(window)
    window.rows.reject(&:empty?)
  end

  it 'shows the spell and skill lines in order among the main text' do
    load("<window class='text' top='0' left='0' height='10' width='52' value='main,percWindow,exp'/>")

    receive_from_server(*session)

    expect(visible_rows(wm.stream['main'])).to eq ['FIN (18 roisaen)', 'NOU (27 roisaen)', 'You wave.', 'You nod.',
                                                   '         Utility: 1700 87% perusing      0.46', 'You smile.']
    expect(errors).to be_empty
  end

  it 'shows the spell and skill lines in their tabs of a tabbed window' do
    load("<window class='text' top='0' left='0' height='5' width='52' value='main'/>" \
         "<window class='tabbed' top='5' left='0' height='5' width='52' tabs='exp,percWindow'/>")
    tabbed = wm.stream['exp']

    receive_from_server(*session)

    expect(visible_rows(wm.stream['main'])).to eq ['You wave.', 'You nod.', 'You smile.']
    tabbed.switch_tab('exp')
    expect(visible_rows(tabbed).drop(1)).to eq ['         Utility: 1700 87% perusing      0.46']
    tabbed.switch_tab('percWindow')
    expect(visible_rows(tabbed).drop(1)).to eq ['FIN (18 roisaen)', 'NOU (27 roisaen)']
    expect(errors).to be_empty
  end

  it 'still files skills and spells in exp and spell windows' do
    load("<window class='text' top='0' left='0' height='5' width='52' value='main'/>" \
         "<window class='exp' top='5' left='0' height='3' width='52'/>" \
         "<window class='percWindow' top='8' left='0' height='3' width='52' value='percWindow'/>")

    receive_from_server(*session)
    shown = visible_rows(wm.stream['exp'])
    receive_from_server("<component id='exp Utility'></component>")

    expect(visible_rows(wm.stream['main'])).to eq ['You wave.', 'You nod.', 'You smile.']
    expect(shown).to eq [' Utility: 1700 87% perusing      0.46']
    expect(visible_rows(wm.stream['exp'])).to be_empty
    expect(visible_rows(wm.stream['percWindow'])).to eq ['NOU (27 roisaen)', 'FIN (18 roisaen)']
    expect(errors).to be_empty
  end
end
