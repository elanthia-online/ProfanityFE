# frozen_string_literal: true

# Tests EventBus pub/sub: on/emit delivery, off removal, clear, subscriber
# counting, and adversarial edge cases (no subscribers, mutation, exceptions,
# reentrant emit, symbol vs string types).

require_relative '../../lib/event_bus'

RSpec.describe EventBus do
  subject(:bus) { described_class.new }

  describe '#on / #emit' do
    it 'delivers event data to a subscriber' do
      received = nil
      bus.on(:test) { |data| received = data }
      bus.emit(:test, key: 'value')

      expect(received).to eq(key: 'value')
    end

    it 'delivers to multiple subscribers in order' do
      calls = []
      bus.on(:test) { |_| calls << :first }
      bus.on(:test) { |_| calls << :second }
      bus.emit(:test)

      expect(calls).to eq %i[first second]
    end

    it 'does not cross-deliver between event types' do
      received = nil
      bus.on(:alpha) { |data| received = data }
      bus.emit(:beta, key: 'value')

      expect(received).to be_nil
    end

    it 'passes empty hash when no keywords given' do
      received = nil
      bus.on(:test) { |data| received = data }
      bus.emit(:test)

      expect(received).to eq({})
    end

    it 'returns self from on for chaining' do
      result = bus.on(:test) { |_| nil }
      expect(result).to equal(bus)
    end
  end

  describe '#off' do
    it 'removes a specific handler' do
      calls = []
      handler = proc { |_| calls << :hit }
      bus.on(:test, &handler)
      bus.off(:test, handler)
      bus.emit(:test)

      expect(calls).to be_empty
    end

    it 'removes all handlers for an event type when no handler given' do
      calls = []
      bus.on(:test) { |_| calls << :a }
      bus.on(:test) { |_| calls << :b }
      bus.off(:test)
      bus.emit(:test)

      expect(calls).to be_empty
    end

    it 'does not affect other event types' do
      called = false
      bus.on(:keep) { |_| called = true }
      bus.on(:remove) { |_| nil }
      bus.off(:remove)
      bus.emit(:keep)

      expect(called).to be true
    end
  end

  describe '#clear' do
    it 'removes all subscribers for all event types' do
      calls = []
      bus.on(:alpha) { |_| calls << :a }
      bus.on(:beta) { |_| calls << :b }
      bus.clear
      bus.emit(:alpha)
      bus.emit(:beta)

      expect(calls).to be_empty
    end
  end

  describe '#subscriber_count' do
    it 'returns count for a specific event type' do
      bus.on(:test) { |_| nil }
      bus.on(:test) { |_| nil }
      bus.on(:other) { |_| nil }

      expect(bus.subscriber_count(:test)).to eq 2
      expect(bus.subscriber_count(:other)).to eq 1
    end

    it 'returns total count when no event type given' do
      bus.on(:alpha) { |_| nil }
      bus.on(:beta) { |_| nil }

      expect(bus.subscriber_count).to eq 2
    end

    it 'returns 0 for unsubscribed event types' do
      expect(bus.subscriber_count(:nonexistent)).to eq 0
    end
  end

  # ---- Adversarial edge cases ----

  describe 'adversarial: emit with no subscribers' do
    it 'does not raise when emitting to an event with no subscribers' do
      expect { bus.emit(:nobody_listening, data: 123) }.not_to raise_error
    end
  end

  describe 'adversarial: subscriber modifies data' do
    it 'does not affect other subscribers when one mutates data' do
      received = []
      bus.on(:test) { |data| data[:key] = 'mutated'; received << data[:key] }
      bus.on(:test) { |data| received << data[:key] }
      bus.emit(:test, key: 'original')

      # Both see 'mutated' because they share the same hash — this is
      # expected for a synchronous bus (no defensive copying)
      expect(received).to eq %w[mutated mutated]
    end
  end

  describe 'adversarial: subscriber raises' do
    it 'propagates exceptions (no swallowing)' do
      bus.on(:test) { |_| raise 'boom' }

      expect { bus.emit(:test) }.to raise_error(RuntimeError, 'boom')
    end
  end

  describe 'adversarial: adding subscriber during emit' do
    it 'does not call the newly added subscriber in the current emit' do
      calls = []
      bus.on(:test) do |_|
        calls << :original
        bus.on(:test) { |_| calls << :new }
      end
      bus.emit(:test)
      expect(calls).to eq %i[original]

      bus.emit(:test)
      expect(calls).to eq %i[original original new]
    end
  end

  describe 'adversarial: off during emit' do
    it 'does not crash when removing a handler during emit' do
      handler = proc { |_| bus.off(:test, handler) }
      bus.on(:test, &handler)

      expect { bus.emit(:test) }.not_to raise_error
    end

    it 'still calls the next handler when an earlier one removes itself' do
      calls = []
      first = proc { |_| calls << :first; bus.off(:test, first) }
      bus.on(:test, &first)
      bus.on(:test) { |_| calls << :second }

      bus.emit(:test)

      expect(calls).to eq %i[first second]
    end
  end

  describe 'adversarial: reentrant emit' do
    it 'handles emit called from within a handler' do
      calls = []
      bus.on(:outer) do |_|
        calls << :outer
        bus.emit(:inner)
      end
      bus.on(:inner) { |_| calls << :inner }
      bus.emit(:outer)

      expect(calls).to eq %i[outer inner]
    end
  end

  describe 'adversarial: symbol vs string event types' do
    it 'treats symbols and strings as different event types' do
      sym_called = false
      str_called = false
      bus.on(:test) { |_| sym_called = true }
      bus.on('test') { |_| str_called = true }
      bus.emit(:test)

      expect(sym_called).to be true
      expect(str_called).to be false
    end
  end
end
