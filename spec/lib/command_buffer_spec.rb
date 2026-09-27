# frozen_string_literal: true

# Tests CommandBuffer's text editing (insert, delete, word operations),
# cursor movement, kill ring (kill-forward, kill-line, yank), command
# history navigation, horizontal scrolling, and clear_and_get.
#
# Screen assertions use ScreenLineWindow (spec/support), a one-row fake
# that models the visible cells and cursor column with ncurses semantics,
# so specs check what the user sees rather than which curses calls ran.

require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../support/screen_line_window'

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

    it 'shows the typed character with the cursor after it' do
      screen = ScreenLineWindow.new(10)
      buf.window = screen
      buf.put_ch('x')
      expect(screen.visible).to eq 'x'
      expect(screen.curx).to eq 1
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

  describe 'history size and consecutive duplicates' do
    let(:screen) { ScreenLineWindow.new(20) }

    before { buf.window = screen }

    # Press up-arrow +times+ times and return what the command line shows
    # after each press.
    def recall(times)
      Array.new(times) do
        buf.previous_command
        screen.visible
      end
    end

    it 'keeps the newest 1000 commands by default, dropping the oldest' do
      1005.times { |i| buf.add_to_history("cmd_#{i}") }

      shown = recall(1001)

      expect(shown.first).to eq 'cmd_1004'
      expect(shown[999]).to eq 'cmd_5'
      expect(shown.last).to eq 'cmd_5'
      expect(buf.history.length).to eq 1001 # 1000 commands plus the edit line
    end

    it 'follows the configured size' do
      CONFIG.history_size = 3
      %w[north south east west].each { |c| buf.add_to_history(c) }

      expect(recall(4)).to eq %w[west east south south]
    end

    it 'drops the oldest commands when the size is lowered' do
      %w[north south east west].each { |c| buf.add_to_history(c) }
      CONFIG.history_size = 2
      buf.add_to_history('look')

      expect(recall(3)).to eq %w[look west west]
    end

    it 'keeps no commands when the size is 0' do
      CONFIG.history_size = 0
      buf.add_to_history('north')

      buf.previous_command
      expect(screen.visible).to eq ''
    end

    it 'keeps every command when the size is larger than any array index' do
      CONFIG.history_size = 10**20
      %w[north south].each { |c| buf.add_to_history(c) }

      expect(recall(2)).to eq %w[south north]
    end

    it 'keeps text saved by down-arrow within the size' do
      CONFIG.history_size = 2
      %w[north south].each { |c| buf.add_to_history(c) }
      type('east')
      buf.next_command

      expect(recall(3)).to eq %w[east south south]
    end

    it 'does not add a command identical to the one before it' do
      %w[north look look].each { |c| buf.add_to_history(c) }

      expect(recall(3)).to eq %w[look north north]
    end

    it 'adds a command identical to an older, non-adjacent one' do
      %w[look north look].each { |c| buf.add_to_history(c) }

      expect(recall(3)).to eq %w[look north look]
    end

    it 'does not add a command identical to text left by up-arrow' do
      buf.add_to_history('north')
      type('look')
      buf.previous_command # stashes 'look', shows 'north'
      buf.kill_line
      type('look')
      buf.add_to_history(buf.clear_and_get)

      expect(recall(3)).to eq %w[look north north]
    end

    it 'does not add text left by up-arrow that repeats the command before it' do
      %w[south north].each { |c| buf.add_to_history(c) }
      type('north')
      buf.previous_command # stashes 'north', shows 'north'
      buf.kill_line
      type('look')
      buf.add_to_history(buf.clear_and_get)

      expect(recall(4)).to eq %w[look north south south]
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
      expect(buf.history[1]).to eq 'unsent'
      buf.previous_command
      expect(buf.text).to eq 'unsent'
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

  # An unsent line stashed by the up arrow is a draft: coming back down
  # restores it, but it is never recalled or resent as a history entry.
  describe 'unsent draft stashed by the up arrow' do
    let(:screen) { ScreenLineWindow.new(20) }

    before do
      buf.window = screen
      buf.add_to_history('look')
    end

    def send_line
      buf.add_to_history(buf.clear_and_get)
    end

    def up_arrow_lines(count)
      Array.new(count) do
        buf.previous_command
        screen.visible
      end
    end

    it 'comes back when navigating down to the bottom' do
      type('draft')
      buf.previous_command
      expect(screen.visible).to eq 'look'
      buf.next_command
      expect(screen.visible).to eq 'draft'
      expect(screen.curx).to eq 5
    end

    it 'comes back after going several entries up and all the way down' do
      buf.add_to_history('exp1')
      type('draft')
      2.times { buf.previous_command }
      expect(screen.visible).to eq 'look'
      2.times { buf.next_command }
      expect(screen.visible).to eq 'draft'
    end

    it 'is not recalled after the recalled entry is sent and another line follows' do
      type('draft')
      buf.previous_command
      send_line # sends "look"
      type('exp1')
      send_line
      expect(up_arrow_lines(3)).to eq %w[exp1 look look]
    end

    it 'is not recalled after it is cleared and another line is sent' do
      type('draft')
      buf.previous_command
      buf.next_command
      buf.kill_line
      type('exp1')
      send_line
      expect(up_arrow_lines(3)).to eq %w[exp1 look look]
    end

    it 'is not recalled after an edited recalled entry is sent' do
      type('draft')
      buf.previous_command
      type(' me')
      send_line # sends "look me"
      expect(up_arrow_lines(3)).to eq ['look me', 'look', 'look']
    end

    it 'is discarded when a line is sent, so coming back down shows an empty line' do
      type('draft')
      buf.previous_command
      send_line
      buf.previous_command
      buf.next_command
      expect(screen.visible).to eq ''
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

    it 'blanks the line and homes the cursor' do
      screen = ScreenLineWindow.new(10)
      buf.window = screen
      type('a' * 15)
      buf.clear_and_get
      expect(screen.visible).to eq ''
      expect(screen.curx).to eq 0
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

    it 'shows the tail of the text with the cursor in the last column' do
      screen = ScreenLineWindow.new(10)
      buf.window = screen
      type('abcdefghijklmno')
      expect(screen.visible).to eq 'ghijklmno'
      expect(screen.curx).to eq 9
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
    it 'put_ch ends by placing the cursor after writing' do
      buf.put_ch('a')
      methods = window.call_log.map(&:first)
      expect(methods.last).to eq :setpos
      expect(window.call_log.last).to eq [:setpos, [0, 1]]
    end

    it 'repaints by clearing the row before writing it' do
      # Writing the last column leaves the curses cursor there; clearing
      # afterwards would erase that character.
      type('ab')
      window.call_log.clear
      buf.backspace
      methods = window.call_log.map(&:first)
      expect(methods.index(:clrtoeol)).to be < methods.index(:addstr)
    end

    it 'put_ch does not flush (callers call refresh)' do
      buf.put_ch('a')
      expect(window.call_log.map(&:first)).not_to include(:noutrefresh)
    end

    it 'kill_line produces setpos, clrtoeol, noutrefresh' do
      type('hello')
      window.call_log.clear
      buf.kill_line
      methods = window.call_log.map(&:first)
      expect(methods).to include(:setpos, :clrtoeol, :noutrefresh)
    end

    it 'cursor_home with offset repaints the scrolled-off leading chars' do
      screen = ScreenLineWindow.new(5)
      buf.window = screen
      type('abcdefghij')
      buf.cursor_home
      expect(screen.line).to eq 'abcde'
      expect(screen.curx).to eq 0
    end
  end

  # ==================================================================
  # What the user sees while the line is scrolled
  # ==================================================================

  # Assert the screen shows a faithful window onto the buffer: the row is
  # exactly the text starting at column 0's buffer index, the cursor sits
  # on buffer position +pos+, no curses call was out of range, and the
  # view is not scrolled right while it has blank columns to spare.
  #
  # Uses only buf.text, buf.pos and the screen, never buf.offset, so it
  # applies to any rendering strategy.
  def expect_faithful_screen(screen)
    width = screen.maxx
    start = buf.pos - screen.curx
    expect(screen.errors).to be_empty
    expect(screen.curx).to be_between(0, width - 1)
    expect(start).to be_between(0, buf.text.length)
    expect(screen.line).to eq buf.text[start, width].ljust(width)
    # Hidden leading text is only acceptable when the rest fills the row
    # (the cursor may occupy the last column past the end).
    expect(buf.text.length - start).to be >= (width - 1) if start.positive?
  end

  describe 'visible line while scrolled' do
    let(:screen) { ScreenLineWindow.new(10) }

    before { buf.window = screen }

    it 'never goes blank while text remains when backspacing from past the width' do
      type('abcdefghijklmnopqrstuvwxy')
      25.times do
        buf.backspace
        expect_faithful_screen(screen)
        expect(screen.visible).not_to be_empty unless buf.text.empty?
      end
      expect(buf.text).to eq ''
    end

    it 'shows everything Enter would send once the text fits again' do
      type('abcdefghijklmno')
      6.times { buf.backspace }
      shown = screen.visible
      expect(shown).to eq 'abcdefghi'
      expect(buf.clear_and_get).to eq shown
    end

    it 'backspace at the left edge while scrolled deletes the right char and scrolls back' do
      type('abcdefghijklmnopqrst')
      buf.cursor_left while screen.curx.positive?
      expect(screen.line).to eq 'lmnopqrst '
      buf.backspace
      expect(buf.text).to eq 'abcdefghijlmnopqrst'
      expect_faithful_screen(screen)
      expect(screen.line).to eq 'lmnopqrst '
      expect(screen.curx).to eq 0
    end

    it 'kill_forward, cursor_end, then typing keeps the text visible' do
      type('abcdefghijklmnopqrst')
      10.times { buf.cursor_left }
      buf.kill_forward
      expect(buf.text).to eq 'abcdefghij'
      expect_faithful_screen(screen)
      buf.cursor_end
      expect_faithful_screen(screen)
      type('XY')
      expect_faithful_screen(screen)
      expect(screen.visible).to eq 'defghijXY'
      expect(screen.curx).to eq 9
    end

    it 'cursor_end on short text left by kill_forward puts the cursor after the text' do
      type('abcdefghijklmno')
      buf.cursor_left while screen.curx.positive?
      buf.kill_forward
      expect(buf.text).to eq 'abcdef'
      buf.cursor_end
      expect_faithful_screen(screen)
      expect(screen.visible).to eq 'abcdef'
      expect(screen.curx).to eq 6
    end

    it 'cursor_home after scrolling shows the start of the text' do
      type('abcdefghijklmnopqrst')
      buf.cursor_home
      expect_faithful_screen(screen)
      expect(screen.line).to eq 'abcdefghij'
      expect(screen.curx).to eq 0
    end

    it 'cursor_home after backspacing a scrolled line does not lose the text' do
      type('abcdefghijklmno')
      12.times { buf.backspace }
      buf.cursor_home
      expect_faithful_screen(screen)
      expect(screen.visible).to eq 'abc'
      buf.put_ch('Z')
      expect_faithful_screen(screen)
      expect(screen.visible).to eq 'Zabc'
    end

    it 'cursor_word_left and cursor_word_right keep the cursor on screen' do
      type('alpha beta gamma delta epsilon')
      4.times do
        buf.cursor_word_left
        expect_faithful_screen(screen)
      end
      4.times do
        buf.cursor_word_right
        expect_faithful_screen(screen)
      end
    end

    it 'recalling a long history entry shows its tail, a short one shows all of it' do
      buf.add_to_history('abcdefghijklmnopqrst')
      buf.add_to_history('short')
      buf.previous_command
      expect(screen.visible).to eq 'short'
      buf.previous_command
      expect_faithful_screen(screen)
      expect(screen.visible).to eq 'lmnopqrst'
      buf.next_command
      expect_faithful_screen(screen)
      expect(screen.visible).to eq 'short'
    end

    it 'yank past the width scrolls to show the pasted text' do
      type('abcdefghijklmnop')
      buf.cursor_home
      buf.kill_forward
      buf.yank
      expect_faithful_screen(screen)
      expect(screen.visible).to eq 'hijklmnop'
    end
  end

  describe '#redraw' do
    it 'refits pos/offset after the window gets narrower, then typing works' do
      screen = ScreenLineWindow.new(20)
      buf.window = screen
      type('abcdefghijklmnopqr')
      screen.resize(1, 10)
      buf.redraw
      expect_faithful_screen(screen)
      expect(screen.line).to eq 'jklmnopqr '
      expect(screen.curx).to eq 9
      buf.put_ch('Z')
      expect_faithful_screen(screen)
      expect(screen.visible).to eq 'klmnopqrZ'
    end

    it 'scrolls hidden text back into view after the window gets wider' do
      screen = ScreenLineWindow.new(10)
      buf.window = screen
      type('abcdefghijklmno')
      screen.resize(1, 30)
      buf.redraw
      expect_faithful_screen(screen)
      expect(screen.visible).to eq 'abcdefghijklmno'
      expect(screen.curx).to eq 15
    end

    it 'keeps a mid-line cursor on screen after narrowing' do
      screen = ScreenLineWindow.new(30)
      buf.window = screen
      type('abcdefghijklmnopqrstuvwxy')
      buf.cursor_home
      20.times { buf.cursor_right }
      screen.resize(1, 8)
      buf.redraw
      expect_faithful_screen(screen)
      expect(buf.pos).to eq 20
    end

    it 'flushes the window' do
      buf.redraw
      expect(window.call_log.map(&:first)).to include(:noutrefresh)
    end

    it 'is a no-op without a window' do
      buf.window = nil
      expect { buf.redraw }.not_to raise_error
    end

    it 'handles a one-column window' do
      screen = ScreenLineWindow.new(1)
      buf.window = screen
      type('abc')
      expect_faithful_screen(screen)
      buf.cursor_left
      expect_faithful_screen(screen)
      expect(screen.line).to eq 'c'
    end
  end

  describe 'randomized editing keeps the screen faithful' do
    edit_ops = %i[put_ch put_ch put_ch put_ch backspace delete_char cursor_left cursor_right
                  cursor_word_left cursor_word_right cursor_home cursor_end backspace_word
                  delete_word kill_forward kill_line yank previous_command next_command]

    [[1, false], [42, false], [999, false], [2024, false], [7, true], [314, true]].each do |seed, resizing|
      it "holds after every operation (seed #{seed}#{', with resizes' if resizing})" do
        ops = resizing ? edit_ops + [:resize] : edit_ops
        rng = Random.new(seed)
        screen = ScreenLineWindow.new(7)
        buf.window = screen
        %w[north southwest get\ my\ longsword\ from\ my\ back look].each { |c| buf.add_to_history(c) }
        400.times do
          op = ops[rng.rand(ops.length)]
          case op
          when :put_ch then buf.put_ch(['a', 'b', ' ', '.', 'z'][rng.rand(5)])
          when :resize
            screen.resize(1, rng.rand(1..12))
            buf.redraw
          else buf.public_send(op)
          end
          expect_faithful_screen(screen)
        end
      end
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
