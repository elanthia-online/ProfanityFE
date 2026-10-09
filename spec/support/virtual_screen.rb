# frozen_string_literal: true

module Curses
  # Where the terminal cursor is. As in ncurses, each Window#noutrefresh
  # stages that window's cursor (as a screen position) and doupdate moves
  # the terminal cursor to the one staged last, so after a flush the cursor
  # is wherever the window refreshed last left it. Window#refresh does
  # both. TerminalScreen.doupdate (spec_helper's Curses.doupdate and its
  # CursesRenderer stub) calls {.flush}, and every example starts with
  # {.reset}.
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

  # What the terminal shows, modelled on ncurses' two screens: each
  # Window#noutrefresh copies the part of every line the window changed
  # since its last refresh (and only that part, as wnoutrefresh does) into
  # the next frame, and doupdate shows that frame. So where windows
  # overlap, the cells on the terminal are those of the window that last
  # copied them, which is not always the window refreshed last: a window
  # refreshed with no changes copies nothing. spec_helper's Curses.doupdate
  # and its CursesRenderer stub call {.doupdate}; every example starts with
  # {.reset}.
  #
  # Checked against real ncurses in a pseudo-terminal: a window copies only
  # the changed range of a line; Window.new, #move, #touch, #erase and
  # #clear mark every line; scrolling marks the scrolled rows.
  module TerminalScreen
    class << self
      # Copy one cell into the next frame (what wnoutrefresh does for each
      # changed cell). Cells off the screen are dropped.
      #
      # @param y [Integer] screen row
      # @param x [Integer] screen column
      # @param cell [Array(String, Integer)] character and attributes
      def stage(y, x, cell)
        return if y.negative? || x.negative? || y >= Curses.lines || x >= Curses.cols

        staged[[y, x]] = cell
      end

      # Show the next frame and move the terminal cursor (see
      # TerminalCursor), as Curses.doupdate does.
      def doupdate
        @shown = staged.dup
        TerminalCursor.flush
      end

      # @param y [Integer] screen row
      # @return [String] the characters the terminal shows on a row after
      #   the last doupdate, trailing blanks removed
      def row(y)
        (0...Curses.cols).map { |x| cell(y, x).first }.join.rstrip
      end

      # @return [Array<String>] every row of the terminal, trailing blanks
      #   removed
      def rows
        (0...Curses.lines).map { |y| row(y) }
      end

      # @param y [Integer] screen row
      # @param x [Integer] screen column
      # @return [Integer] the attributes of the cell the terminal shows
      def attrs_at(y, x)
        cell(y, x).last
      end

      # Blank the terminal and the next frame.
      def reset
        @staged = {}
        @shown = {}
      end

      private

      def staged
        @staged ||= {}
      end

      def cell(y, x)
        (@shown || {}).fetch([y, x], Window::BLANK)
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
  # - each window remembers which part of each line changed since its last
  #   refresh, and #noutrefresh copies only that part to the terminal (see
  #   TerminalScreen);
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

    # Like newwin, a height or width of 0 reaches the bottom or right edge
    # of the screen.
    #
    # @param height [Integer] number of rows
    # @param width [Integer] number of columns
    # @param top [Integer] screen row of the window's top edge
    # @param left [Integer] screen column of the window's left edge
    def initialize(height = 1, width = 80, top = 0, left = 0)
      height = Curses.lines - top if height.zero?
      width = Curses.cols - left if width.zero?
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
      touch_rows(0...height)
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
      touch_to_eol(@cury, @curx)
      nil
    end

    def delch
      log(:delch)
      line = @cells[@cury]
      line.delete_at(@curx)
      line.push(BLANK)
      touch_to_eol(@cury, @curx)
      nil
    end

    def deleteln
      log(:deleteln)
      @cells.delete_at(@cury)
      @cells.push(blank_row(@maxx))
      touch_rows(@cury...@maxy)
      nil
    end

    def clrtoeol
      log(:clrtoeol)
      clrtoeol_silently
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
      touch_rows(top..bottom)
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
      @changed = []
      touch_rows(0...height)
      nil
    end

    def move(top, left)
      log(:move, top, left)
      @begy = top
      @begx = left
      touch_rows(0...@maxy)
      nil
    end

    # Like touchwin, marks every line as changed, so the next #noutrefresh
    # copies the whole window to the terminal.
    def touch
      log(:touch)
      touch_rows(0...@maxy)
      nil
    end

    # Like wnoutrefresh, copies the changed part of each line to the next
    # frame (see TerminalScreen), forgets the changes, and stages the
    # cursor for the next doupdate (see TerminalCursor).
    def noutrefresh
      log(:noutrefresh)
      stage_changes
      nil
    end

    # Like wrefresh: wnoutrefresh, then doupdate.
    def refresh
      log(:refresh)
      stage_changes
      TerminalScreen.doupdate
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

    # Copy each line's changed range to the terminal's next frame, forget
    # the changes, and stage the cursor.
    def stage_changes
      (@changed || []).each_with_index do |range, y|
        next unless range

        range.each { |x| TerminalScreen.stage(@begy + y, @begx + x, @cells[y][x]) if x < @maxx }
      end
      @changed = []
      TerminalCursor.stage(@begy + @cury, @begx + @curx)
    end

    # Mark columns +first+..+last+ of row +y+ as changed (ncurses keeps one
    # range per line, from the first to the last changed column).
    def touch_cells(y, first, last)
      return if y.negative? || y >= @maxy || last < first

      @changed ||= []
      old = @changed[y]
      @changed[y] = old ? ([old.first, first].min..[old.last, last].max) : (first..last)
    end

    def touch_to_eol(y, x)
      touch_cells(y, x, @maxx - 1)
    end

    def touch_rows(rows)
      rows.each { |y| touch_cells(y, 0, @maxx - 1) }
    end

    def blank_row(width)
      Array.new([width, 0].max) { BLANK }
    end

    def clear_cells
      @cells = Array.new(@maxy) { blank_row(@maxx) }
      @cury = 0
      @curx = 0
      touch_rows(0...@maxy)
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

      if @cury < @maxy && @curx < @maxx
        @cells[@cury][@curx] = [ch, @attrs]
        touch_cells(@cury, @curx, @curx)
      end
      @curx += 1
      return true if @curx < @maxx

      next_line(wrapping: true)
    end

    def clrtoeol_silently
      return unless @cury < @maxy

      (@curx...@maxx).each { |x| @cells[@cury][x] = BLANK }
      touch_to_eol(@cury, @curx)
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
      touch_rows(top..bottom)
    end
  end
end
