# frozen_string_literal: true

# Pins the virtual screen (spec/support/virtual_screen.rb) to real ncurses
# behaviour. Each expectation was captured by running the same calls on a
# real Curses::Window (ncurses, TERM=xterm-256color) in a pseudo-terminal
# and reading every cell back with #inch.

RSpec.describe Curses::Window do
  def window(height, width)
    described_class.new(height, width, 0, 0)
  end

  def screen(win)
    { rows: win.rows, cursor: [win.cury, win.curx] }
  end

  describe 'writing text' do
    it 'wraps to the next line past the right margin' do
      win = window(3, 5)
      win.addstr('abcdefgh')
      expect(screen(win)).to eq(rows: ['abcde', 'fgh', ''], cursor: [1, 3])
    end

    it 'leaves a blank row when a line exactly fills the width and is followed by a newline' do
      win = window(3, 5)
      win.addstr('abcde')
      win.addstr("\nxy")
      expect(screen(win)).to eq(rows: ['abcde', '', 'xy'], cursor: [2, 2])
    end

    it 'starts the first line on row 1 when output begins with a newline' do
      win = window(3, 6)
      win.scrollok(true)
      win.addstr("\nfirst")
      win.addstr("\nsecond")
      expect(screen(win)).to eq(rows: ['first', 'second', ''], cursor: [2, 0])
    end
  end

  describe 'reaching the bottom line' do
    it 'scrolls the window up on a newline when scrollok is on' do
      win = window(3, 5)
      win.scrollok(true)
      win.addstr("a\nb\nc\nd")
      expect(screen(win)).to eq(rows: %w[b c d], cursor: [2, 1])
    end

    it 'stops writing the rest of the string on a newline when scrollok is off' do
      win = window(3, 5)
      win.addstr("a\nb\nc\nd")
      expect(screen(win)).to eq(rows: %w[a b c], cursor: [2, 1])
    end

    it 'stops writing after the last column when scrollok is off' do
      win = window(2, 4)
      win.addstr('abcdefghij')
      expect(screen(win)).to eq(rows: %w[abcd efgh], cursor: [1, 3])
    end

    it 'scrolls when wrapping past the last column with scrollok on' do
      win = window(2, 4)
      win.scrollok(true)
      win.addstr('abcdefghij')
      expect(screen(win)).to eq(rows: %w[efgh ij], cursor: [1, 2])
    end
  end

  describe 'scrolling' do
    it 'scrl moves content up' do
      win = window(4, 5)
      win.scrollok(true)
      win.addstr("1\n2\n3\n4")
      win.scrl(1)
      expect(screen(win)).to eq(rows: ['2', '3', '4', ''], cursor: [3, 1])
    end

    it 'scrl with a negative count moves content down' do
      win = window(4, 5)
      win.scrollok(true)
      win.addstr("1\n2\n3\n4")
      win.scrl(-2)
      expect(screen(win)).to eq(rows: ['', '', '1', '2'], cursor: [3, 1])
    end

    it 'scrl only moves the scrolling region set by setscrreg' do
      win = window(4, 5)
      win.scrollok(true)
      win.addstr("T\n2\n3\n4")
      win.setscrreg(1, 3)
      win.scrl(1)
      expect(screen(win)).to eq(rows: ['T', '3', '4', ''], cursor: [3, 1])
    end

    it 'scrolls the region on a newline at its bottom line' do
      win = window(4, 5)
      win.scrollok(true)
      win.setscrreg(1, 3)
      win.setpos(3, 0)
      win.addstr("x\ny")
      expect(screen(win)).to eq(rows: ['', '', 'x', 'y'], cursor: [3, 1])
    end
  end

  describe 'editing' do
    it 'insch inserts at the cursor and delch deletes at the cursor' do
      win = window(1, 6)
      win.addstr('abcdef')
      win.setpos(0, 2)
      win.insch('X')
      win.setpos(0, 0)
      win.delch
      expect(screen(win)).to eq(rows: ['bXcde'], cursor: [0, 0])
    end

    it 'deleteln removes the cursor line and shifts the rest up' do
      win = window(3, 5)
      win.addstr("a\nb\nc")
      win.setpos(0, 0)
      win.deleteln
      expect(screen(win)).to eq(rows: ['b', 'c', ''], cursor: [0, 0])
    end

    it 'clrtoeol blanks from the cursor to the end of the line' do
      win = window(1, 6)
      win.addstr('abcdef')
      win.setpos(0, 2)
      win.clrtoeol
      expect(screen(win)).to eq(rows: ['ab'], cursor: [0, 2])
    end

    it 'erase blanks the window and homes the cursor' do
      win = window(2, 5)
      win.addstr("ab\ncd")
      win.erase
      win.addstr('z')
      expect(screen(win)).to eq(rows: ['z', ''], cursor: [0, 1])
    end

    it 'resize keeps the top-left content and clamps the cursor' do
      win = window(3, 6)
      win.addstr("abcdef\nghijkl\nmn")
      win.resize(2, 3)
      expect(screen(win)).to eq(rows: ['abc', ''], cursor: [1, 2])
    end
  end

  describe 'attributes' do
    it 'applies attron to text written inside its block only' do
      win = window(1, 6)
      win.attron(Curses::A_REVERSE) { win.addstr('ab') }
      win.addstr('c')
      expect([win.attrs_at(0, 0), win.attrs_at(0, 1), win.attrs_at(0, 2)]).to eq [Curses::A_REVERSE, Curses::A_REVERSE, 0]
    end
  end
end
