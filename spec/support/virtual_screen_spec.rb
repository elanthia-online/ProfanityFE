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

    it 'scrl moves nothing while scrollok is off' do
      win = window(4, 5)
      win.addstr("1\n2\n3\n4")
      win.scrl(1)
      win.scrl(-1)
      expect(screen(win)).to eq(rows: %w[1 2 3 4], cursor: [3, 1])
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

    it 'rejects a scrolling region of one row, so scrl moves the whole window' do
      win = window(3, 5)
      win.scrollok(true)
      win.addstr("T\n2\n3")
      win.setscrreg(1, 1)
      win.scrl(1)
      expect(screen(win)).to eq(rows: ['2', '3', ''], cursor: [2, 1])
    end

    it 'keeps the previous scrolling region when setscrreg is rejected' do
      win = window(4, 5)
      win.scrollok(true)
      win.addstr("T\n2\n3\n4")
      win.setscrreg(1, 3)
      win.setscrreg(2, 2)
      win.scrl(1)
      expect(screen(win)).to eq(rows: ['T', '3', '4', ''], cursor: [3, 1])
    end
  end

  describe 'moving the cursor' do
    it 'ignores a setpos outside the window, so later text goes where the cursor was' do
      win = window(3, 5)
      win.setpos(1, 2)
      [[-1, 0], [0, -1], [3, 0], [0, 5]].each { |y, x| win.setpos(y, x) }
      win.addstr('ab')
      expect(screen(win)).to eq(rows: ['', '  ab', ''], cursor: [1, 4])
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

  describe 'resizing with a scrolling region' do
    # Number each row, then scroll once: the rows that moved show the region.
    def scroll_once(win)
      win.scrollok(true)
      (0...win.maxy).each do |y|
        win.setpos(y, 0)
        win.addstr(y.to_s)
      end
      win.setpos(0, 0)
      win.scrl(1)
      win.rows
    end

    it 'moves a region that ends on the bottom row to the new bottom row' do
      win = window(4, 5)
      win.setscrreg(1, 3)
      win.resize(6, 5)
      expect(scroll_once(win)).to eq ['0', '2', '3', '4', '5', '']
    end

    it 'keeps a region that ends above the bottom row' do
      win = window(5, 5)
      win.setscrreg(1, 2)
      win.resize(7, 5)
      expect(scroll_once(win)).to eq ['0', '2', '', '3', '4', '5', '6']
    end

    it 'trims the region to a shorter window, down to one row' do
      win = window(5, 5)
      win.setscrreg(1, 4)
      win.resize(2, 5)
      expect(scroll_once(win)).to eq ['0', '']
    end

    it 'grows the whole-window region with the window' do
      win = window(2, 5)
      win.setscrreg(1, 1)
      win.resize(4, 5)
      expect(scroll_once(win)).to eq ['1', '2', '3', '']
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

  # Screen positions read back from a real terminal (the output replayed
  # through a terminal emulator) after the same calls.
  # mvwin: ncurses refuses a move that would put any of the window off the
  # screen, and the window stays where it was (the curses gem returns nil
  # either way). Captured with a 5x10 window on a 12x40 terminal.
  describe 'moving a window' do
    before { allow(Curses).to receive_messages(lines: 12, cols: 40) }

    def moved(top, left)
      win = window(5, 10)
      expect(win.move(top, left)).to be_nil
      [win.begy, win.begx]
    end

    it 'moves a window that ends on the bottom row and the last column' do
      expect(moved(7, 30)).to eq [7, 30]
    end

    it 'moves a window that stays inside the screen' do
      expect(moved(2, 3)).to eq [2, 3]
    end

    it 'leaves a window that would end one row past the bottom where it was' do
      expect(moved(8, 30)).to eq [0, 0]
    end

    it 'leaves a window that would end one column past the right edge where it was' do
      expect(moved(7, 31)).to eq [0, 0]
    end

    it 'leaves a window that would start above or left of the screen where it was' do
      expect(moved(-1, 0)).to eq [0, 0]
      expect(moved(0, -1)).to eq [0, 0]
    end
  end

  describe 'the terminal cursor' do
    let(:top) { described_class.new(3, 10, 0, 0) }
    let(:bottom) { described_class.new(1, 10, 5, 2) }

    it 'goes where the window refreshed last before doupdate left its cursor' do
      bottom.setpos(0, 4)
      bottom.noutrefresh
      top.addstr('hi')
      top.noutrefresh
      Curses.doupdate
      expect(Curses::TerminalCursor.position).to eq [0, 2]

      bottom.noutrefresh
      Curses.doupdate
      expect(Curses::TerminalCursor.position).to eq [5, 6]
    end

    it 'does not follow a setpos made after the window was refreshed' do
      bottom.setpos(0, 4)
      bottom.noutrefresh
      bottom.setpos(0, 1)
      Curses.doupdate
      expect(Curses::TerminalCursor.position).to eq [5, 6]
    end

    it 'moves at once on refresh' do
      bottom.setpos(0, 1)
      bottom.refresh
      expect(Curses::TerminalCursor.position).to eq [5, 3]
    end
  end

  # The terminal after doupdate. Each rule here was checked against a real
  # ncurses screen (12x40, xterm-256color, in a pseudo-terminal): the same
  # calls on three overlapping windows, the screen read back after every
  # doupdate, 23 steps identical to the virtual screen's.
  describe 'the terminal (overlapping windows)' do
    before do
      allow(Curses).to receive_messages(lines: 12, cols: 40)
    end

    # back: rows 0-7, full width; front: rows 4-9, columns 10-29;
    # line: row 7, full width, refreshed last.
    let(:back) { described_class.new(8, 40, 0, 0) }
    let(:front) { described_class.new(6, 20, 4, 10) }
    let(:line) { described_class.new(1, 40, 7, 0) }

    def terminal = Curses::TerminalScreen.rows

    before do
      back.addstr('b' * 40 * 7)
      front.addstr('f' * 20 * 5)
      line.addstr('> typed text')
      [back, front, line].each(&:noutrefresh)
      Curses.doupdate
    end

    it 'shows nothing a window wrote until doupdate' do
      line.setpos(0, 2)
      line.addstr('TYPED')
      line.noutrefresh
      expect(terminal[7]).to eq '> typed text'

      Curses.doupdate
      expect(terminal[7]).to eq '> TYPED text'
    end

    it 'keeps a window drawn over another when the one below is refreshed with no changes' do
      front.setpos(3, 0)
      front.addstr('XXXX')
      front.noutrefresh
      line.noutrefresh
      Curses.doupdate
      expect(terminal[7]).to eq '> typed teXXXX'
    end

    it 'copies the whole window again after touch' do
      front.setpos(3, 0)
      front.addstr('XXXX')
      front.noutrefresh
      line.touch
      line.noutrefresh
      Curses.doupdate
      expect(terminal[7]).to eq '> typed text'
    end

    it 'copies only the changed part of a line' do
      back.setpos(5, 2)
      back.addstr('zz')
      back.noutrefresh
      Curses.doupdate
      expect(terminal[5]).to eq "bbzz#{'b' * 6}#{'f' * 20}#{'b' * 10}"
    end

    it 'copies every row a scroll moved' do
      back.scrollok(true)
      back.setpos(7, 0)
      back.addstr("\nnew")
      back.noutrefresh
      Curses.doupdate
      expect(terminal[3..7]).to eq ['b' * 40, 'b' * 40, 'b' * 40, '', 'new']
    end

    it 'copies the whole window after a move' do
      front.move(6, 20)
      front.noutrefresh
      Curses.doupdate
      expect(terminal[7]).to eq "> typed text#{' ' * 8}#{'f' * 20}"
    end

    it 'copies a new window whole, blank cells included' do
      described_class.new(2, 10, 8, 2).noutrefresh
      Curses.doupdate
      expect(terminal[8]).to eq "#{' ' * 12}#{'f' * 18}"
    end

    it 'clears the screen when a new window of size 0x0 is refreshed (it reaches the edges)' do
      described_class.new(0, 0, 0, 0).refresh
      expect(terminal).to all(eq(''))
    end
  end

  describe 'a closed window' do
    %i[maxy cury addstr close].each do |meth|
      it "raises on #{meth}, as the curses gem does" do
        win = window(5, 20)
        win.close
        expect { meth == :addstr ? win.addstr('x') : win.public_send(meth) }
          .to raise_error(RuntimeError, 'already closed window')
      end
    end
  end
end
