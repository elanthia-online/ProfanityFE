# frozen_string_literal: true

# Tests the <dialogData> effect blocks (spells, buffs, debuffs, cooldowns)
# through the real server loop: each example sends server lines through
# GameTextProcessor#run and checks the :effects_update events emitted. The
# lines are the ones the game sent (spec/fixtures/effects_dialog.xml).

require 'rexml/document'
require 'socket'
require_relative '../../lib/event_bus'
require_relative '../../lib/shared_state'
require_relative '../../lib/clock'
require_relative '../../lib/window_manager'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/command_buffer'

RSpec.describe 'Effect dialogs (<dialogData>)' do
  let(:now) { 1_791_488_880 }
  let(:clock) { Clock.new(now: -> { Time.at(now) }) }
  let(:event_bus) { EventBus.new }
  let(:window_manager) { WindowManager.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: window_manager, shared_state: state, cmd_buffer: instance_double(CommandBuffer, window: nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus, clock: clock
    )
  end
  let!(:effects_events) { [].tap { |list| event_bus.on(:effects_update) { |data| list << data } } }
  let!(:progress_events) { [].tap { |list| event_bus.on(:progress_update) { |data| list << data } } }

  let(:fixture_lines) { File.readlines(File.expand_path('../fixtures/effects_dialog.xml', __dir__), chomp: true) }
  let(:other_dialog_lines) { File.readlines(File.expand_path('../fixtures/other_dialogs.xml', __dir__), chomp: true) }
  let(:prompt) { %(<prompt time="1791488882">&gt;</prompt>) }

  before do
    LAYOUT['effects_dialog'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='8' width='60' value='main'/>
        <window class='text' top='8' left='0' height='4' width='40' value='thoughts'/>
        <window class='text' top='12' left='0' height='4' width='40' value='combat'/>
      </layout>
    XML
    window_manager.load_layout('effects_dialog')
    window_manager.subscribe_to_events(event_bus)
    allow(IO).to receive(:select).and_return(nil)
    allow(ProfanityLog).to receive(:write) do |context, message, **|
      raise "#{context}: #{message}" if context == 'game_text_processor'
    end
  end

  def receive_from_server(*lines)
    client_end, server_end = UNIXSocket.pair
    server_end.write(lines.map { |line| "#{line}\r\n" }.join)
    server_end.close_write
    processor.run(client_end)
  ensure
    client_end&.close
    server_end&.close
  end

  def by_category
    effects_events.to_h { |event| [event[:category], event[:effects]] }
  end

  def shown(stream)
    window_manager.stream[stream].rows.reject(&:empty?)
  end

  describe 'the game\'s four blocks' do
    before { receive_from_server(*fixture_lines) }

    it 'emits one :effects_update per category, in the order sent' do
      expect(effects_events.map { |e| e[:category] }).to eq %i[spells debuffs cooldowns buffs]
    end

    it 'emits each effect with its id, name, percent and end_time' do
      expect(by_category[:buffs]).to eq [
        { id: '115', name: "Fasthr's Reward", percent: 97, end_time: now + 14_597.0 },
        { id: '1215', name: 'Blink', percent: 74, end_time: now + 11_198.0 },
      ]
    end

    it 'keeps the large ids and the order of the cooldowns' do
      expect(by_category[:cooldowns].map { |e| [e[:id], e[:name], e[:percent]] }).to eq [
        ['20990', 'Next Bounty', 39], ['194442916', 'Hallowed Reprisal', 5], ['194442920', 'Ardent Plea', 0]
      ]
    end

    it 'reads every spell, the indefinite ones with a nil end_time' do
      spells = by_category[:spells]
      expect([spells.size, spells.first, spells.select { |e| e[:end_time].nil? }.map { |e| e[:name] }]).to eq [
        19, { id: '101', name: 'Spirit Warding I', percent: 97, end_time: now + 14_579.0 },
        ['Mind over Body', 'Rolling Krynch Stance', 'Med. Resistance (Slash)']
      ]
    end

    it 'commits the empty debuffs (a label, no progressBar) as an empty bucket' do
      expect(by_category[:debuffs]).to eq []
    end

    it 'shows no text for the blocks' do
      expect(shown('main')).to be_empty
    end

    it 'does not send the effects to the vitals' do
      expect(progress_events).to be_empty
    end
  end

  it 'decodes the entities of an effect name' do
    receive_from_server(%(<dialogData id='Buffs' clear='t'></dialogData><dialogData id='Buffs'>) +
                        %(<progressBar id='9' value='50' text="Fasthr&apos;s &amp; Sons" time='00:00:10'/></dialogData>))

    expect(by_category[:buffs].map { |e| e[:name] }).to eq ["Fasthr's & Sons"]
  end

  it 'uses the server time now (the clock less its offset) for end_time' do
    clock.server_time_offset = 5.0
    receive_from_server(%(<dialogData id='Buffs'><progressBar id='9' value='50' text="Blink" time='00:00:10'/></dialogData>))

    expect(by_category[:buffs].first[:end_time]).to eq now - 5.0 + 10
  end

  it 'reads an effect without a time as indefinite' do
    receive_from_server(%(<dialogData id='Buffs'><progressBar id='9' value='50' text="Brace"/></dialogData>))

    expect(by_category[:buffs].first[:end_time]).to be_nil
  end

  it 'commits once for a block opened, filled and closed on three lines' do
    receive_from_server(%(<dialogData id='Buffs'>),
                        %(<progressBar id='115' value='97' text="Blink" time='00:00:10'/>),
                        %(<progressBar id='116' value='50' text="Haste" time='00:00:20'/>),
                        %(</dialogData>))

    expect(effects_events.map { |e| [e[:category], e[:effects].map { |x| x[:name] }] }).to eq [[:buffs, %w[Blink Haste]]]
  end

  it 'commits nothing until the block is closed' do
    receive_from_server(%(<dialogData id='Buffs'>), %(<progressBar id='115' value='97' text="Blink" time='00:00:10'/>))

    expect(effects_events).to be_empty
  end

  it 'finalizes a block whose </dialogData> never came at the next prompt' do
    receive_from_server(%(<dialogData id='Buffs'><progressBar id='115' value='97' text="Blink" time='00:00:10'/>), prompt)

    expect(effects_events.map { |e| [e[:category], e[:effects].map { |x| x[:name] }] }).to eq [[:buffs, %w[Blink]]]
  end

  it 'does not leak an unfinished block into the vitals after the prompt' do
    receive_from_server(%(<dialogData id='Buffs'><progressBar id='115' value='97' text="Blink" time='00:00:10'/>), prompt,
                        %(<progressBar id='health' value='100' text='health 456/456'/>))

    expect([effects_events.size, progress_events]).to eq [1, [{ id: 'health', value: 456, max: 456 }]]
  end

  it 'commits a clear block that nothing followed at the next prompt' do
    receive_from_server(%(<dialogData id='Buffs' clear='t'></dialogData>), prompt)

    expect(effects_events).to eq [{ category: :buffs, effects: [] }]
  end

  it 'commits a block of one category and then the next without a close tag between' do
    receive_from_server(%(<dialogData id='Buffs'><progressBar id='1' value='1' text="A" time='00:00:10'/>),
                        %(<dialogData id='Cooldowns'><progressBar id='2' value='2' text="B" time='00:00:10'/></dialogData>))

    expect(effects_events.map { |e| e[:category] }).to eq %i[buffs cooldowns]
  end

  describe 'a dialog that holds no effects' do
    it 'records no effects for the combat dropDownBox' do
      receive_from_server(*other_dialog_lines.first(1))

      expect(effects_events).to be_empty
    end

    it 'does not switch to combat for its tags while combat routing is on' do
      receive_from_server(%(<pushStream id="combat"/><component id='thoughts'>#{other_dialog_lines.first}You recall a song.))

      expect([shown('thoughts'), shown('combat')]).to eq [['You recall a song.'], []]
    end

    it 'does not switch to combat for an effect block while combat routing is on' do
      receive_from_server(%(<pushStream id="combat"/><component id='thoughts'>#{fixture_lines.first}You recall a song.))

      expect([shown('thoughts'), shown('combat')]).to eq [['You recall a song.'], []]
    end

    it 'still switches to combat for an unrecognized tag outside a dialog' do
      receive_from_server(%(<pushStream id="combat"/><component id='thoughts'><unknownTag/>The goblin lunges.))

      expect([shown('thoughts'), shown('combat')]).to eq [[], ['The goblin lunges.']]
    end

    it 'leaves a self-closing dialog closed' do
      receive_from_server(%(<pushStream id="combat"/><component id='thoughts'><dialogData id="foo"/><unknownTag/>Text.))

      expect(shown('combat')).to eq ['Text.']
    end

    it 'keeps the vitals of minivitals working' do
      receive_from_server(other_dialog_lines.last)

      expect([effects_events, progress_events]).to eq [[], [{ id: 'health', value: 456, max: 456 }]]
    end
  end

  describe 'a standalone progressBar with no dialog open' do
    it 'still routes to the vitals' do
      receive_from_server(%(<progressBar id='health' value='100' text='health 456/456' left='0%'/>))

      expect([effects_events, progress_events]).to eq [[], [{ id: 'health', value: 456, max: 456 }]]
    end

    it 'still routes stance, mind and encumbrance' do
      receive_from_server(%(<progressBar id='pbarStance' value='80'/>), %(<progressBar id='mindState' value='50' text='clear'/>),
                          %(<progressBar id='encumlevel' value='20' text='Light'/>))

      expect(progress_events.map { |e| [e[:id], e[:value]] }).to eq [['stance', 80], ['mind', 50], ['encumbrance', 20]]
    end

    it 'still routes the vitals after an effect block closed' do
      receive_from_server(*fixture_lines, %(<progressBar id='health' value='100' text='health 456/456'/>))

      expect(progress_events).to eq [{ id: 'health', value: 456, max: 456 }]
    end
  end

  describe 'custom timers (ProfanityCustom)' do
    def custom_events
      effects_events.select { |event| event[:category] == :custom }
    end

    def custom_names
      custom_events.last[:effects].map { |effect| effect[:name] }
    end

    it 'emits :custom with the timers of a block, from a Lich script\'s line' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='mytimer' text='My Timer' time='00:05:00'/></dialogData>))

      expect(effects_events).to eq [{ category: :custom,
                                      effects: [{ id: 'mytimer', name: 'My Timer', percent: 100, end_time: now + 300.0 }] }]
    end

    it 'decodes the entities of a name and reads value and end_time' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='a' text="Fasthr&apos;s &amp; Co" value='25' ) +
                          %(end_time='1791489999'/></dialogData>))

      expect(effects_events.first[:effects]).to eq [{ id: 'a', name: "Fasthr's & Co", percent: 25, end_time: 1_791_489_999.0 }]
    end

    it 'keeps a timer sent once through later lines and game blocks' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='a' text='A' time='00:10:00'/></dialogData>),
                          *fixture_lines,
                          %(<dialogData id='ProfanityCustom'><progressBar id='b' text='B' time='00:10:00'/></dialogData>))

      expect(custom_events.map { |e| e[:effects].map { |x| x[:id] } }).to eq [%w[a], %w[a b]]
    end

    it 'does not turn a custom bar into a game effect or a vital' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='health' text='health 1/2' value='50' time='00:10:00'/></dialogData>))

      expect([effects_events.map { |e| e[:category] }, progress_events]).to eq [[:custom], []]
    end

    it 'removes one timer with a per-bar clear' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='a' text='A' time='00:10:00'/>) +
                          %(<progressBar id='b' text='B' time='00:10:00'/></dialogData>),
                          %(<dialogData id='ProfanityCustom'><progressBar id='a' clear='t'/></dialogData>))

      expect(custom_names).to eq %w[B]
    end

    it 'removes every timer with an empty clear block, committing it without a block after it' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='a' text='A' time='00:10:00'/></dialogData>),
                          %(<dialogData id='ProfanityCustom' clear='t'></dialogData>))

      expect(custom_events.last).to eq({ category: :custom, effects: [] })
    end

    it 'removes every timer with a self-closing clear tag' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='a' text='A' time='00:10:00'/></dialogData>),
                          %(<dialogData id='ProfanityCustom' clear='t'/>))

      expect(custom_events.last).to eq({ category: :custom, effects: [] })
    end

    it 'ignores a self-closing tag that is not a clear for the game categories' do
      receive_from_server(%(<dialogData id='Buffs'/>))

      expect(effects_events).to be_empty
    end

    it 'commits a clear block and the timers that follow it in one line as the timers' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='old' text='Old' time='00:10:00'/></dialogData>),
                          %(<dialogData id='ProfanityCustom' clear='t'></dialogData><dialogData id='ProfanityCustom'>) +
                          %(<progressBar id='new' text='New' time='00:10:00'/></dialogData>))

      expect(custom_names).to eq %w[New]
    end

    it 'commits once for a block opened, filled and closed on three lines' do
      receive_from_server(%(<dialogData id='ProfanityCustom'>),
                          %(<progressBar id='a' text='A' time='00:10:00'/>),
                          %(</dialogData>))

      expect(custom_events.size).to eq 1
    end

    it 'finalizes a block whose </dialogData> never came at the next prompt' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='a' text='A' time='00:10:00'/>), prompt)

      expect(custom_names).to eq %w[A]
    end

    it 'finalizes an unclosed clear block at the next prompt' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='a' text='A' time='00:10:00'/></dialogData>),
                          %(<dialogData id='ProfanityCustom' clear='t'>), prompt)

      expect(custom_events.last).to eq({ category: :custom, effects: [] })
    end

    it 'does not switch to combat for its tags while combat routing is on' do
      receive_from_server(%(<pushStream id="combat"/><component id='thoughts'><dialogData id='ProfanityCustom'>) +
                          %(<progressBar id='a' text='A' time='00:10:00'/><label id='la' value='x'/></dialogData>You recall a song.))

      expect([shown('thoughts'), shown('combat'), custom_names]).to eq [['You recall a song.'], [], %w[A]]
    end

    it 'shows no text for the block' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='a' text='A' time='00:10:00'/></dialogData>))

      expect(shown('main')).to be_empty
    end

    it 'leaves the vitals working after a custom block' do
      receive_from_server(%(<dialogData id='ProfanityCustom'><progressBar id='a' text='A' time='00:10:00'/></dialogData>),
                          %(<progressBar id='health' value='100' text='health 456/456'/>))

      expect(progress_events).to eq [{ id: 'health', value: 456, max: 456 }]
    end
  end

  it 'leaves the arbProgress path of the scripts alone' do
    receive_from_server(%(<arbProgress id='spell0' max='1200' current='600' label='x' colors='395573,9BA2B2'></arbProgress>))

    expect([effects_events, progress_events.map { |e| e[:id] }]).to eq [[], ['spell0']]
  end
end
