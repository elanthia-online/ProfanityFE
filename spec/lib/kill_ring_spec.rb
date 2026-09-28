# frozen_string_literal: true

# Tests KillRing's readline-style accumulation: kills between #before and
# #after share one buffer until #end_sequence, and a new sequence starts
# a fresh buffer and captures the original text.

require_relative '../../lib/kill_ring'

RSpec.describe KillRing do
  subject(:ring) { described_class.new }

  # One kill as CommandBuffer performs it: before, mutate, after.
  def kill(text, &mutate)
    ring.before(text)
    mutate.call
    ring.after
  end

  describe '#initialize' do
    it 'starts with empty buffer' do
      expect(ring.buffer).to eq ''
    end

    it 'starts with empty original' do
      expect(ring.original).to eq ''
    end
  end

  describe '#before' do
    it 'starts a new buffer on the first kill' do
      ring.buffer = 'stale'
      ring.before('hello')
      expect(ring.buffer).to eq ''
    end

    it 'captures the text at the start of the sequence as original' do
      ring.before('hello world')
      expect(ring.original).to eq 'hello world'
    end

    it 'keeps the buffer and original when the previous command was a kill' do
      kill('hello world') { ring.buffer += ' world' }
      ring.before('hello')
      expect(ring.buffer).to eq ' world'
      expect(ring.original).to eq 'hello world'
    end

    it 'copies the original so later edits to the text do not change it' do
      text = +'hello'
      ring.before(text)
      text << ' world'
      expect(ring.original).to eq 'hello'
    end
  end

  describe '#end_sequence' do
    it 'makes the next kill start a new buffer' do
      kill('hello world') { ring.buffer += ' world' }
      ring.end_sequence
      ring.before('hello')
      expect(ring.buffer).to eq ''
      expect(ring.original).to eq 'hello'
    end

    it 'keeps the buffer for yanking until the next kill' do
      kill('hello world') { ring.buffer += ' world' }
      ring.end_sequence
      expect(ring.buffer).to eq ' world'
    end
  end

  describe 'multi-kill accumulation workflow' do
    it 'appends forward kills' do
      kill('hello big world') { ring.buffer += ' big' }
      kill('hello world') { ring.buffer += ' world' }
      expect(ring.buffer).to eq ' big world'
    end

    it 'prepends backward kills' do
      kill('hello world') { ring.buffer = 'world' + ring.buffer }
      kill('hello ') { ring.buffer = 'hello ' + ring.buffer }
      expect(ring.buffer).to eq 'hello world'
    end

    it 'does not join kills separated by another command' do
      kill('one two') { ring.buffer = 'two' + ring.buffer }
      ring.end_sequence
      kill('one ') { ring.buffer = 'one ' + ring.buffer }
      expect(ring.buffer).to eq 'one '
    end
  end
end
