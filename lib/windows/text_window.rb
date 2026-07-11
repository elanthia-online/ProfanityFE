# frozen_string_literal: true

# Main scrollable text buffer window with word wrap, timestamps, and selection.

# Scrollable text buffer window.
#
# Displays a reverse-ordered buffer of word-wrapped lines with optional
# timestamps. Supports keyboard scrolling, scrollbar rendering, and
# mouse-based text selection with copy support.
class TextWindow < BaseWindow
  # @return [Array<Array(String, Array<Hash>)>] the line buffer (newest first)
  attr_reader :buffer

  # @return [Integer] maximum number of lines retained in the buffer
  attr_reader :max_buffer_size

  # @return [Boolean] whether continuation lines are indented during word wrap
  attr_accessor :indent_word_wrap

  # @return [Boolean] whether a timestamp is appended to each non-empty line
  attr_accessor :time_stamp

  # @return [Integer] monotonic count of lines ever appended to the buffer.
  #   Gives each buffer line a stable ID for selection anchoring
  #   (see {AnchoredSelection}).
  attr_reader :lines_appended

  # Create a new scrollable text window.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @buffer = []
    @buffer_pos = 0
    @lines_appended = 0
    @max_buffer_size = DEFAULT_BUFFER_SIZE
    @indent_word_wrap = true
    super
  end

  # Return the line buffer for selection support.
  #
  # @return [Array<Array(String, Array<Hash>)>] the line buffer (newest first)
  def buffer_content
    @buffer
  end

  # Set the maximum number of lines retained in the buffer.
  #
  # @param val [Integer, #to_i] new buffer size limit
  # @return [void]
  def max_buffer_size=(val)
    @max_buffer_size = val.to_i
  end

  # Append a string to the buffer, word-wrapping to the window width.
  # If the window is not scrolled, the new text is rendered immediately;
  # otherwise the scroll position is adjusted.
  #
  # @param string [String] the text to append
  # @param string_colors [Array<Hash>] color region descriptors
  # @return [void]
  def add_string(string, string_colors = [], indent: nil)
    string += format_timestamp if @time_stamp && string && !string.chomp.empty?
    effective_indent = indent.nil? ? @indent_word_wrap : indent
    wrap_text(string, maxx - 1, string_colors, indent: effective_indent) do |line, line_colors|
      @buffer.unshift([line, line_colors])
      @lines_appended += 1
      @buffer.pop if @buffer.length > @max_buffer_size
      if @buffer_pos == 0
        addstr "\n" unless line.chomp.empty?
        add_line(line, line_colors)
      else
        @buffer_pos += 1
        scroll(1) if @buffer_pos > (@max_buffer_size - maxy)
        update_scrollbar
      end
    end
    return unless @buffer_pos == 0

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
      scroll_num = 0 - (@buffer.length - @buffer_pos - maxy) if (@buffer_pos + maxy + scroll_num.abs) >= @buffer.length
      if scroll_num < 0
        @buffer_pos += scroll_num.abs
        scrl(scroll_num)
        setpos(0, 0)
        pos = @buffer_pos + maxy - 1
        scroll_num.abs.times do
          add_line(@buffer[pos][0], @buffer[pos][1])
          addstr "\n"
          pos -= 1
        end
        noutrefresh
      end
      update_scrollbar
    elsif scroll_num > 0
      if @buffer_pos > 0
        scroll_num = @buffer_pos if (@buffer_pos - scroll_num) < 0
        @buffer_pos -= scroll_num
        scrl(scroll_num)
        setpos(maxy - scroll_num, 0)
        pos = @buffer_pos + scroll_num - 1
        (scroll_num - 1).times do
          add_line(@buffer[pos][0], @buffer[pos][1])
          addstr "\n"
          pos -= 1
        end
        add_line(@buffer[pos][0], @buffer[pos][1])
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
    render_scrollbar(@buffer.length, @buffer_pos, maxy)
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
    return false if @buffer.empty?

    recent_line = @buffer.find { |entry| entry[0] && !entry[0].empty? }
    recent_line && recent_line[0] == prompt_text
  end

  # Resolve window-relative coordinates to a stable [line_id, x] anchor.
  # The anchor stays glued to the same text as the buffer grows or scrolls.
  #
  # @param rel_y [Integer] row relative to window top
  # @param rel_x [Integer] column relative to window left
  # @return [Array<Integer>, nil] [line_id, x] anchor, or nil if the buffer is empty
  def selection_anchor_at(rel_y, rel_x)
    id = AnchoredSelection.id_at_row(rel_y, lines_appended: @lines_appended,
                                            buffer_pos: @buffer_pos,
                                            buffer_length: @buffer.length,
                                            height: maxy)
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
    AnchoredSelection.extract(@buffer, @lines_appended, start_id, start_x, end_id, end_x)
  end

  # Redraw all visible lines, applying reverse-video to the selected region.
  # The selection is anchored to stable line IDs, so the highlight follows
  # its text as new lines arrive or the user scrolls.
  #
  # @return [void]
  def redraw_with_highlight
    return unless @selection_start && @selection_end

    start_id, start_x, end_id, end_x = normalize_selection(*@selection_start, *@selection_end)
    visible_lines = [@buffer.length - @buffer_pos, maxy].min

    (0...maxy).each do |y|
      buffer_idx = @buffer_pos + (visible_lines - 1 - y)
      setpos(y, 0)
      clrtoeol
      next if buffer_idx >= @buffer.length || buffer_idx < 0

      line_text, line_colors = @buffer[buffer_idx]
      id = @lines_appended - buffer_idx

      if id >= start_id && id <= end_id
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
    visible_lines = [@buffer.length - @buffer_pos, maxy].min
    return nil if rel_y >= visible_lines

    buffer_idx = @buffer_pos + (visible_lines - 1 - rel_y)
    return nil if buffer_idx < 0 || buffer_idx >= @buffer.length

    _text, colors = @buffer[buffer_idx]
    return nil unless colors

    colors.each do |h|
      return h[:cmd] if h[:cmd] && rel_x >= h[:start] && rel_x < h[:end]
    end
    nil
  end
end

BaseWindow.register_type('text') do |height, width, top, left, element, wm|
  next nil unless width > 1

  if element.attributes['value'] && (window = wm.previous_stream[wm.previous_stream.keys.find do |key|
    element.attributes['value'].split(',').include?(key)
  end])
    wm.previous_stream[element.attributes['value']] = nil
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
  SCROLL_WINDOW.push(window)
  window
end
