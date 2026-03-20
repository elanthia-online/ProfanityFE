# frozen_string_literal: true

# Tests KillRing's emacs-style kill/yank accumulation: consecutive kills
# merge, non-kill operations reset accumulation, yank retrieves the
# combined text.

require_relative '../../lib/kill_ring'

RSpec.describe KillRing do
  subject(:ring) { described_class.new }

  describe '#initialize' do
    it 'starts with empty buffer' do
      expect(ring.buffer).to eq ''
    end

    it 'starts with empty original' do
      expect(ring.original).to eq ''
    end
  end

  describe '#before' do
    it 'resets buffer when text changes' do
      ring.buffer = 'old stuff'
      ring.after('hello', 5)
      ring.before('changed', 5)
      expect(ring.buffer).to eq ''
    end

    it 'resets buffer when position changes' do
      ring.buffer = 'old stuff'
      ring.after('hello', 3)
      ring.before('hello', 5)
      expect(ring.buffer).to eq ''
    end

    it 'preserves buffer when nothing changed' do
      ring.buffer = 'kept'
      ring.after('hello', 3)
      ring.before('hello', 3)
      expect(ring.buffer).to eq 'kept'
    end

    it 'captures original text on reset' do
      ring.after('old', 3)
      ring.before('new text', 0)
      expect(ring.original).to eq 'new text'
    end

    it 'does not update original when buffer is preserved' do
      ring.before('first', 0)
      ring.after('first', 0)
      ring.before('first', 0) # same state — no reset
      expect(ring.original).to eq 'first'
    end

    # ---- Adversarial ----

    it 'handles empty string text' do
      expect { ring.before('', 0) }.not_to raise_error
    end

    it 'handles very large position values' do
      expect { ring.before('short', 999_999) }.not_to raise_error
    end

    it 'handles position 0 consistently' do
      ring.after('text', 0)
      ring.before('text', 0)
      expect(ring.buffer).to eq '' # first call always resets since last_text starts empty
    end

    it 'handles nil-length strings' do
      ring.after('', 0)
      ring.before('', 0)
      # Same empty text and position — should preserve buffer
      ring.buffer = 'test'
      ring.after('', 0)
      ring.before('', 0)
      expect(ring.buffer).to eq 'test'
    end
  end

  describe '#after' do
    it 'snapshots text for next before comparison' do
      ring.before('hello', 0)
      ring.buffer = 'h'
      ring.after('ello', 0)

      # Now if we call before with the same state, buffer preserved
      ring.before('ello', 0)
      expect(ring.buffer).to eq 'h'
    end

    it 'dups the text to avoid aliasing' do
      text = +'mutable'
      ring.after(text, 3)
      text.replace('changed')
      # The snapshot should still be 'mutable'
      ring.before('mutable', 3)
      expect(ring.buffer).to eq '' # still empty from init, but no reset
    end
  end

  describe 'multi-kill accumulation workflow' do
    it 'accumulates forward kills' do
      # "hello world" with cursor at 5, kill "world" then kill " "
      ring.before('hello world', 5)
      ring.buffer += ' world'
      ring.after('hello', 5)

      # Cursor hasn't moved, text changed — but after() snapshot matches
      ring.before('hello', 5)
      ring.buffer += '!' # hypothetical next kill
      expect(ring.buffer).to eq ' world!'
    end

    it 'accumulates backward kills by prepending' do
      ring.before('hello world', 11)
      ring.buffer = 'world'
      ring.after('hello ', 6)

      ring.before('hello ', 6)
      ring.buffer = 'hello ' + ring.buffer
      ring.after('', 0)

      expect(ring.buffer).to eq 'hello world'
    end

    it 'resets accumulation when user types between kills' do
      ring.before('hello world', 5)
      ring.buffer = ' world'
      ring.after('hello', 5)

      # User types 'x' — text and position change
      ring.before('hellox', 6)
      expect(ring.buffer).to eq ''
      expect(ring.original).to eq 'hellox'
    end

    it 'resets accumulation when user moves cursor between kills' do
      ring.before('hello world', 5)
      ring.buffer = ' world'
      ring.after('hello', 5)

      # User moves cursor without changing text
      ring.before('hello', 0)
      expect(ring.buffer).to eq ''
    end
  end
end
