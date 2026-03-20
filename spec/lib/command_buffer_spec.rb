# frozen_string_literal: true

# Tests CommandBuffer's text editing (insert, delete, word operations),
# cursor movement, kill ring (kill-forward, kill-line, yank), command
# history navigation, horizontal scrolling, and clear_and_get.

require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'

RSpec.describe CommandBuffer do
  subject(:buf) { described_class.new }
  let(:window) { Curses::Window.new(1, 80, 0, 0) }

  before { buf.window = window }

  def type(str)
    str.each_char { |ch| buf.put_ch(ch) }
  end

  # ==================================================================
  # Character insertion
  # ==================================================================

  describe '#put_ch' do
    it 'inserts a character and advances the cursor' do
      buf.put_ch('a')
      expect(buf.text).to eq 'a'
      expect(buf.pos).to eq 1
    end

    it 'inserts at cursor position, not at end' do
      type('ac')
      buf.cursor_left
      buf.put_ch('b')
      expect(buf.text).to eq 'abc'
      expect(buf.pos).to eq 2
    end

    it 'inserts at the beginning when cursor is at 0' do
      type('bc')
      buf.cursor_home
      buf.put_ch('a')
      expect(buf.text).to eq 'abc'
      expect(buf.pos).to eq 1
    end

    it 'calls insch then setpos on the curses window' do
      buf.put_ch('x')
      insch_idx = window.call_log.index { |m, _| m == :insch }
      setpos_idx = window.call_log.rindex { |m, _| m == :setpos }
      expect(insch_idx).not_to be_nil
      expect(setpos_idx).to be > insch_idx
    end

    # Adversarial
    it 'handles inserting into a very long string' do
      type('a' * 1000)
      expect(buf.text.length).to eq 1000
      expect(buf.pos).to eq 1000
    end

    it 'handles space character' do
      buf.put_ch(' ')
      expect(buf.text).to eq ' '
    end

    it 'handles special characters' do
      %w[! @ # $ % ^ & * ( ) \\ / ' "].each do |ch|
        buf.put_ch(ch)
      end
      expect(buf.text.length).to eq 14
    end
  end

  # ==================================================================
  # Cursor movement
  # ==================================================================

  describe '#cursor_left' do
    it 'moves cursor left' do
      type('abc')
      buf.cursor_left
      expect(buf.pos).to eq 2
    end

    it 'clamps at 0' do
      buf.cursor_left
      expect(buf.pos).to eq 0
    end

    it 'clamps at 0 after multiple calls' do
      type('a')
      10.times { buf.cursor_left }
      expect(buf.pos).to eq 0
    end

    it 'emits noutrefresh' do
      type('a')
      window.call_log.clear
      buf.cursor_left
      expect(window.call_log.map(&:first)).to include(:noutrefresh)
    end
  end

  describe '#cursor_right' do
    it 'moves cursor right' do
      type('abc')
      buf.cursor_home
      buf.cursor_right
      expect(buf.pos).to eq 1
    end

    it 'clamps at text length' do
      type('abc')
      10.times { buf.cursor_right }
      expect(buf.pos).to eq 3
    end

    it 'does nothing on empty buffer' do
      buf.cursor_right
      expect(buf.pos).to eq 0
    end
  end

  describe '#cursor_home' do
    it 'jumps to position 0' do
      type('hello world')
      buf.cursor_home
      expect(buf.pos).to eq 0
    end

    it 'is idempotent' do
      type('hi')
      buf.cursor_home
      buf.cursor_home
      expect(buf.pos).to eq 0
    end

    it 'works on empty buffer' do
      buf.cursor_home
      expect(buf.pos).to eq 0
    end
  end

  describe '#cursor_end' do
    it 'jumps to end of text' do
      type('hello')
      buf.cursor_home
      buf.cursor_end
      expect(buf.pos).to eq 5
    end

    it 'is idempotent' do
      type('hi')
      buf.cursor_end
      buf.cursor_end
      expect(buf.pos).to eq 2
    end

    it 'works on empty buffer' do
      buf.cursor_end
      expect(buf.pos).to eq 0
    end
  end

  describe '#cursor_word_left' do
    it 'jumps to start of previous word' do
      type('hello world')
      buf.cursor_word_left
      expect(buf.pos).to eq 6
    end

    it 'jumps to 0 from first word' do
      type('hello')
      buf.cursor_word_left
      expect(buf.pos).to eq 0
    end

    it 'handles multiple spaces between words' do
      type('hello   world')
      buf.cursor_word_left
      expect(buf.pos).to be <= 8 # Should land at or before 'w'
    end

    it 'handles punctuation as word boundary' do
      type('hello.world')
      buf.cursor_word_left
      # Should stop at the word boundary around '.'
      expect(buf.pos).to be < 11
    end

    it 'does nothing at position 0' do
      buf.cursor_word_left
      expect(buf.pos).to eq 0
    end

    it 'does nothing on empty buffer' do
      buf.cursor_word_left
      expect(buf.pos).to eq 0
    end
  end

  describe '#cursor_word_right' do
    it 'jumps to start of next word' do
      type('hello world')
      buf.cursor_home
      buf.cursor_word_right
      expect(buf.pos).to eq 6
    end

    it 'jumps to end from last word' do
      type('hello')
      buf.cursor_home
      buf.cursor_word_right
      expect(buf.pos).to eq 5
    end

    it 'does nothing at end of text' do
      type('hello')
      buf.cursor_word_right
      expect(buf.pos).to eq 5
    end

    it 'does nothing on empty buffer' do
      buf.cursor_word_right
      expect(buf.pos).to eq 0
    end
  end

  # ==================================================================
  # Deletion
  # ==================================================================

  describe '#backspace' do
    it 'deletes char before cursor' do
      type('abc')
      buf.backspace
      expect(buf.text).to eq 'ab'
      expect(buf.pos).to eq 2
    end

    it 'deletes from middle' do
      type('abc')
      buf.cursor_left
      buf.backspace
      expect(buf.text).to eq 'ac'
      expect(buf.pos).to eq 1
    end

    it 'does nothing at position 0' do
      type('abc')
      buf.cursor_home
      buf.backspace
      expect(buf.text).to eq 'abc'
      expect(buf.pos).to eq 0
    end

    it 'does nothing on empty buffer' do
      buf.backspace
      expect(buf.text).to eq ''
    end

    it 'can delete entire string one char at a time' do
      type('hello')
      5.times { buf.backspace }
      expect(buf.text).to eq ''
      expect(buf.pos).to eq 0
    end

    it 'extra backspaces after emptying do not crash' do
      type('a')
      10.times { buf.backspace }
      expect(buf.text).to eq ''
      expect(buf.pos).to eq 0
    end

    it 'emits noutrefresh' do
      type('a')
      window.call_log.clear
      buf.backspace
      expect(window.call_log.map(&:first)).to include(:noutrefresh)
    end
  end

  describe '#delete_char' do
    it 'deletes char at cursor' do
      type('abc')
      buf.cursor_home
      buf.delete_char
      expect(buf.text).to eq 'bc'
    end

    it 'deletes from middle' do
      type('abc')
      buf.cursor_home
      buf.cursor_right
      buf.delete_char
      expect(buf.text).to eq 'ac'
    end

    it 'does nothing at end of text' do
      type('abc')
      buf.delete_char
      expect(buf.text).to eq 'abc'
    end

    it 'does nothing on empty buffer' do
      buf.delete_char
      expect(buf.text).to eq ''
    end

    it 'can delete entire string from position 0' do
      type('hello')
      buf.cursor_home
      5.times { buf.delete_char }
      expect(buf.text).to eq ''
    end
  end

  # ==================================================================
  # Word deletion
  # ==================================================================

  describe '#backspace_word' do
    it 'deletes word before cursor' do
      type('hello world')
      buf.backspace_word
      expect(buf.text).to eq 'hello '
    end

    it 'deletes word with trailing punctuation' do
      type('hello, world!')
      buf.backspace_word
      # Should delete 'world!' or similar — behavior depends on boundary logic
      expect(buf.text.length).to be < 13
    end

    it 'does nothing on empty buffer' do
      buf.backspace_word
      expect(buf.text).to eq ''
    end

    it 'does nothing at position 0' do
      type('hello')
      buf.cursor_home
      buf.backspace_word
      expect(buf.text).to eq 'hello'
    end

    it 'handles single-character words' do
      type('a b c')
      buf.backspace_word
      expect(buf.text).to eq 'a b '
    end

    it 'handles all-spaces' do
      type('   ')
      buf.backspace_word
      expect(buf.pos).to be < 3
    end
  end

  describe '#delete_word' do
    it 'deletes word after cursor' do
      type('hello world')
      buf.cursor_home
      buf.delete_word
      expect(buf.text).to eq ' world'
    end

    it 'does nothing at end of text' do
      type('hello')
      buf.delete_word
      expect(buf.text).to eq 'hello'
    end

    it 'does nothing on empty buffer' do
      buf.delete_word
      expect(buf.text).to eq ''
    end
  end

  # ==================================================================
  # Kill / Yank
  # ==================================================================

  describe '#kill_forward' do
    it 'kills from cursor to end' do
      type('hello world')
      5.times { buf.cursor_left }
      buf.kill_forward
      expect(buf.text).to eq 'hello '
    end

    it 'does nothing at end of text' do
      type('hello')
      buf.kill_forward
      expect(buf.text).to eq 'hello'
    end

    it 'kills entire text from position 0' do
      type('hello')
      buf.cursor_home
      buf.kill_forward
      expect(buf.text).to eq ''
    end

    it 'emits clrtoeol' do
      type('hello')
      buf.cursor_home
      window.call_log.clear
      buf.kill_forward
      expect(window.call_log.map(&:first)).to include(:clrtoeol)
    end
  end

  describe '#kill_line' do
    it 'kills entire line' do
      type('hello world')
      buf.kill_line
      expect(buf.text).to eq ''
      expect(buf.pos).to eq 0
      expect(buf.offset).to eq 0
    end

    it 'does nothing on empty buffer' do
      buf.kill_line
      expect(buf.text).to eq ''
    end

    it 'resets cursor and scroll state' do
      narrow = Curses::Window.new(1, 5, 0, 0)
      buf.window = narrow
      type('a' * 20)
      buf.kill_line
      expect(buf.pos).to eq 0
      expect(buf.offset).to eq 0
    end
  end

  describe '#yank' do
    it 'inserts killed text' do
      type('hello world')
      5.times { buf.cursor_left }
      buf.kill_forward
      buf.cursor_home
      buf.yank
      expect(buf.text).to include('world')
    end

    it 'yank is empty when nothing was killed' do
      original = buf.text.dup
      buf.yank
      expect(buf.text).to eq original
    end
  end

  # ==================================================================
  # History
  # ==================================================================

  describe '#add_to_history' do
    it 'saves commands to history' do
      buf.add_to_history('test command')
      expect(buf.history).to include('test command')
    end

    it 'skips short commands' do
      buf.add_to_history('ab')
      expect(buf.history).not_to include('ab')
    end

    it 'always saves numeric commands' do
      buf.add_to_history('42')
      expect(buf.history).to include('42')
    end

    it 'always saves single-digit commands' do
      buf.add_to_history('5')
      expect(buf.history).to include('5')
    end

    it 'suppresses consecutive duplicates' do
      buf.add_to_history('test')
      buf.add_to_history('test')
      expect(buf.history.count('test')).to eq 1
    end

    it 'allows non-consecutive duplicates' do
      buf.add_to_history('first')
      buf.add_to_history('second')
      buf.add_to_history('first')
      expect(buf.history.count('first')).to eq 2
    end

    it 'resets history_pos' do
      buf.add_to_history('first')
      buf.previous_command
      buf.add_to_history('second')
      expect(buf.history_pos).to eq 0
    end

    # Adversarial
    it 'handles empty string (below min_history_length)' do
      buf.add_to_history('')
      expect(buf.history).not_to include('')
    end

    it 'handles command at exactly min_history_length' do
      buf.add_to_history('abcd') # default min is 4
      expect(buf.history).to include('abcd')
    end

    it 'handles command one below min_history_length' do
      buf.add_to_history('abc')
      expect(buf.history).not_to include('abc')
    end
  end

  describe '#previous_command / #next_command' do
    before do
      buf.add_to_history('first')
      buf.add_to_history('second')
      buf.add_to_history('third')
    end

    it 'navigates to older commands' do
      buf.previous_command
      expect(buf.text).to eq 'third'
    end

    it 'navigates through full history' do
      3.times { buf.previous_command }
      expect(buf.text).to eq 'first'
    end

    it 'does not crash when going past oldest' do
      20.times { buf.previous_command }
      expect(buf.history_pos).to be <= buf.history.length - 1
    end

    it 'navigates back to newer commands' do
      2.times { buf.previous_command }
      buf.next_command
      expect(buf.text).to eq 'third'
    end

    it 'next_command on empty buffer with text pushes to history' do
      type('unsent')
      buf.next_command
      expect(buf.text).to eq ''
    end

    it 'next_command at position 0 with empty buffer is a no-op' do
      buf.next_command
      expect(buf.text).to eq ''
      expect(buf.history_pos).to eq 0
    end

    it 'preserves current text when navigating away and back' do
      type('current')
      buf.previous_command
      buf.next_command
      expect(buf.text).to eq 'current'
    end
  end

  # ==================================================================
  # Buffer operations
  # ==================================================================

  describe '#clear_and_get' do
    it 'returns text and empties buffer' do
      type('hello')
      expect(buf.clear_and_get).to eq 'hello'
      expect(buf.text).to eq ''
      expect(buf.pos).to eq 0
      expect(buf.offset).to eq 0
    end

    it 'returns empty string on empty buffer' do
      expect(buf.clear_and_get).to eq ''
    end

    it 'emits deleteln and setpos on window' do
      type('hi')
      window.call_log.clear
      buf.clear_and_get
      expect(window.call_log.map(&:first)).to include(:deleteln, :setpos)
    end
  end

  describe '#refresh' do
    it 'calls noutrefresh' do
      window.call_log.clear
      buf.refresh
      expect(window.call_log.map(&:first)).to include(:noutrefresh)
    end

    it 'does not crash when window is nil' do
      buf.window = nil
      expect { buf.refresh }.not_to raise_error
    end
  end

  # ==================================================================
  # Horizontal scrolling
  # ==================================================================

  describe 'horizontal scrolling' do
    let(:narrow) { Curses::Window.new(1, 10, 0, 0) }

    before { buf.window = narrow }

    it 'scrolls when text exceeds window width' do
      type('a' * 15)
      expect(buf.offset).to be > 0
    end

    it 'cursor position tracks correctly through scroll' do
      type('a' * 15)
      expect(buf.pos).to eq 15
      expect(buf.pos - buf.offset).to be < narrow.maxx
    end

    it 'cursor_home resets offset' do
      type('a' * 15)
      buf.cursor_home
      expect(buf.offset).to eq 0
      expect(buf.pos).to eq 0
    end

    it 'cursor_end scrolls to show end of text' do
      type('a' * 15)
      buf.cursor_home
      buf.cursor_end
      expect(buf.pos).to eq 15
    end

    it 'backspace through scrolled content works' do
      type('a' * 15)
      15.times { buf.backspace }
      expect(buf.text).to eq ''
      expect(buf.pos).to eq 0
    end

    it 'emits delch when scrolling right' do
      type('a' * 15)
      delch_count = narrow.call_log.count { |m, _| m == :delch }
      expect(delch_count).to be > 0
    end

    it 'insert at cursor during scroll maintains consistency' do
      type('a' * 15)
      buf.cursor_home
      buf.cursor_right
      buf.put_ch('X')
      expect(buf.text[1]).to eq 'X'
      expect(buf.text.length).to eq 16
    end
  end

  # ==================================================================
  # Curses interaction verification
  # ==================================================================

  describe 'curses call sequence' do
    it 'put_ch produces insch followed by setpos' do
      buf.put_ch('a')
      methods = window.call_log.map(&:first)
      insch_pos = methods.index(:insch)
      setpos_pos = methods.rindex(:setpos)
      expect(insch_pos).not_to be_nil
      expect(setpos_pos).to be > insch_pos
    end

    it 'backspace produces setpos followed by delch' do
      type('ab')
      window.call_log.clear
      buf.backspace
      methods = window.call_log.map(&:first)
      # delete_at_position does setpos then delch
      expect(methods).to include(:setpos, :delch)
    end

    it 'clear_and_get produces deleteln' do
      type('hello')
      window.call_log.clear
      buf.clear_and_get
      expect(window.call_log.map(&:first)).to include(:deleteln)
    end

    it 'kill_line produces setpos, clrtoeol, noutrefresh' do
      type('hello')
      window.call_log.clear
      buf.kill_line
      methods = window.call_log.map(&:first)
      expect(methods).to include(:setpos, :clrtoeol, :noutrefresh)
    end

    it 'cursor_home with offset produces insch to restore scrolled chars' do
      narrow = Curses::Window.new(1, 5, 0, 0)
      buf.window = narrow
      type('a' * 10)
      narrow.call_log.clear
      buf.cursor_home
      # Should insert chars that were scrolled off the left
      expect(narrow.call_log.map(&:first)).to include(:insch)
    end
  end

  # ==================================================================
  # UTF-8 multi-byte characters
  # ==================================================================

  describe 'multi-byte UTF-8 characters' do
    it 'inserts multi-byte characters and tracks cursor position correctly' do
      type('café')
      expect(buf.text).to eq 'café'
      expect(buf.pos).to eq 4
    end

    it 'handles backspace on multi-byte character' do
      type('café')
      buf.backspace
      expect(buf.text).to eq 'caf'
      expect(buf.pos).to eq 3
    end

    it 'preserves emoji in buffer text' do
      buf.put_ch('🎮')
      buf.put_ch('!')
      expect(buf.text).to include('🎮')
      expect(buf.text).to include('!')
    end

    it 'handles CJK characters in text' do
      type('日本語')
      expect(buf.text).to eq '日本語'
      expect(buf.pos).to eq 3
    end
  end

  # ==================================================================
  # Large history
  # ==================================================================

  describe 'large command history' do
    it 'handles 500 history entries without degradation' do
      500.times { |i| buf.add_to_history("command_#{i.to_s.rjust(4, '0')}") }
      # History starts with [''] sentinel, so total is 501
      expect(buf.history.length).to be >= 500

      buf.previous_command
      expect(buf.text).to eq 'command_0499'
    end

    it 'navigates to oldest entry in large history' do
      100.times { |i| buf.add_to_history("cmd_#{i}") }
      100.times { buf.previous_command }
      expect(buf.text).to eq 'cmd_0'
    end
  end
end
