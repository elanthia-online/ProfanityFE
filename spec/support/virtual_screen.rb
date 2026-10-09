# frozen_string_literal: true

module Curses
  # Where the terminal cursor is. As in ncurses, each Window#noutrefresh
  # stages that window's cursor (as a screen position) and doupdate moves
  # the terminal cursor to the one staged last, so after a flush the cursor
  # is wherever the window refreshed last left it. Window#refresh does
  # both. spec_helper's Curses.doupdate and its CursesRenderer stub call
  # {.flush}, and every example starts with {.reset}.
  module TerminalCursor
    class << self
      # @return [Array(Integer, Integer), nil] screen row and column of the
      #   terminal cursor after the last flush; nil before the first
      attr_reader :position

      # Stage a screen position for the next {.flush}.
      def stage(y, x)
        @staged = [y, x]
      end

      # Move the terminal cursor to the position staged last.
      def flush
        @position = @staged
        nil
      end

      # Forget the staged and flushed positions.
      def reset
        @staged = nil
        @position = nil
      end
    end
  end

  # Headless stand-in for Curses::Window that models what a real curses
  # window shows: a grid of cells (character + attributes), a cursor, a
  # scrolling region, and the attribute state. Specs can assert on the
  # screen a user would see ({#rows}, {#row}, {#attrs_at}) instead of on
  # the sequence of curses calls.
  #
  # Behaviour follows ncurses for the calls ProfanityFE makes:
  # - writing past the last column wraps the cursor to the next line;
  # - "\n" clears to the end of the line and moves to the next line;
  # - moving past the bottom of the scrolling region scrolls it when
  #   scrollok is on, and otherwise leaves the cursor on the bottom line;
  # - scrl scrolls only the scrolling region (the whole window by default),
  #   and only while scrollok is on;
  # - after #close, every curses call, a second #close and the size,
  #   position and cursor readers included, raises RuntimeError "already
  #   closed window", as the curses gem does. The inspection helpers
  #   ({#rows}, {#row}, {#attrs_at}, {#call_log}) keep working.
  #
  # Every call is also recorded in {#call_log} for specs that assert on
  # the calls themselves.
  #
  # @example
  #   win = Curses::Window.new(3, 10, 0, 0)
  #   win.addstr("hello")
  #   win.rows #=> ["hello", "", ""]
  class Window
    # Cell contents for a position nothing has been written to.
    BLANK = [' ', 0].freeze

    # @return [Integer] window height, width, and screen position
    attr_writer :maxy, :maxx, :begy, :begx

    # Window height, width, screen position, and cursor row and column.
    %i[maxy maxx begy begx cury curx].each do |meth|
      define_method(meth) do
        ensure_open
        instance_variable_get(:"@#{meth}")
      end
    end

    # @return [Array<Array(Symbol, Array)>] every call made, in order
    attr_reader :call_log

    # @param height [Integer] number of rows
    # @param width [Integer] number of columns
    # @param top [Integer] screen row of the window's top edge
    # @param left [Integer] screen column of the window's left edge
    def initialize(height = 1, width = 80, top = 0, left = 0)
      @maxy = height
      @maxx = width
      @begy = top
      @begx = left
      @call_log = []
      @cells = Array.new(height) { blank_row(width) }
      @cury = 0
      @curx = 0
      @attrs = 0
      @scrollok = false
      @region = nil
    end

    # --- Screen inspection (for specs) ---

    # @param y [Integer] row index
    # @return [String] the characters on a row, trailing blanks removed
    def row(y)
      @cells[y].map(&:first).join.rstrip
    end

    # @return [Array<String>] every row, trailing blanks removed
    def rows
      (0...@maxy).map { |y| row(y) }
    end

    # @param y [Integer] row index
    # @param x [Integer] column index
    # @return [Integer] the attributes the cell was written with
    def attrs_at(y, x)
      @cells[y][x].last
    end

    # --- Cursor and output ---

    # Like wmove, a position outside the window fails (ERR) and leaves
    # the cursor where it was.
    def setpos(y, x)
      log(:setpos, y, x)
      return nil if y.negative? || x.negative? || y >= @maxy || x >= @maxx

      @cury = y
      @curx = x
      nil
    end

    # Like waddstr, stops at the first character that can't be placed
    # (moving past the bottom line without scrollok).
    def addstr(str)
      log(:addstr, str)
      str.to_s.each_char { |ch| break unless put_char(ch) }
      nil
    end

    def addch(ch)
      log(:addch, ch)
      put_char(ch.is_a?(Integer) ? ch.chr : ch.to_s)
      nil
    end

    def insch(ch)
      log(:insch, ch)
      raise TypeError, 'no implicit conversion of nil into Integer' if ch.nil?

      line = @cells[@cury]
      line.insert(@curx, [ch.is_a?(Integer) ? ch.chr : ch.to_s, @attrs])
      line.pop
      nil
    end

    def delch
      log(:delch)
      line = @cells[@cury]
      line.delete_at(@curx)
      line.push(BLANK)
      nil
    end

    def deleteln
      log(:deleteln)
      @cells.delete_at(@cury)
      @cells.push(blank_row(@maxx))
      nil
    end

    def clrtoeol
      log(:clrtoeol)
      (@curx...@maxx).each { |x| @cells[@cury][x] = BLANK }
      nil
    end

    def erase
      log(:erase)
      clear_cells
    end

    def clear
      log(:clear)
      clear_cells
    end

    # --- Scrolling ---

    def scrollok(flag)
      log(:scrollok, flag)
      @scrollok = flag
      nil
    end

    # Like wsetscrreg, rejects a region outside the window or of fewer
    # than two rows and keeps the previous one.
    def setscrreg(top, bottom)
      log(:setscrreg, top, bottom)
      @region = [top, bottom] if top >= 0 && bottom < @maxy && bottom > top
      nil
    end

    # Scroll the scrolling region up by +lines+ (down when negative).
    # Like wscrl, does nothing while scrollok is off.
    def scrl(lines)
      log(:scrl, lines)
      return nil unless @scrollok

      top, bottom = region
      lines.abs.times do
        if lines.positive?
          @cells.delete_at(top)
          @cells.insert(bottom, blank_row(@maxx))
        else
          @cells.delete_at(bottom)
          @cells.insert(top, blank_row(@maxx))
        end
      end
      nil
    end

    # Curses::Window#scroll scrolls up one line (a window's buffer scrolls with LineBuffered#scroll_lines).
    def scroll
      scrl(1)
    end

    # --- Attributes ---

    def attron(attrs)
      log(:attron, attrs)
      previous = @attrs
      @attrs |= attrs
      return nil unless block_given?

      begin
        yield
      ensure
        @attrs = previous
      end
    end

    def attroff(attrs)
      log(:attroff, attrs)
      @attrs &= ~attrs
      nil
    end

    def attrset(attrs)
      log(:attrset, attrs)
      @attrs = attrs
      nil
    end

    # --- Geometry ---

    # Like wresize, keeps the scrolling region: trimmed to fit, and one
    # that ended on the bottom row ends on the new bottom row.
    def resize(height, width)
      log(:resize, height, width)
      @cells = (0...height).map do |y|
        line = @cells[y] || blank_row(width)
        line = line.first(width)
        line + blank_row(width - line.length)
      end
      if @region
        top, bottom = @region
        bottom = height - 1 if bottom > height - 1 || bottom == @maxy - 1
        @region = [[top, height - 1].min, bottom]
      end
      @maxy = height
      @maxx = width
      @cury = [@cury, height - 1].min
      @curx = [@curx, width - 1].min
      nil
    end

    # Like mvwin, refuses a move that would put any of the window off the
    # screen (Curses.lines by Curses.cols) and leaves the window where it
    # was; the curses gem returns nil either way.
    def move(top, left)
      log(:move, top, left)
      return nil if top.negative? || left.negative?
      return nil if top + @maxy > Curses.lines || left + @maxx > Curses.cols

      @begy = top
      @begx = left
      nil
    end

    # Like wnoutrefresh, stages the cursor for the next doupdate (see
    # TerminalCursor).
    def noutrefresh
      log(:noutrefresh)
      TerminalCursor.stage(@begy + @cury, @begx + @curx)
      nil
    end

    # Like wrefresh: wnoutrefresh, then doupdate.
    def refresh
      log(:refresh)
      TerminalCursor.stage(@begy + @cury, @begx + @curx)
      TerminalCursor.flush
    end

    # --- Calls with no effect on the modelled screen ---

    %i[redraw keypad].each do |meth|
      define_method(meth) do |*args|
        log(meth, *args)
        nil
      end
    end

    # Like the curses gem, frees the window: any later call raises.
    def close
      log(:close)
      @closed = true
      nil
    end

    def nodelay=(val)
      log(:nodelay=, val)
    end

    # wtimeout: how long the next getch waits, in milliseconds.
    def timeout=(val)
      log(:timeout=, val)
    end

    def getch
      log(:getch)
      nil
    end

    private

    def log(meth, *args)
      ensure_open
      @call_log << [meth, args]
    end

    # The curses gem's GetWINDOW check on a freed window.
    def ensure_open
      raise 'already closed window' if @closed
    end

    def blank_row(width)
      Array.new([width, 0].max) { BLANK }
    end

    def clear_cells
      @cells = Array.new(@maxy) { blank_row(@maxx) }
      @cury = 0
      @curx = 0
      nil
    end

    def region
      @region || [0, @maxy - 1]
    end

    # Write one character at the cursor and advance it, as waddch does.
    #
    # @return [Boolean] false when the cursor could not advance (ERR)
    def put_char(ch)
      if ch == "\n"
        clrtoeol_silently
        return next_line(wrapping: false)
      end

      @cells[@cury][@curx] = [ch, @attrs] if @cury < @maxy && @curx < @maxx
      @curx += 1
      return true if @curx < @maxx

      next_line(wrapping: true)
    end

    def clrtoeol_silently
      (@curx...@maxx).each { |x| @cells[@cury][x] = BLANK } if @cury < @maxy
    end

    # Move to the start of the next line, scrolling the region at its
    # bottom. Without scrollok the cursor stays put on the bottom line (on
    # the last column after a wrap) and the move fails.
    #
    # @return [Boolean] false when the move failed (ERR)
    def next_line(wrapping:)
      _top, bottom = region
      if @cury == bottom
        unless @scrollok
          @curx = @maxx - 1 if wrapping
          return false
        end

        scrl_silently
      elsif @cury < @maxy - 1
        @cury += 1
      end
      @curx = 0
      true
    end

    def scrl_silently
      top, bottom = region
      @cells.delete_at(top)
      @cells.insert(bottom, blank_row(@maxx))
    end
  end
end
