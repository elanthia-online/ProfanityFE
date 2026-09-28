# frozen_string_literal: true

# Viewport shared by windows that show a LineBuffer: append, scroll,
# repaint, selection and link lookup.

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
# here.
module LineBuffered
  # @return [Boolean] whether continuation lines are indented during word wrap
  attr_accessor :indent_word_wrap

  # @return [Boolean] whether a timestamp is appended to each non-empty line
  attr_accessor :time_stamp

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
  # @return [Array<Array(String, Array<Hash>)>] rows, newest first (empty
  #   when no buffer is shown)
  def buffer
    shown_buffer&.lines || []
  end

  # Return the shown buffer's display rows for selection support.
  #
  # @return [Array<Array(String, Array<Hash>)>] rows, newest first (empty
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
  #
  # @param scroll_num [Integer] lines to scroll (negative = up, positive = down)
  # @return [void]
  def scroll(scroll_num)
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
  # It covers the text area's rows, beside them.
  #
  # @return [void]
  def update_scrollbar
    line_buffer = shown_buffer
    return unless line_buffer

    render_scrollbar(line_buffer.length, line_buffer.pos, content_height, top: content_top)
  end

  # Clear (hide) the scrollbar.
  #
  # @return [void]
  def clear_scrollbar
    reset_scrollbar
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
      scroll(-1)
    elsif rel_y >= maxy - 1
      scroll(1)
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
  # selected region, if any, in reverse video.
  #
  # @return [void]
  def repaint
    paint_content
  end

  # Fit every buffer to the window's current size, after a resize.
  # Stored lines are re-wrapped to the new width, keeping the logical
  # line on each buffer's bottom row there, and a view scrolled back past
  # the oldest row of a taller text area moves down onto it. A re-wrap
  # clears the selection: its row IDs no longer exist. The caller
  # repaints.
  #
  # @return [void]
  def rewrap
    width = wrap_width
    height = content_height
    rewrapping = line_buffers.any? { |line_buffer| line_buffer.width != width }
    line_buffers.each do |line_buffer|
      line_buffer.width = width
      line_buffer.pos = line_buffer.pos.clamp(0, [line_buffer.length - height, 0].max)
    end
    return unless rewrapping

    @selection_start = nil
    @selection_end = nil
    # A drag in progress, or the highlight kept after one, is anchored to
    # the old rows too
    SelectionManager.clear_selection if SelectionManager.active_window.equal?(self)
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

  # The buffer whose lines the text area shows.
  #
  # @abstract
  # @return [LineBuffer, nil] the buffer, or nil when nothing is shown
  private def shown_buffer
    raise NotImplementedError, "#{self.class} must implement shown_buffer"
  end

  # Every buffer the window keeps, shown or not.
  #
  # @abstract
  # @return [Array<LineBuffer>]
  private def line_buffers
    raise NotImplementedError, "#{self.class} must implement line_buffers"
  end

  # Append a string to a buffer as one logical line; the buffer wraps it
  # to the window width. When the buffer is shown and live, the new rows
  # are drawn at once; when it is scrolled back, shown or not, the view
  # keeps its place (moving onto the oldest row left if an eviction
  # dropped the rows it reached). A buffer that isn't shown draws
  # nothing, and the block, if given, is called.
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
    length_before = line_buffer.length
    added = line_buffer.push(string, string_colors, indent: effective_indent)
    height = content_height
    if !shown
      # Scrolled back: keep the view in place, as the shown path below
      # does, but draw nothing. Evictions may have dropped rows it reached.
      line_buffer.pos += added unless line_buffer.live?
      line_buffer.pos = line_buffer.pos.clamp(0, [line_buffer.length - height, 0].max)
      yield if block_given?
    elsif line_buffer.live?
      if line_buffer.length < [length_before + added, height].min
        # An eviction left too few rows to fill the text area, so every
        # row moved up: redraw them all
        paint_content
      else
        (added - 1).downto(0).each_with_index do |index, drawn|
          line, line_colors = line_buffer.lines[index]
          draw_newest_line(line, line_colors, length_before + drawn + 1, content_top, height)
        end
      end
    else
      line_buffer.pos += added
      keep_view_on_stored_rows(line_buffer, height)
      update_scrollbar
    end
    return unless shown && line_buffer.live?

    # Re-apply selection highlight if active (new text overwrites it)
    if has_highlight?
      redraw_with_highlight
    else
      noutrefresh
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
      scroll(excess)
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

  # Clear and redraw every row of the text area from the shown buffer,
  # with the selected region, if any, in reverse video.
  #
  # @return [void]
  private def paint_content
    line_buffer = shown_buffer
    start_id, start_x, end_id, end_x = normalize_selection(*@selection_start, *@selection_end) if has_highlight?
    height = content_height

    (0...height).each do |row|
      setpos(content_top + row, 0)
      clrtoeol
      id, entry = line_buffer.line_at_row(row, height)
      next unless entry

      line_text, line_colors = entry
      if start_id && id >= start_id && id <= end_id
        draw_line_with_selection(id, line_text, line_colors || [], start_id, start_x, end_id, end_x)
      else
        add_line(line_text, line_colors || [])
      end
    end
    noutrefresh
  end
end
