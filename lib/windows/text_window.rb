# frozen_string_literal: true

# Main scrollable text buffer window with word wrap, timestamps, and selection.

require_relative '../line_buffer'

# Scrollable text buffer window.
#
# Displays a reverse-ordered buffer of word-wrapped lines with optional
# timestamps. Supports keyboard scrolling, scrollbar rendering, and
# mouse-based text selection with copy support.
class TextWindow < BaseWindow
  # @return [Boolean] whether continuation lines are indented during word wrap
  attr_accessor :indent_word_wrap

  # @return [Boolean] whether a timestamp is appended to each non-empty line
  attr_accessor :time_stamp

  # Create a new scrollable text window.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @line_buffer = LineBuffer.new(cap: DEFAULT_BUFFER_SIZE)
    @indent_word_wrap = true
    super
  end

  # The stored lines.
  #
  # @return [Array<Array(String, Array<Hash>)>] the line buffer (newest first)
  def buffer
    @line_buffer.lines
  end

  # Return the line buffer for selection support.
  #
  # @return [Array<Array(String, Array<Hash>)>] the line buffer (newest first)
  def buffer_content
    @line_buffer.lines
  end

  # @return [Integer] monotonic count of lines ever appended to the buffer.
  #   Gives each buffer line a stable ID for selection anchoring
  #   (see {AnchoredSelection}).
  def lines_appended
    @line_buffer.lines_appended
  end

  # @return [Integer] maximum number of lines retained in the buffer
  def max_buffer_size
    @line_buffer.cap
  end

  # Set the maximum number of lines retained in the buffer.
  #
  # @param val [Integer, #to_i] new buffer size limit
  # @return [void]
  def max_buffer_size=(val)
    @line_buffer.cap = val
  end

  # Append a string to the buffer, word-wrapping to the window width.
  # If the window is not scrolled, the new text is rendered immediately;
  # otherwise the scroll position is adjusted.
  #
  # @param string [String] the text to append
  # @param string_colors [Array<Hash>] color region descriptors
  # @return [void]
  def add_string(string, string_colors = [], indent: nil)
    string = buffer_text(string, @time_stamp)
    effective_indent = indent.nil? ? @indent_word_wrap : indent
    wrap_text(string, maxx - 1, string_colors, indent: effective_indent) do |line, line_colors, continuation|
      @line_buffer.push(line, line_colors, continuation)
      if @line_buffer.live?
        draw_newest_line(line, line_colors, @line_buffer.length, 0, maxy)
      else
        @line_buffer.pos += 1
        scroll(1) if @line_buffer.pos > (@line_buffer.cap - maxy)
        update_scrollbar
      end
    end
    return unless @line_buffer.live?

    # Re-apply selection highlight if active (new text overwrites it)
    if has_highlight?
      redraw_with_highlight
    else
      noutrefresh
    end
  end

  # Scroll the buffer by the given number of lines.
  # Negative values scroll up (toward older content), positive values scroll
  # down (toward newer content).
  #
  # @param scroll_num [Integer] lines to scroll (negative = up, positive = down)
  # @return [void]
  def scroll(scroll_num)
    if scroll_num < 0
      moved = @line_buffer.scroll_back(scroll_num.abs, maxy)
      if moved.positive?
        scrl(-moved)
        setpos(0, 0)
        draw_buffer_lines(@line_buffer.lines, @line_buffer.pos + maxy - 1, moved)
        noutrefresh
      end
      update_scrollbar
    elsif scroll_num > 0
      moved = @line_buffer.scroll_forward(scroll_num)
      if moved.positive?
        scrl(moved)
        setpos(maxy - moved, 0)
        draw_buffer_lines(@line_buffer.lines, @line_buffer.pos + moved - 1, moved)
        noutrefresh
      end
    end
    # Selection is anchored to line IDs; re-render so the highlight
    # follows its text to the new scroll position
    redraw_with_highlight if has_highlight?
    update_scrollbar
  end

  # Refresh the scrollbar to reflect current buffer and scroll state.
  #
  # @return [void]
  def update_scrollbar
    render_scrollbar(@line_buffer.length, @line_buffer.pos, maxy)
  end

  # Clear (hide) the scrollbar.
  #
  # @return [void]
  def clear_scrollbar
    reset_scrollbar
  end

  # Check if the most recent non-empty line matches the given prompt text.
  # Used to suppress duplicate bare prompts.
  #
  # @param prompt_text [String] the prompt string to check against
  # @return [Boolean] true if the last non-empty buffer line equals prompt_text
  def duplicate_prompt?(prompt_text)
    @line_buffer.newest_text?(prompt_text)
  end

  # Resolve window-relative coordinates to a stable [line_id, x] anchor.
  # The anchor stays glued to the same text as the buffer grows or scrolls.
  #
  # @param rel_y [Integer] row relative to window top
  # @param rel_x [Integer] column relative to window left
  # @return [Array<Integer>, nil] [line_id, x] anchor, or nil if the buffer is empty
  def selection_anchor_at(rel_y, rel_x)
    id = @line_buffer.id_at_row(rel_y, maxy)
    id ? [id, [rel_x, 0].max] : nil
  end

  # Extract text from the buffer for a selection anchored to stable line IDs.
  # Lines evicted past max_buffer_size are skipped.
  #
  # @param start_id [Integer] starting line ID
  # @param start_x [Integer] starting column
  # @param end_id [Integer] ending line ID
  # @param end_x [Integer] ending column
  # @return [String] the selected text, lines joined by newlines
  def extract_selection(start_id, start_x, end_id, end_x)
    @line_buffer.extract(start_id, start_x, end_id, end_x)
  end

  # Scroll one line when a drag pointer sits at the window's top or
  # bottom edge, extending a selection past the visible area.
  #
  # @param rel_y [Integer] drag row relative to window top
  # @return [Boolean] true if the view actually scrolled
  def drag_auto_scroll(rel_y)
    before = @line_buffer.pos
    if rel_y <= 0
      scroll(-1)
    elsif rel_y >= maxy - 1
      scroll(1)
    end
    @line_buffer.pos != before
  end

  # Redraw all visible lines, applying reverse-video to the selected region.
  # The selection is anchored to stable line IDs, so the highlight follows
  # its text as new lines arrive or the user scrolls.
  #
  # @return [void]
  def redraw_with_highlight
    return unless @selection_start && @selection_end

    repaint
  end

  # Repaint every visible row from the buffer, drawing the selected
  # region, if any, in reverse video.
  #
  # @return [void]
  def repaint
    start_id, start_x, end_id, end_x = normalize_selection(*@selection_start, *@selection_end) if has_highlight?

    (0...maxy).each do |y|
      id, entry = @line_buffer.line_at_row(y, maxy)
      setpos(y, 0)
      clrtoeol
      next unless entry

      line_text, line_colors = entry

      if start_id && id >= start_id && id <= end_id
        draw_line_with_selection(id, line_text, line_colors, start_id, start_x, end_id, end_x)
      else
        add_line(line_text, line_colors)
      end
    end
    noutrefresh
  end

  # Find a clickable link command at the given window-relative coordinates.
  # Scans the color regions of the buffer line at (rel_y, rel_x) for a
  # :cmd entry whose span covers the column.
  #
  # @param rel_y [Integer] row relative to window top
  # @param rel_x [Integer] column relative to window left
  # @return [String, nil] the link command string, or nil if no link at that position
  def link_cmd_at(rel_y, rel_x)
    return nil if rel_y >= @line_buffer.visible_count(maxy)

    _id, entry = @line_buffer.line_at_row(rel_y, maxy)
    return nil unless entry

    _text, colors = entry
    return nil unless colors

    colors.each do |h|
      return h[:cmd] if h[:cmd] && rel_x >= h[:start] && rel_x < h[:end]
    end
    nil
  end
end

BaseWindow.register_type('text') do |height, width, top, left, element, wm|
  next nil unless width > 1

  # Reuse the previous layout's text window for one of this slot's streams,
  # then forget every stream it served so no later slot reuses it too.
  # Only text windows qualify: a sink or tabbed window can't fill a text slot.
  streams = element.attributes['value']&.split(',') || []
  if (window = streams.map { |stream| wm.previous_stream[stream] }.find { |old| old.instance_of?(TextWindow) })
    wm.previous_stream.delete_if { |_stream, old| old.equal?(window) }
    wm.old_windows.delete(window)
  else
    window = TextWindow.new(height, width - 1, top, left)
    window.scrollbar = Curses::Window.new(window.maxy, 1, window.begy, window.begx + window.maxx)
  end
  window.layout = [element.attributes['height'], element.attributes['width'], element.attributes['top'], element.attributes['left']]
  window.scrollok(true)
  window.max_buffer_size = element.attributes['buffer-size'] || 1000
  window.time_stamp = element.attributes['timestamp']
  element.attributes['value'].split(',').each do |str|
    wm.stream[str] = window
  end
  SCROLL_WINDOW.push(window) unless SCROLL_WINDOW.include?(window)
  window
end
