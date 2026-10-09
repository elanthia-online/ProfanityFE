# frozen_string_literal: true

# Tests EffectTracker, the model behind the native effect timers: the
# effects of each <dialogData> block collected into a bucket per category,
# and the :effects_update event each commit emits. No curses involved.

require_relative '../../lib/event_bus'
require_relative '../../lib/clock'
require_relative '../../lib/pending_render'
require_relative '../../lib/effect_tracker'

RSpec.describe EffectTracker do
  let(:event_bus) { EventBus.new }
  let(:pending_render) { PendingRender.new }
  let(:now) { [1_000_000] }
  let(:clock) { Clock.new(now: -> { Time.at(now[0]) }) }
  let(:tracker) { described_class.new(event_bus: event_bus, pending_render: pending_render, clock: clock) }
  let!(:events) do
    [].tap { |list| event_bus.on(:effects_update) { |data| list << data } }
  end

  def bar(id, text, value: '97', time: '00:01:30')
    { 'id' => id, 'text' => text, 'value' => value, 'time' => time }.compact
  end

  def commit(category, *bars)
    tracker.start_dialog(category)
    bars.each { |attrs| tracker.add_effect(attrs) }
    tracker.end_dialog
  end

  describe '.category_for' do
    it 'maps the four effect dialogs, ProfanityCustom and nothing else' do
      ids = ['Active Spells', 'Buffs', 'Debuffs', 'Cooldowns', 'ProfanityCustom', 'combat', 'minivitals', nil]
      expect(ids.map { |id| described_class.category_for(id) })
        .to eq [:spells, :buffs, :debuffs, :cooldowns, :custom, nil, nil, nil]
    end

    it 'does not take other spellings of the custom id' do
      expect(%w[profanitycustom Custom ProfanityCustom2].map { |id| described_class.category_for(id) }).to all(be_nil)
    end
  end

  describe '.parse_seconds' do
    it 'reads HH:MM:SS as seconds' do
      expect(described_class.parse_seconds('04:02:59')).to eq 14_579
    end

    it 'reads a zero time as 0' do
      expect(described_class.parse_seconds('00:00:00')).to eq 0
    end

    it 'is nil for no time (an indefinite effect)' do
      expect(described_class.parse_seconds(nil)).to be_nil
    end

    it 'is nil for Indefinite, which the server sends as the time' do
      expect(described_class.parse_seconds('Indefinite')).to be_nil
    end

    it 'is nil for malformed times' do
      expect(['', '12', '1:2', '04:02:xx', '-1:00:00', '04:02:59:01', 'abc'].map { |t| described_class.parse_seconds(t) }.compact).to eq []
    end
  end

  describe 'a commit' do
    it 'emits one :effects_update with the category and the effects in the contract shape' do
      commit(:buffs, bar('115', 'Blink', value: '74', time: '03:06:38'))

      expect(events).to eq [{ category: :buffs,
                              effects: [{ id: '115', name: 'Blink', percent: 74, end_time: 1_000_000.0 + 11_198 }] }]
    end

    it 'gives end_time as a Float' do
      commit(:buffs, bar('1', 'Blink'))

      expect(events.first[:effects].first[:end_time]).to be_a(Float)
    end

    it 'adds the time left to the server time now, which the clock offset moves' do
      clock.server_time_offset = 10.0
      commit(:buffs, bar('1', 'Blink', time: '00:00:20'))

      expect(events.first[:effects].first[:end_time]).to eq 1_000_010.0
    end

    it 'gives an indefinite effect a nil end_time' do
      commit(:spells, bar('1213', 'Mind over Body', value: '100', time: nil), bar('1214', 'Brace', time: 'Indefinite'))

      expect(events.first[:effects].map { |e| e[:end_time] }).to eq [nil, nil]
    end

    it 'keeps the effects in the order the server sent them' do
      commit(:spells, bar('9', 'Zeta'), bar('1', 'Alpha'), bar('5', 'Mu'))

      expect(events.first[:effects].map { |e| e[:id] }).to eq %w[9 1 5]
    end

    it 'keeps a large numeric id as the string it was sent as' do
      commit(:cooldowns, bar('194442916', 'Hallowed Reprisal'))

      expect(events.first[:effects].first[:id]).to eq '194442916'
    end

    it 'gives percent as an Integer within 0 to 100' do
      commit(:spells, bar('1', 'A', value: '0'), bar('2', 'B', value: '250'), bar('3', 'C', value: 'x'), bar('4', 'D', value: nil))

      expect(events.first[:effects].map { |e| e[:percent] }).to eq [0, 100, 0, 0]
    end

    it 'drops an effect without an id' do
      commit(:spells, bar(nil, 'Nameless'), bar('1', 'Kept'))

      expect(events.first[:effects].map { |e| e[:name] }).to eq ['Kept']
    end

    it 'asks for a screen update' do
      expect { commit(:buffs, bar('1', 'Blink')) }.to change { pending_render.update_requested? }.from(false).to(true)
    end

    it 'replaces the whole bucket of the category and leaves the others' do
      commit(:buffs, bar('1', 'Blink'), bar('2', 'Haste'))
      commit(:debuffs, bar('3', 'Bleeding'))
      commit(:buffs, bar('2', 'Haste'))

      expect([tracker.effects(:buffs).map { |e| e[:id] }, tracker.effects(:debuffs).map { |e| e[:id] }]).to eq [%w[2], %w[3]]
    end

    it 'emits an empty bucket for a block without effects' do
      commit(:debuffs)

      expect(events).to eq [{ category: :debuffs, effects: [] }]
    end

    it 'decodes the entities of a name with the given unescape' do
      decoded = described_class.new(event_bus: event_bus, pending_render: pending_render, clock: clock,
                                    unescape: ->(text) { text.gsub('&apos;', "'").gsub('&amp;', '&') })
      decoded.start_dialog(:buffs)
      decoded.add_effect(bar('1', 'Fasthr&apos;s &amp; Co'))
      decoded.end_dialog

      expect(events.first[:effects].first[:name]).to eq "Fasthr's & Co"
    end
  end

  describe 'blocks' do
    it 'commits nothing until the block ends' do
      tracker.start_dialog(:buffs)
      tracker.add_effect(bar('1', 'Blink'))

      expect([events, tracker.open?]).to eq [[], true]
    end

    it 'ignores an effect added with no block open' do
      tracker.add_effect(bar('1', 'Blink'))
      tracker.end_dialog

      expect(events).to be_empty
    end

    it 'commits a block still open when the next one starts' do
      tracker.start_dialog(:buffs)
      tracker.add_effect(bar('1', 'Blink'))
      tracker.start_dialog(:spells)

      expect(events.map { |e| e[:category] }).to eq [:buffs]
    end

    it 'does not emit for a clear block that the full block follows' do
      tracker.start_dialog(:buffs, clear: true)
      tracker.end_dialog
      commit(:buffs, bar('1', 'Blink'))
      tracker.finalize

      expect(events.map { |e| e[:effects].size }).to eq [1]
    end

    it 'commits a clear block that nothing followed, empty, at finalize' do
      commit(:buffs, bar('1', 'Blink'))
      tracker.start_dialog(:buffs, clear: true)
      tracker.end_dialog
      tracker.finalize

      expect(events.map { |e| e[:effects].size }).to eq [1, 0]
    end
  end

  describe '#finalize' do
    it 'commits a block left open' do
      tracker.start_dialog(:buffs)
      tracker.add_effect(bar('1', 'Blink'))
      tracker.finalize

      expect([events.size, tracker.open?]).to eq [1, false]
    end

    it 'does nothing when nothing is open' do
      tracker.finalize

      expect(events).to be_empty
    end
  end

  describe '#reset' do
    it 'drops the open block without emitting' do
      tracker.start_dialog(:buffs)
      tracker.reset
      tracker.finalize

      expect(events).to be_empty
    end
  end

  describe 'custom timers (ProfanityCustom)' do
    def custom(*bars, clear: false)
      tracker.start_dialog(:custom, clear: clear)
      bars.each { |attrs| tracker.add_effect(attrs) }
      tracker.end_dialog
    end

    def timer(id, text = nil, time: nil, **rest)
      { 'id' => id, 'text' => text, 'time' => time }.merge(rest.transform_keys(&:to_s)).compact
    end

    def last_ids
      events.last[:effects].map { |e| e[:id] }
    end

    it 'emits a timer with its end_time from the time left, a full bar and its name' do
      custom(timer('t1', 'My Timer', time: '00:05:00'))

      expect(events).to eq [{ category: :custom,
                              effects: [{ id: 't1', name: 'My Timer', percent: 100, end_time: 1_000_300.0 }] }]
    end

    it 'names a timer by its id when it has no text' do
      custom(timer('t1', time: '00:01:00'), timer('t2', '  ', time: '00:01:00'))

      expect(events.last[:effects].map { |e| e[:name] }).to eq %w[t1 t2]
    end

    it 'takes a percent from value, 100 when it is missing or unreadable, and keeps it within 0 to 100' do
      custom(timer('a', time: '00:01:00', value: '40'), timer('b', value: 'x'), timer('c', value: '900'), timer('d'))

      expect(events.last[:effects].map { |e| e[:percent] }).to eq [40, 100, 100, 100]
    end

    it 'makes a timer without a readable time indefinite' do
      custom(timer('a'), timer('b', time: 'Indefinite'), timer('c', time: '5 minutes'))

      expect(events.last[:effects].map { |e| e[:end_time] }).to eq [nil, nil, nil]
    end

    it 'uses an end_time attribute (server epoch seconds) over the time' do
      custom(timer('a', time: '00:01:00', end_time: '1000500.5'), timer('b', end_time: 'soon', time: '00:00:10'))

      expect(events.last[:effects].map { |e| e[:end_time] }).to eq [1_000_500.5, 1_000_010.0]
    end

    it 'adds the time left to the server time now, which the clock offset moves' do
      clock.server_time_offset = 10.0
      custom(timer('a', time: '00:00:20'))

      expect(events.last[:effects].first[:end_time]).to eq 1_000_010.0
    end

    it 'decodes the entities of a name with the given unescape' do
      decoded = described_class.new(event_bus: event_bus, pending_render: pending_render, clock: clock,
                                    unescape: ->(text) { text.gsub('&apos;', "'") })
      decoded.start_dialog(:custom)
      decoded.add_effect(timer('a', 'Fasthr&apos;s'))
      decoded.end_dialog

      expect(events.last[:effects].first[:name]).to eq "Fasthr's"
    end

    it 'drops a bar without an id' do
      custom(timer(nil, 'Nameless', time: '00:01:00'), timer('a', time: '00:01:00'))

      expect(last_ids).to eq %w[a]
    end

    it 'asks for a screen update' do
      expect { custom(timer('a', time: '00:01:00')) }.to change { pending_render.update_requested? }.from(false).to(true)
    end

    describe 'sticking' do
      it 'keeps a timer when a later block adds another' do
        custom(timer('a', 'A', time: '00:10:00'))
        custom(timer('b', 'B', time: '00:10:00'))

        expect(events.map { |e| e[:effects].map { |x| x[:id] } }).to eq [%w[a], %w[a b]]
      end

      it 'updates a timer that exists by its id, in place, without dropping the others' do
        custom(timer('a', 'A', time: '00:10:00'), timer('b', 'B', time: '00:10:00'), timer('c', 'C', time: '00:10:00'))
        custom(timer('a', 'A renamed', time: '00:20:00', value: '30'))

        expect(events.last[:effects]).to eq [
          { id: 'a', name: 'A renamed', percent: 30, end_time: 1_001_200.0 },
          { id: 'b', name: 'B', percent: 100, end_time: 1_000_600.0 },
          { id: 'c', name: 'C', percent: 100, end_time: 1_000_600.0 }
        ]
      end

      it 'keeps the order the timers were first added in across re-upserts' do
        custom(timer('z', time: '00:10:00'), timer('m', time: '00:10:00'))
        custom(timer('a', time: '00:10:00'))
        custom(timer('z', time: '00:09:00'), timer('a', time: '00:09:00'))

        expect(last_ids).to eq %w[z m a]
      end

      it 'upserts a timer repeated within one block once' do
        custom(timer('a', time: '00:10:00'), timer('a', 'Again', time: '00:05:00'))

        expect(events.last[:effects]).to eq [{ id: 'a', name: 'Again', percent: 100, end_time: 1_000_300.0 }]
      end

      it 'keeps an indefinite timer through later blocks' do
        custom(timer('forever', 'Forever'))
        custom(timer('b', time: '00:00:10'))

        expect(last_ids).to eq %w[forever b]
      end

      it 'does not touch the game categories, nor they the custom timers' do
        custom(timer('a', time: '00:10:00'))
        commit(:buffs, bar('1', 'Blink'))
        commit(:buffs)

        expect([tracker.effects(:custom).map { |e| e[:id] }, tracker.effects(:buffs)]).to eq [%w[a], []]
      end

      it 'returns the sticky list from #effects' do
        custom(timer('a', time: '00:10:00'), timer('b'))

        expect(tracker.effects(:custom).map { |e| e[:id] }).to eq %w[a b]
      end

      it 'commits an empty block as the unchanged list' do
        custom(timer('a', time: '00:10:00'))
        custom

        expect(events.last[:effects].map { |e| e[:id] }).to eq %w[a]
      end
    end

    describe 'expiry' do
      it 'drops a timer whose end time has passed when the next block is committed' do
        custom(timer('short', time: '00:00:05'), timer('long', time: '00:10:00'))
        now[0] = 1_000_010
        custom(timer('c', time: '00:10:00'))

        expect(last_ids).to eq %w[long c]
      end

      it 'drops a timer that arrives with no time left' do
        custom(timer('a', time: '00:00:00'), timer('b', time: '00:00:30'))

        expect(last_ids).to eq %w[b]
      end

      it 'does not drop an indefinite timer' do
        custom(timer('a'))
        now[0] = 2_000_000
        custom(timer('b'))

        expect(last_ids).to eq %w[a b]
      end
    end

    describe 'clearing' do
      it 'removes one timer with clear=t on its bar, leaving the others' do
        custom(timer('a', time: '00:10:00'), timer('b', time: '00:10:00'))
        custom({ 'id' => 'a', 'clear' => 't' })

        expect(last_ids).to eq %w[b]
      end

      it 'ignores a per-timer clear of a timer that does not exist, but still emits' do
        custom(timer('a', time: '00:10:00'))
        custom({ 'id' => 'nope', 'clear' => 't' })

        expect([last_ids, events.size]).to eq [%w[a], 2]
      end

      it 'lets a timer be added again after it was removed, at the end' do
        custom(timer('a', time: '00:10:00'), timer('b', time: '00:10:00'))
        custom({ 'id' => 'a', 'clear' => 't' })
        custom(timer('a', time: '00:10:00'))

        expect(last_ids).to eq %w[b a]
      end

      it 'applies the bars of a block in order' do
        custom(timer('a', time: '00:10:00'), { 'id' => 'a', 'clear' => 't' }, timer('b', time: '00:10:00'))

        expect(last_ids).to eq %w[b]
      end

      it 'removes every timer with a clear block, and emits the empty list at once' do
        custom(timer('a', time: '00:10:00'), timer('b'))
        custom(clear: true)

        expect([events.last, tracker.effects(:custom)]).to eq [{ category: :custom, effects: [] }, []]
      end

      it 'emits the empty list for a clear block even when nothing was set, and for it alone' do
        custom(clear: true)
        tracker.finalize

        expect(events).to eq [{ category: :custom, effects: [] }]
      end

      it 'clears first and then adds the bars of a clear block that has some' do
        custom(timer('old', time: '00:10:00'))
        custom(timer('new', time: '00:10:00'), clear: true)

        expect(last_ids).to eq %w[new]
      end

      it 'keeps the timers when the same ids come back after a clear block' do
        custom(timer('a', time: '00:10:00'))
        custom(clear: true)
        custom(timer('a', time: '00:10:00'))

        expect(last_ids).to eq %w[a]
      end
    end

    describe 'open blocks' do
      it 'commits nothing until the block ends' do
        tracker.start_dialog(:custom)
        tracker.add_effect(timer('a', time: '00:10:00'))

        expect([events, tracker.open?]).to eq [[], true]
      end

      it 'commits a custom block left open at #finalize' do
        tracker.start_dialog(:custom)
        tracker.add_effect(timer('a', time: '00:10:00'))
        tracker.finalize

        expect([last_ids, tracker.open?]).to eq [%w[a], false]
      end

      it 'commits a custom clear block left open at #finalize' do
        custom(timer('a', time: '00:10:00'))
        tracker.start_dialog(:custom, clear: true)
        tracker.finalize

        expect(events.last).to eq({ category: :custom, effects: [] })
      end

      it 'commits a custom block still open when another block starts' do
        tracker.start_dialog(:custom)
        tracker.add_effect(timer('a', time: '00:10:00'))
        tracker.start_dialog(:buffs)

        expect(events.map { |e| e[:category] }).to eq [:custom]
      end

      it 'drops an open custom block on #reset but keeps the timers it already has' do
        custom(timer('a', time: '00:10:00'))
        tracker.start_dialog(:custom)
        tracker.add_effect(timer('b', time: '00:10:00'))
        tracker.reset
        tracker.finalize

        expect([events.size, tracker.effects(:custom).map { |e| e[:id] }]).to eq [1, %w[a]]
      end
    end
  end
end
