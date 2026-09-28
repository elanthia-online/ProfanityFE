# frozen_string_literal: true

# Viewport shared by windows that show a LineBuffer: append, scroll,
# repaint, selection and link lookup.

require_relative '../line_buffer'

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

  # The shown buffer's lines.
  #
  # @return [Array<Array(String, Array<Hash>)>] lines, newest first (empty
  #   when no buffer is shown)
  def buffer
    shown_buffer&.lines || []
  end

  # Return the shown buffer's lines for selection support.
  #
  # @return [Array<Array(String, Array<Hash>)>] lines, newest first (empty
  #   when no buffer is shown)
  def buffer_content
    shown_buffer&.lines || []
  end

  # Return the shown buffer's scroll offset.
  #
  # @return [Integer] number of lines scrolled back from the newest
  def buffer_pos
    shown_buffer&.pos || 0
  end

  # Monotonic count of lines ever appended to the shown buffer. Gives
  # each buffer line a stable ID for selection anchoring
  # (see {AnchoredSelection}).
  #
  # @return [Integer]
  def lines_appended
    shown_buffer&.lines_appended || 0
  end

  # Scroll the shown buffer by the given number of lines.
  # Negative values scroll up (toward older content), positive values scroll
  # down (toward newer content).
  #
  # @param scroll_num [Integer] lines to scroll (negative = up, positive = down)
  # @return [void]
  def scroll(scroll_num)
    line_buffer = shown_buffer
    return unless line_buffer

    height = content_height
    if scroll_num < 0
      moved = line_buffer.scroll_back(scroll_num.abs, height)
      if moved.positive?
        scrl(-moved)
        setpos(content_top, 0)
        draw_buffer_lines(line_buffer.lines, line_buffer.pos + height - 1, moved)
        noutrefresh
      end
      update_scrollbar
    elsif scroll_num > 0
      moved = line_buffer.scroll_forward(scroll_num)
      if moved.positive?
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
  #
  # @return [void]
  def update_scrollbar
    line_buffer = shown_buffer
    return unless line_buffer

    render_scrollbar(line_buffer.length, line_buffer.pos, content_height)
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

  # Append a string to a buffer, word-wrapping it to the window width.
  # When the buffer is shown and live, each new line is drawn at once;
  # when it is shown but scrolled back, the view keeps its place. A
  # buffer that isn't shown only stores the lines, and the block, if
  # given, is called once per stored line.
  #
  # @param line_buffer [LineBuffer] the buffer to append to
  # @param string [String] the text to append
  # @param string_colors [Array<Hash>] color region descriptors
  # @param indent [Boolean, nil] indent continuation lines (nil = window default)
  # @param shown [Boolean] whether the text area shows +line_buffer+
  # @yield once per line stored in a buffer that isn't shown
  # @return [void]
  private def append_string(line_buffer, string, string_colors, indent:, shown:)
    string = buffer_text(string, @time_stamp)
    effective_indent = indent.nil? ? @indent_word_wrap : indent
    wrap_text(string, maxx - 1, string_colors, indent: effective_indent) do |line, line_colors, continuation|
      line_buffer.push(line, line_colors, continuation)
      if !shown
        yield if block_given?
      elsif line_buffer.live?
        draw_newest_line(line, line_colors, line_buffer.length, content_top, content_height)
      else
        line_buffer.pos += 1
        # Scrolled back to the oldest line of a full buffer: that line
        # was just evicted, so move the view down onto the next one
        scroll(1) if line_buffer.pos > (line_buffer.cap - content_height)
        update_scrollbar
      end
    end
    return unless shown && line_buffer.live?

    # Re-apply selection highlight if active (new text overwrites it)
    if has_highlight?
      redraw_with_highlight
    else
      noutrefresh
    end
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
