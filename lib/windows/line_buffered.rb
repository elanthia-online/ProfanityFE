# frozen_string_literal: true

# Viewport shared by windows that show a LineBuffer: append, scroll,
# scrollbar, repaint, selection and link lookup.

require_relative '../line_buffer'
require_relative '../selection_manager'

# Draws a {LineBuffer} into a window's text area and maps the area's
# rows back to buffer lines, for windows whose text area is all or part
# of the window.
#
# The including window supplies the buffer being shown ({#shown_buffer})
# and may narrow the text area by overriding {#content_top} and
# {#content_height} (a tabbed window keeps its top row for the tab bar).
# Row arguments to the public methods are relative to the window's top,
# as mouse handling reports them; they are converted to text-area rows
# here. The scrollbar and selection live here too: only windows showing
# a buffer have them, so the one-row widgets don't carry either.
module LineBuffered
  # Bold vertical line character used for the scrollbar when the window is active.
  ACTIVE_SCROLLBAR_CHAR = "\u2503" # bold vertical line

  # Right-pointing triangle shown at the top of the scrollbar for the active window.
  ACTIVE_INDICATOR = "\u25B6" # right-pointing triangle

  # @return [Boolean] whether continuation lines are indented during word wrap
  attr_accessor :indent_word_wrap

  # @return [Boolean] whether a timestamp is appended to each non-empty line
  attr_accessor :time_stamp

  # @return [Array<Integer>, nil] [line_id, x] where the selection begins
  #   (line_id is a stable buffer line ID — see {AnchoredSelection})
  attr_accessor :selection_start

  # @return [Array<Integer>, nil] [line_id, x] where the selection ends
  attr_accessor :selection_end

  # Start with no scrollbar drawn and the window inactive.
  #
  # @param args [Array] arguments forwarded to the window class's superclass
  def initialize(*args)
    @active = false
    @scrollbar_pos = nil
    @painted_selection = nil
    super
  end

  # First window row of the text area. Default: the window's top row.
  #
  # @return [Integer]
  def content_top
    0
  end

  # Height of the text area in rows. Default: the whole window.
  #
  # @return [Integer]
  def content_height
    maxy
  end

  # The shown buffer's display rows.
  #
  # @return [Array<Array(String, Array<Hash>, Boolean)>] rows (text, runs,
  #   wrap-continuation flag; see {LineBuffer#lines}), newest first (empty
  #   when no buffer is shown)
  def buffer
    shown_buffer&.lines || []
  end

  # Return the shown buffer's display rows for selection support.
  #
  # @return [Array<Array(String, Array<Hash>, Boolean)>] rows (text, runs,
  #   wrap-continuation flag; see {LineBuffer#lines}), newest first (empty
  #   when no buffer is shown)
  def buffer_content
    shown_buffer&.lines || []
  end

  # Return the shown buffer's scroll offset.
  #
  # @return [Integer] number of rows scrolled back from the newest
  def buffer_pos
    shown_buffer&.pos || 0
  end

  # Monotonic count of rows ever appended to the shown buffer. Gives
  # each buffer row a stable ID for selection anchoring
  # (see {AnchoredSelection}).
  #
  # @return [Integer]
  def lines_appended
    shown_buffer&.lines_appended || 0
  end

  # Scroll the shown buffer by the given number of lines.
  # Negative values scroll up (toward older content), positive values scroll
  # down (toward newer content). A text area with no rows doesn't scroll.
  # Not to be confused with +Curses::Window#scroll+, which the window
  # keeps: it takes no argument and moves the window's cells up one row.
  #
  # @param scroll_num [Integer] lines to scroll (negative = up, positive = down)
  # @return [void]
  def scroll_lines(scroll_num)
    line_buffer = shown_buffer
    return unless line_buffer && content_height.positive?

    height = content_height
    if scroll_num < 0
      moved = line_buffer.scroll_back(scroll_num.abs, height)
      if moved > height
        # More than a page: drawing the uncovered rows from the top would
        # run past the text area, so repaint it
        paint_content
      elsif moved.positive?
        scrl(-moved)
        setpos(content_top, 0)
        draw_buffer_lines(line_buffer.lines, line_buffer.pos + height - 1, moved)
        noutrefresh
      end
      update_scrollbar
    elsif scroll_num > 0
      moved = line_buffer.scroll_forward(scroll_num)
      if moved > height
        # More than a page: the rows to draw would start above the text
        # area (on the tab bar, or outside the window), so repaint it
        paint_content
      elsif moved.positive?
        scrl(moved)
        setpos(content_top + height - moved, 0)
        draw_buffer_lines(line_buffer.lines, line_buffer.pos + moved - 1, moved)
        noutrefresh
      end
    end
    # Selection is anchored to line IDs; re-render so the highlight
    # follows its text to the new scroll position
    redraw_with_highlight if has_highlight?
    update_scrollbar
  end

  # Refresh the scrollbar to reflect the shown buffer and scroll state.
  # It covers the text area's rows, beside them. Only the active window
  # (the one the scroll keys act on, see {#set_active}) shows a
  # scrollbar: {#set_active} clears it when the window stops being
  # active, and nothing draws it again until the window is active: not
  # lines arriving, a lowered buffer size, a redraw or a scroll (a drag
  # held at the window's edge scrolls an inactive window).
  #
  # @return [void]
  def update_scrollbar
    line_buffer = shown_buffer
    return unless active? && line_buffer

    render_scrollbar(line_buffer.length, line_buffer.pos, content_height, top: content_top)
  end

  # Clear (hide) the scrollbar.
  #
  # @return [void]
  def clear_scrollbar
    reset_scrollbar
  end

  # Give the window its scrollbar: a one-column window just right of it,
  # as tall as it is.
  #
  # @return [void]
  def add_scrollbar
    self.scrollbar = Curses::Window.new(maxy, 1, begy, begx + maxx)
  end

  # Move and size the scrollbar to the window after the window was
  # resized: just right of it, as tall as it is (at least one row).
  #
  # @return [void]
  def fit_scrollbar
    scrollbar.resize([maxy, 1].max, 1)
    scrollbar.move(begy, begx + maxx)
  end

  # @return [Curses::Window, nil] companion 1-column curses window for the scrollbar
  attr_accessor :scrollbar

  # Set whether this window is the active (focused) window, and show it:
  # the scrollbar is cleared, then drawn again in full as the active one
  # if the window is now active (see {#update_scrollbar}).
  #
  # @param is_active [Boolean] true to mark this window active
  # @return [void]
  def set_active(is_active)
    @active = is_active
    clear_scrollbar
    update_scrollbar
  end

  # Whether this window is currently the active (focused) window.
  #
  # @return [Boolean]
  def active?
    @active
  end

  # Render the active window's scrollbar for a buffer with the given
  # metrics. {#update_scrollbar} calls this, only while the window is
  # active, with the shown buffer's length and scroll position and the
  # text area's height. It always draws the active look, so it is
  # private: call {#update_scrollbar}, which skips inactive windows.
  # The scrollbar covers the content area's rows only: +visible_height+
  # cells from row +top+ of the scrollbar window. A content area with no
  # rows gets no scrollbar.
  #
  # The thumb (a reverse-video blank) marks the scroll position. Every
  # other cell shows the bar, except the top cell, which shows the active
  # marker whenever the thumb isn't on it. The first call after
  # {#reset_scrollbar} draws every cell; later calls redraw only the cell
  # the thumb left and the one it moved to.
  #
  # @param buffer_length [Integer] total number of lines in the buffer
  # @param buffer_pos [Integer] current scroll offset from the bottom
  # @param visible_height [Integer] number of visible rows in the content area
  # @param top [Integer] window row where the content area starts
  # @return [void]
  private def render_scrollbar(buffer_length, buffer_pos, visible_height, top: 0)
    return unless @scrollbar && visible_height.positive?

    last_scrollbar_pos = @scrollbar_pos
    @scrollbar_pos = visible_height - ((buffer_pos / [(buffer_length - visible_height),
                                                      1].max.to_f) * (visible_height - 1)).round - 1

    if last_scrollbar_pos
      unless last_scrollbar_pos == @scrollbar_pos
        draw_scrollbar_bar_cell(last_scrollbar_pos, top)
        @scrollbar.setpos(top + @scrollbar_pos, 0)
        @scrollbar.attron(Curses::A_REVERSE) do
          @scrollbar.addch ' '
        end
        @scrollbar.noutrefresh
      end
    else
      (0...visible_height).each do |num|
        if num == @scrollbar_pos
          @scrollbar.setpos(top + num, 0)
          @scrollbar.attron(Curses::A_REVERSE) do
            @scrollbar.addch ' '
          end
        else
          draw_scrollbar_bar_cell(num, top)
        end
      end
      @scrollbar.noutrefresh
    end
  end

  # Draw one scrollbar cell without the thumb: the active marker (bold) on
  # the top row, else the bar glyph.
  #
  # @param row [Integer] content-area row of the cell
  # @param top [Integer] window row where the content area starts
  # @return [void]
  private def draw_scrollbar_bar_cell(row, top)
    @scrollbar.setpos(top + row, 0)
    if row.zero?
      @scrollbar.attron(Curses::A_BOLD) do
        @scrollbar.addstr ACTIVE_INDICATOR
      end
    else
      @scrollbar.addstr ACTIVE_SCROLLBAR_CHAR
    end
  end

  # Reset the scrollbar to its default (cleared) state: erase the
  # scrollbar column, so that the next {#render_scrollbar} draws every
  # cell. Whether the window is active is kept.
  #
  # @return [void]
  def reset_scrollbar
    @scrollbar_pos = nil
    return unless @scrollbar

    @scrollbar.erase
    @scrollbar.noutrefresh
  end

  # Resolve window-relative coordinates to a stable [line_id, x] anchor
  # in the shown buffer. The anchor stays glued to the same text as the
  # buffer grows or scrolls.
  #
  # @param rel_y [Integer] row relative to window top
  # @param rel_x [Integer] column relative to window left
  # @return [Array<Integer>, nil] [line_id, x] anchor, or nil if nothing is shown
  def selection_anchor_at(rel_y, rel_x)
    line_buffer = shown_buffer
    return nil unless line_buffer

    id = line_buffer.id_at_row(rel_y - content_top, content_height)
    id ? [id, [rel_x, 0].max] : nil
  end

  # Extract text from the shown buffer for a selection anchored to stable
  # line IDs. Lines evicted past max_buffer_size are skipped.
  #
  # @param start_id [Integer] starting line ID
  # @param start_x [Integer] starting column
  # @param end_id [Integer] ending line ID
  # @param end_x [Integer] ending column
  # @return [String] the selected text, lines joined by newlines
  def extract_selection(start_id, start_x, end_id, end_x)
    line_buffer = shown_buffer
    return '' unless line_buffer

    line_buffer.extract(start_id, start_x, end_id, end_x)
  end

  # Scroll one line when a drag pointer sits at the text area's top edge
  # (or above it) or the window's bottom row, extending a selection past
  # the visible area.
  #
  # @param rel_y [Integer] drag row relative to window top
  # @return [Boolean] true if the view actually scrolled
  def drag_auto_scroll(rel_y)
    before = buffer_pos
    if rel_y <= content_top
      scroll_lines(-1)
    elsif rel_y >= maxy - 1
      scroll_lines(1)
    end
    buffer_pos != before
  end

  # Redraw the text area, applying reverse-video to the selected region.
  # The selection is anchored to stable line IDs, so the highlight follows
  # its text as new lines arrive or the user scrolls.
  #
  # @return [void]
  def redraw_with_highlight
    return unless @selection_start && @selection_end && shown_buffer

    paint_content
  end

  # Repaint every row of the text area from the shown buffer, drawing the
  # selected region, if any, in reverse video (see {BaseWindow#repaint}).
  #
  # @return [void]
  def repaint
    paint_content
  end

  # Set the selection range and redraw the text area with it highlighted.
  #
  # @param start_id [Integer] starting line ID
  # @param start_x [Integer] starting column
  # @param end_id [Integer] ending line ID
  # @param end_x [Integer] ending column
  # @return [void]
  def highlight_selection(start_id, start_x, end_id, end_x)
    @selection_start = [start_id, start_x]
    @selection_end = [end_id, end_x]
    redraw_with_highlight
  end

  # Whether a selection highlight is currently active on this window.
  #
  # @return [Boolean]
  def has_highlight?
    !@selection_start.nil? && !@selection_end.nil?
  end

  # Clear the selection highlight and repaint the window normally.
  #
  # @return [void]
  def clear_highlight
    @selection_start = nil
    @selection_end = nil
    repaint
  end

  # Fit every buffer to the window's current size, after a resize.
  # Stored lines are re-wrapped to the new width, keeping the logical
  # line on each buffer's bottom row there, and a view scrolled back past
  # the oldest row of a taller text area moves down onto it (see
  # {LineBuffer#fit}). Only the shown buffer is re-wrapped now; the
  # others are re-wrapped when they are next read, when shown, to what
  # they would have been. A re-wrap clears the selection: its row IDs no
  # longer exist. The caller repaints.
  #
  # @return [void]
  def rewrap
    width = wrap_width
    height = content_height
    rewrapping = line_buffers.any? { |line_buffer| line_buffer.width != width }
    line_buffers.each do |line_buffer|
      line_buffer.fit(width, height, later: !line_buffer.equal?(shown_buffer))
    end
    return unless rewrapping

    drop_selection
  end

  # Find a clickable link command at the given window-relative coordinates.
  # Scans the color regions of the line shown at (rel_y, rel_x) for a
  # :cmd entry whose span covers the column.
  #
  # @param rel_y [Integer] row relative to window top
  # @param rel_x [Integer] column relative to window left
  # @return [String, nil] the link command string, or nil if no link at that position
  def link_cmd_at(rel_y, rel_x)
    row = rel_y - content_top
    return nil if row < 0

    line_buffer = shown_buffer
    return nil unless line_buffer
    return nil if row >= line_buffer.visible_count(content_height)

    _id, entry = line_buffer.line_at_row(row, content_height)
    return nil unless entry

    _text, colors = entry
    return nil unless colors

    colors.each do |h|
      return h[:cmd] if h[:cmd] && rel_x >= h[:start] && rel_x < h[:end]
    end
    nil
  end

  # Drop the selection in this window when the rows its line IDs name
  # are no longer the ones shown (a re-wrap, a tab switch): the highlight,
  # and {SelectionManager}'s selection here, a drag in progress or the
  # highlight kept after one. Both go together, so a drag can't carry on
  # and copy other text under the old IDs.
  #
  # @return [void]
  private def drop_selection
    @selection_start = nil
    @selection_end = nil
    SelectionManager.clear_selection if SelectionManager.active_window.equal?(self)
  end

  # The buffer whose lines the text area shows.
  #
  # @abstract
  # @return [LineBuffer, nil] the buffer, or nil when nothing is shown
  # @raise [NotImplementedError] unless the including class defines it
  private def shown_buffer
    raise NotImplementedError, "#{self.class} must implement shown_buffer"
  end

  # Every buffer the window keeps, shown or not.
  #
  # @abstract
  # @return [Array<LineBuffer>]
  # @raise [NotImplementedError] unless the including class defines it
  private def line_buffers
    raise NotImplementedError, "#{self.class} must implement line_buffers"
  end

  # Append a string to a buffer as one logical line; the buffer wraps it
  # to the window width. When the buffer is shown and live, the new rows
  # are drawn at once (see {#draw_new_rows}); when it is scrolled back,
  # shown or not, the view keeps its place (moving onto the oldest row
  # left if an eviction dropped the rows it reached). A buffer that isn't
  # shown draws nothing, and the block, if given, is called.
  #
  # @param line_buffer [LineBuffer] the buffer to append to
  # @param string [String] the text to append
  # @param string_colors [Array<Hash>] color region descriptors
  # @param indent [Boolean, nil] indent continuation lines (nil = window default)
  # @param shown [Boolean] whether the text area shows +line_buffer+
  # @yield once, when +line_buffer+ isn't shown
  # @return [void]
  private def append_string(line_buffer, string, string_colors, indent:, shown:)
    string = buffer_text(string, @time_stamp)
    effective_indent = indent.nil? ? @indent_word_wrap : indent
    unless shown
      # Draw nothing; a view scrolled back keeps its place, as on the
      # shown path below, and evictions may have dropped rows it reached
      line_buffer.push_unseen(string, string_colors, indent: effective_indent, height: content_height)
      yield if block_given?
      return
    end

    length_before = line_buffer.length
    added = line_buffer.push(string, string_colors, indent: effective_indent)
    height = content_height
    if line_buffer.live?
      if line_buffer.length < [length_before + added, height].min
        # An eviction left too few rows to fill the text area, so every
        # row moved up: redraw them all
        paint_content
      else
        draw_new_rows(line_buffer, added, length_before, height)
      end
    else
      line_buffer.pos += added
      keep_view_on_stored_rows(line_buffer, height)
      update_scrollbar
    end
    return unless line_buffer.live?

    noutrefresh
  end

  # Draw the rows a line just added to a live view, each in the selection
  # highlight where it falls in the selection. The rows already shown
  # aren't drawn again: they keep their cells, highlight included, as
  # the text area scrolls them up. That holds only while they show the
  # current selection as {#paint_content} (or a tabbed window's redraw)
  # drew it; otherwise (rows drawn without the highlight, or the selection
  # changed without a repaint) every row is repainted with the highlight
  # after the new rows are drawn.
  #
  # @param line_buffer [LineBuffer] the shown buffer, live
  # @param added [Integer] rows the line was wrapped to
  # @param length_before [Integer] buffer length before the line was added
  # @param height [Integer] rows in the text area
  # @return [void]
  private def draw_new_rows(line_buffer, added, length_before, height)
    selection = painted_selection
    (added - 1).downto(0).each_with_index do |index, drawn|
      line, line_colors = line_buffer.lines[index]
      draw_newest_line(line, line_colors, length_before + drawn + 1, content_top, height,
                       id: line_buffer.lines_appended - index, selection: selection)
    end
    if has_highlight? && !selection
      paint_content
    elsif selection && line_buffer.length < height
      # A repaint ends at the start of the bottom row, which stays blank
      # until the text area fills: leave the cursor where it would
      setpos(content_top + height - 1, 0)
    end
  end

  # Set every buffer's cap, evicting the oldest lines over it at once.
  # Views react as to an eviction on append (see {#append_string}): a
  # scrolled-back view keeps its place, moving onto the oldest row left
  # if the eviction dropped the rows it reached, and a live view whose
  # rows no longer fill the text area is redrawn from its top row.
  #
  # @param cap [Integer, #to_i] maximum number of logical lines per buffer
  # @return [void]
  private def cap_line_buffers(cap)
    height = content_height
    line_buffers.each do |line_buffer|
      unless line_buffer.equal?(shown_buffer)
        # Not shown: keep its view in place, re-wrap put off or not
        line_buffer.cap = cap
        line_buffer.fit(line_buffer.width, height, later: true)
        next
      end

      length_before = line_buffer.length
      line_buffer.cap = cap
      next if line_buffer.length == length_before

      if line_buffer.live?
        paint_content if line_buffer.length < [length_before, height].min
      else
        keep_view_on_stored_rows(line_buffer, height)
        update_scrollbar
      end
    end
  end

  # After an eviction, move a scrolled-back view that reaches past the
  # oldest stored row down onto it: the rows shown above it are gone.
  #
  # @param line_buffer [LineBuffer] the shown buffer
  # @param height [Integer] rows in the text area
  # @return [void]
  private def keep_view_on_stored_rows(line_buffer, height)
    excess = line_buffer.pos - [line_buffer.length - height, 0].max
    return unless excess.positive?

    if excess < height && line_buffer.length >= height
      scroll_lines(excess)
    else
      line_buffer.pos -= excess
      paint_content
    end
  end

  # Column width lines are wrapped to: one column narrower than the
  # window.
  #
  # @return [Integer]
  private def wrap_width
    maxx - 1
  end

  # Draw consecutive buffer lines on consecutive rows, starting at the
  # cursor and moving from older lines (higher index) to newer ones.
  # No newline follows the last line: on the bottom row of the scrolling
  # region it would scroll the text up and blank that row. The lines are
  # drawn without the selection highlight.
  #
  # @param buffer [Array<Array(String, Array<Hash>, Boolean)>] the rows of a
  #   {LineBuffer} (newest first)
  # @param from_index [Integer] buffer index of the first (oldest) line to draw
  # @param count [Integer] number of lines to draw
  # @return [void]
  private def draw_buffer_lines(buffer, from_index, count)
    painted_without_selection
    top = cury
    from_index.downto(from_index - count + 1).each_with_index do |index, drawn|
      if drawn.positive?
        # A one-column row that isn't blank fills the window, so drawing
        # it moved the cursor down a row already (a blank one didn't),
        # and a newline would skip a row: place each row instead
        one_column? ? setpos(top + drawn, 0) : addstr("\n")
      end
      without_scrolling { add_line(buffer[index][0], buffer[index][1]) }
    end
  end

  # Draw a line just added to the newest end of a live (unscrolled) view.
  # Lines fill the text area from its top row; once the area is full it
  # scrolls up one row and the new line takes the bottom row. Every buffer
  # line, blank ones included, gets its own row, so rows keep matching the
  # row-to-line mapping of {AnchoredSelection} used for selection and links.
  # A text area with no rows (a one-row tabbed window is all tab bar)
  # draws nothing.
  #
  # @param line [String] the new line
  # @param line_colors [Array<Hash>] color regions for the line
  # @param buffer_length [Integer] buffer length, including the new line
  # @param top [Integer] first row of the text area
  # @param height [Integer] number of rows in the text area
  # @param id [Integer] the line's stable row ID
  # @param selection [Array<Integer>, nil] the normalized selection
  #   (see {#normalize_selection}) to draw the line in where it falls in
  #   it, or nil to draw it without a highlight
  # @return [void]
  private def draw_newest_line(line, line_colors, buffer_length, top, height, id:, selection:)
    return unless height.positive?

    scrl(1) if buffer_length > height
    setpos(top + [buffer_length, height].min - 1, 0)
    clrtoeol
    painted_without_selection unless selection
    draw_row(id, line, line_colors, selection)
  end

  # The selection the text area shows, when it is the current one: the
  # one the text area was last painted with in full (see
  # {#painted_with_selection}), as long as every row drawn since was drawn
  # with it.
  #
  # @return [Array<Integer>, nil] the normalized selection, or nil when
  #   there is none or the rows shown may not carry it
  private def painted_selection
    return nil unless has_highlight? && @painted_selection
    return nil unless @painted_selection == current_selection

    @painted_selection
  end

  # Note that rows of the text area were drawn without the selection
  # highlight, so the next line to arrive while a selection is set
  # repaints every row with it (see {#draw_new_rows}).
  #
  # @return [void]
  private def painted_without_selection
    @painted_selection = nil
  end

  # Note that every row of the text area was just drawn with +selection+
  # (none, when nil), so a line arriving while it is still the current
  # selection draws only its new rows (see {#draw_new_rows}).
  #
  # @param selection [Array<Integer>, nil] the normalized selection the
  #   rows were drawn with (see {#current_selection})
  # @return [void]
  private def painted_with_selection(selection)
    @painted_selection = selection
  end

  # The current selection, normalized (see {#normalize_selection}).
  #
  # @return [Array<Integer>, nil] [start_id, start_x, end_id, end_x], or
  #   nil when there is no selection
  private def current_selection
    normalize_selection(*@selection_start, *@selection_end) if has_highlight?
  end

  # Clear and redraw every row of the text area from the shown buffer,
  # with the selected region, if any, in reverse video.
  #
  # @return [void]
  private def paint_content
    line_buffer = shown_buffer
    selection = current_selection
    height = content_height

    (0...height).each do |row|
      setpos(content_top + row, 0)
      clrtoeol
      id, entry = line_buffer.line_at_row(row, height)
      next unless entry

      line_text, line_colors = entry
      draw_row(id, line_text, line_colors, selection)
    end
    painted_with_selection(selection)
    noutrefresh
  end

  # Draw one buffer row at the cursor, in the selection highlight where
  # it falls in the selection.
  #
  # @param id [Integer] the row's stable ID
  # @param line_text [String] the row's text
  # @param line_colors [Array<Hash>, nil] the row's color regions
  # @param selection [Array<Integer>, nil] the normalized selection
  #   (see {#normalize_selection}), or nil to draw the row plain
  # @return [void]
  private def draw_row(id, line_text, line_colors, selection)
    without_scrolling do
      if selection && id.between?(selection[0], selection[2])
        draw_line_with_selection(id, line_text, line_colors || [], *selection)
      else
        add_line(line_text, line_colors || [])
      end
    end
  end

  # Whether the text area is one column wide. Rows are wrapped one column
  # narrower than the window (see {#wrap_width}), so they never reach its
  # last column, except here: there is only one column, and every row
  # that isn't blank fills it.
  #
  # @return [Boolean]
  private def one_column?
    maxx == 1
  end

  # Run the block, which draws a row of the text area at the cursor, so
  # that it can't scroll the text area. Writing a scrolling window's
  # bottom-right cell scrolls it up a row in ncurses, which only a window
  # one column wide does here: its scrolling is turned off while the row
  # is drawn, so the cell is written and the cursor stays on it, and
  # turned on again after (text and tabbed windows always scroll: their
  # builders turn it on, and {#scroll_lines} needs it). Other windows
  # draw as they are.
  #
  # @yield draws the row
  # @return [void]
  private def without_scrolling
    return yield unless one_column?

    begin
      scrollok(false)
      yield
    ensure
      scrollok(true)
    end
  end

  # Normalize selection coordinates so start is the older (topmost) endpoint.
  #
  # @param start_id [Integer] starting line ID
  # @param start_x [Integer] starting column
  # @param end_id [Integer] ending line ID
  # @param end_x [Integer] ending column
  # @return [Array<Integer>] normalized [start_id, start_x, end_id, end_x]
  private def normalize_selection(start_id, start_x, end_id, end_x)
    AnchoredSelection.normalize(start_id, start_x, end_id, end_x)
  end

  # Draw a single line with reverse-video highlighting for the selected region.
  #
  # @param id [Integer] stable line ID of the line being drawn
  # @param line_text [String] full text of the line
  # @param line_colors [Array<Hash>] color regions for the line
  # @param start_id [Integer] selection start line ID
  # @param start_x [Integer] selection start column
  # @param end_id [Integer] selection end line ID
  # @param end_x [Integer] selection end column
  # @return [void]
  private def draw_line_with_selection(id, line_text, line_colors, start_id, start_x, end_id, end_x)
    return if line_text.nil?

    sel_start = id == start_id ? start_x : 0
    sel_end = id == end_id ? end_x : line_text.length

    if sel_start > 0
      pre_text = line_text[0...sel_start]
      pre_colors = line_colors.map do |h|
        { start: h[:start], end: [h[:end], sel_start].min, fg: h[:fg], bg: h[:bg], ul: h[:ul] }
      end.select { |h| h[:end] > h[:start] }
      add_line(pre_text, pre_colors)
    end

    if sel_end > sel_start
      selected_text = line_text[sel_start...sel_end] || ''
      attron(Curses::A_REVERSE) { addstr selected_text }
    end

    return unless sel_end < line_text.length

    post_text = line_text[sel_end..-1]
    post_colors = line_colors.map do |h|
      new_start = [h[:start] - sel_end, 0].max
      new_end = h[:end] - sel_end
      { start: new_start, end: new_end, fg: h[:fg], bg: h[:bg], ul: h[:ul] }
    end.select { |h| h[:end] > 0 && h[:end] > h[:start] }
    add_line(post_text, post_colors)
  end
end
