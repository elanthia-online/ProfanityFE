# frozen_string_literal: true

# Tests WindowManager#subscribe_to_events, the entry point the application
# uses to connect the parser's events to the windows, for what an update
# leaves alone and for sinks standing in for windows. Windows are built from
# layout XML by WindowManager#load_layout on the virtual screen.
#
# Where each event shows up is specified in event_bridge_spec.rb (the
# EventBridge that subscribe_to_events installs) and, with colors, in
# window_contracts_spec.rb.

require 'rexml/document'
require_relative '../../lib/event_bus'
require_relative '../../lib/window_manager'
require_relative '../../lib/windows/sink_window' # real SinkWindow (spec_helper only declares the class)

RSpec.describe WindowManager, '#subscribe_to_events' do
  let(:now) { 1_000_000.0 }
  let(:window_manager) { described_class.new(clock: Clock.new(now: -> { Time.at(now) })) }
  let(:event_bus) { EventBus.new }

  def load(windows_xml)
    LAYOUT['subscribe'] = REXML::Document.new("<layout>#{windows_xml}</layout>").root
    window_manager.load_layout('subscribe')
    window_manager.subscribe_to_events(event_bus)
  end

  describe 'an update that brings only some attributes' do
    before do
      load(<<~XML)
        <window class='indicator' top='0' left='0' height='1' width='12' value='spell' label='None'/>
        <window class='countdown' top='1' left='0' height='1' width='20' value='roundtime' label='RT'/>
      XML
    end

    let(:spell) { window_manager.indicator['spell'] }
    let(:roundtime) { window_manager.countdown['roundtime'] }

    it 'keeps the indicator on when an update brings only a new label' do
      event_bus.emit(:indicator_update, id: 'spell', value: 1)

      event_bus.emit(:indicator_update, id: 'spell', label: 'Fire Ball')

      expect(spell.rows).to eq ['Fire Ball']
      expect(spell.value).to eq 1
    end

    it 'keeps the indicator label when an update brings only a value' do
      event_bus.emit(:indicator_update, id: 'spell', label: 'Fire Ball')

      event_bus.emit(:indicator_update, id: 'spell', value: 0)

      expect(spell.rows).to eq ['Fire Ball']
      expect(spell.value).to eq 0
    end

    it 'keeps counting down the roundtime when only a cast time arrives' do
      event_bus.emit(:countdown_update, id: 'roundtime', end_time: now + 5)

      event_bus.emit(:countdown_update, id: 'roundtime', secondary_end_time: now + 3)

      expect(roundtime.rows).to eq ["RT#{'5'.rjust(18)}"]
    end
  end

  # <window class='sink' value='exp,percWindow'/> drops the exp and spell
  # streams; their component and clear events must not show anywhere.
  describe 'a sink standing in for the exp and spell windows' do
    before do
      load(<<~XML)
        <window class='text' top='0' left='0' height='3' width='40' value='main'/>
        <window class='sink' value='exp,percWindow'/>
      XML
    end

    let(:main) { window_manager.stream['main'] }

    it 'shows the exp and spell events and text nowhere' do
      event_bus.emit(:exp_set_current, skill: 'Athletics')
      event_bus.emit(:stream_text, stream: 'exp', text: 'Athletics: 12 34%', colors: [])
      event_bus.emit(:exp_delete_skill)
      event_bus.emit(:clear_spells)

      expect(window_manager.stream['exp']).to be_a SinkWindow
      expect(main.rows).to eq ['', '', '']
    end
  end
end
