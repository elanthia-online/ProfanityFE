# frozen_string_literal: true

# Tests StreamStack: the stack of enclosing streams suspended while nested
# game-output streams are active. Covers push/pop LIFO ordering, the nil
# "main window" entry, peek/depth/empty?/reset, and the adversarial cases
# that matter for stream routing (unmatched pop, deep nesting, repeated
# reset), plus an end-to-end mirror of the moon-window leak scenario.

require_relative '../../lib/stream_stack'

RSpec.describe StreamStack do
  subject(:stack) { described_class.new }

  describe 'a freshly created stack' do
    it 'is empty' do
      expect(stack.empty?).to be true
    end

    it 'has zero depth' do
      expect(stack.depth).to eq 0
    end

    it 'peeks nil' do
      expect(stack.peek).to be_nil
    end

    it 'pops nil without raising' do
      expect(stack.pop).to be_nil
    end
  end

  describe '#push' do
    it 'returns the stream it suspended' do
      expect(stack.push('thoughts')).to eq 'thoughts'
    end

    it 'increases the depth by one' do
      expect { stack.push('thoughts') }.to change(stack, :depth).from(0).to(1)
    end

    it 'makes the pushed stream the next one to resume' do
      stack.push('thoughts')
      expect(stack.peek).to eq 'thoughts'
    end

    it 'accepts nil to represent the main window' do
      stack.push(nil)
      expect(stack.depth).to eq 1
      expect(stack.peek).to be_nil
    end
  end

  describe '#pop' do
    it 'returns the most recently suspended stream' do
      stack.push('thoughts')
      expect(stack.pop).to eq 'thoughts'
    end

    it 'removes the stream so it is not resumed twice' do
      stack.push('thoughts')
      stack.pop
      expect(stack.empty?).to be true
    end

    it 'resumes suspended streams in last-in-first-out order' do
      stack.push('speech')
      stack.push('room')
      expect(stack.pop).to eq 'room'
      expect(stack.pop).to eq 'speech'
    end

    it 'resumes the main window (nil) for a stream that was opened from main' do
      stack.push(nil) # a stream opened while nothing else was active
      expect(stack.pop).to be_nil
    end
  end

  describe '#peek' do
    it 'reports the next stream to resume without removing it' do
      stack.push('familiar')
      expect(stack.peek).to eq 'familiar'
      expect(stack.depth).to eq 1
    end
  end

  describe '#reset' do
    it 'discards every suspended stream' do
      stack.push('speech')
      stack.push('room')
      stack.reset
      expect(stack.empty?).to be true
      expect(stack.peek).to be_nil
    end
  end

  # ==================================================================
  # Adversarial edge cases
  # ==================================================================

  describe 'adversarial: underflow' do
    it 'keeps returning nil when popped past empty' do
      stack.push('thoughts')
      expect(stack.pop).to eq 'thoughts'
      expect(stack.pop).to be_nil
      expect(stack.pop).to be_nil
      expect(stack.depth).to eq 0
    end
  end

  describe 'adversarial: deep nesting' do
    it 'unwinds a deep stack in exact reverse order' do
      ids = %w[a b c d e f g h]
      ids.each { |id| stack.push(id) }
      expect(stack.depth).to eq ids.length
      expect(ids.length.times.map { stack.pop }).to eq ids.reverse
      expect(stack.empty?).to be true
    end
  end

  describe 'adversarial: repeated reset' do
    it 'is idempotent and safe on an already-empty stack' do
      stack.reset
      expect { stack.reset }.not_to raise_error
      expect(stack.empty?).to be true
    end
  end

  describe 'the moon-window leak scenario' do
    # Mirrors what happens when moonwatch (an async script) repaints the moon
    # window while the game has a familiar stream open: the injected stream
    # must close back to 'familiar', never to the main window.
    it 'restores the active game stream after an injected side stream closes' do
      active = 'familiar'         # game stream currently active
      stack.push(active)          # async side stream opens, suspending 'familiar'
      active = 'moonWindow'       # the injected moon-window stream is now active
      expect(active).to eq 'moonWindow'
      active = stack.pop          # the side stream closes
      expect(active).to eq 'familiar'
      expect(stack.empty?).to be true
    end
  end
end
