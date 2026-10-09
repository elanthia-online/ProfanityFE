# frozen_string_literal: true

# A one-row fake curses window that models what the user sees: a fixed
# number of character cells and a cursor column.
#
# The editing primitives follow ncurses semantics for a single-line window
# with scrollok off, so specs can drive CommandBuffer (old incremental
# code or new repaint code) and assert on the visible line instead of on
# the sequence of curses calls:
#
# - +setpos+ outside the window is rejected (ERR) and the cursor stays put.
# - +insch+ shifts the rest of the row right, dropping the last cell;
#   the cursor does not move. A non-String argument raises TypeError,
#   as the real binding does for +nil+.
# - +delch+ shifts the rest of the row left, blanking the last cell.
# - +addstr+/+addch+ write from the cursor; writing the last cell leaves
#   the cursor on it and stops (ncurses cannot wrap a one-line window).
# - +clrtoeol+ blanks from the cursor to the end; +deleteln+ blanks the row.
# - +resize+ changes the width, truncating or padding the row; +move+
#   and +touch+ only record the call.
#
# Every call is also appended to +call_log+ like the spec_helper stub.
class ScreenLineWindow
  # @return [Integer] number of columns
  attr_reader :maxx

  # @return [Integer] current cursor column
  attr_reader :curx

  # @return [Array<Array>] every call as [method, args]
  attr_reader :call_log

  # @return [Array<String>] descriptions of calls ncurses would reject
  attr_reader :errors

  # @param width [Integer] number of columns
  def initialize(width)
    @maxx = width
    @cells = Array.new(width, ' ')
    @curx = 0
    @call_log = []
    @errors = []
  end

  # @return [Integer] always 1
  def maxy = 1

  # @return [String] the row exactly as displayed, one char per cell
  def line = @cells.join

  # @return [String] the row with trailing blanks removed
  def visible = line.rstrip

  def setpos(y, x)
    log(:setpos, y, x)
    if y != 0 || x.negative? || x >= @maxx
      @errors << "setpos(#{y}, #{x}) outside width #{@maxx}"
      return
    end
    @curx = x
  end

  def insch(ch)
    log(:insch, ch)
    raise TypeError, "no implicit conversion of #{ch.class} into String" unless ch.is_a?(String)

    @cells.insert(@curx, ch)
    @cells.pop
  end

  def delch
    log(:delch)
    @cells.delete_at(@curx)
    @cells << ' '
  end

  def addstr(str)
    log(:addstr, str)
    str.each_char { |ch| break unless put(ch) }
  end

  def addch(ch)
    log(:addch, ch)
    put(ch)
  end

  def clrtoeol
    log(:clrtoeol)
    (@curx...@maxx).each { |i| @cells[i] = ' ' }
  end

  def deleteln
    log(:deleteln)
    @cells.fill(' ')
  end

  def resize(h, w)
    log(:resize, h, w)
    @cells = (@cells + Array.new([w - @maxx, 0].max, ' '))[0, w]
    @maxx = w
    @curx = [@curx, w - 1].min
  end

  def move(y, x) = log(:move, y, x)

  def touch = log(:touch)

  def noutrefresh = log(:noutrefresh)

  private

  def log(meth, *args)
    @call_log << [meth, args]
    nil
  end

  # Write one character at the cursor. Returns false once the last cell
  # has been written, as ncurses returns ERR when it cannot wrap.
  def put(ch)
    @cells[@curx] = ch
    return false if @curx == @maxx - 1

    @curx += 1
    true
  end
end
