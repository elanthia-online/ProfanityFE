# frozen_string_literal: true

# anchored_selection.rb: Stable line-ID coordinate math for text selection.

# Pure coordinate math for buffer-anchored text selection.
#
# Text window buffers are unshift-based (newest line at index 0), so a
# line's buffer index shifts every time new text arrives. Anchoring a
# selection to a screen row or buffer index therefore silently drifts
# onto different text mid-drag. Instead, each window keeps a monotonic
# count of lines ever appended (+lines_appended+), which gives every
# buffer line a stable ID:
#
#   id    = lines_appended - buffer_index   (1 = oldest, grows with new lines)
#   index = lines_appended - id
#
# IDs never change once assigned, so a selection stored as
# (start_id, start_x, end_id, end_x) stays glued to the same text no
# matter how much output arrives or how far the user scrolls.
#
# All functions here are pure (no curses, no window state) so the
# row <-> ID mapping and extraction logic can be unit tested headless.
module AnchoredSelection
  module_function

  # Number of buffer lines currently visible in the content area.
  # Accounts for partially-filled buffers (fewer lines than rows).
  #
  # @param buffer_length [Integer] total lines in the buffer
  # @param buffer_pos [Integer] scroll offset from the bottom (0 = live)
  # @param height [Integer] content-area height in rows
  # @return [Integer] visible line count (may be zero or negative when empty)
  def visible_lines(buffer_length, buffer_pos, height)
    [buffer_length - buffer_pos, height].min
  end

  # Stable ID of the buffer line displayed at a content-area row.
  # Rows outside the populated area are clamped to the nearest line so
  # drags that wander above/below the text still anchor sensibly.
  #
  # @param row [Integer] content-area row (0 = top)
  # @param lines_appended [Integer] monotonic append counter
  # @param buffer_pos [Integer] scroll offset from the bottom
  # @param buffer_length [Integer] total lines in the buffer
  # @param height [Integer] content-area height in rows
  # @return [Integer, nil] stable line ID, or nil if the buffer is empty
  def id_at_row(row, lines_appended:, buffer_pos:, buffer_length:, height:)
    visible = visible_lines(buffer_length, buffer_pos, height)
    return nil if visible <= 0

    row = row.clamp(0, visible - 1)
    index = buffer_pos + (visible - 1 - row)
    return nil if index.negative? || index >= buffer_length

    lines_appended - index
  end

  # Content-area row where a stable line ID is currently displayed.
  #
  # @param id [Integer] stable line ID
  # @param lines_appended [Integer] monotonic append counter
  # @param buffer_pos [Integer] scroll offset from the bottom
  # @param buffer_length [Integer] total lines in the buffer
  # @param height [Integer] content-area height in rows
  # @return [Integer, nil] row (0 = top), or nil if scrolled out of view
  def row_of_id(id, lines_appended:, buffer_pos:, buffer_length:, height:)
    visible = visible_lines(buffer_length, buffer_pos, height)
    return nil if visible <= 0

    index = lines_appended - id
    return nil if index.negative? || index >= buffer_length

    row = visible - 1 - (index - buffer_pos)
    return nil if row.negative? || row >= visible

    row
  end

  # Normalize a selection so the start is the older (topmost) endpoint.
  # Smaller IDs are older lines, which render above newer ones.
  #
  # @param start_id [Integer] anchor line ID
  # @param start_x [Integer] anchor column
  # @param end_id [Integer] endpoint line ID
  # @param end_x [Integer] endpoint column
  # @return [Array<Integer>] [start_id, start_x, end_id, end_x] ordered oldest-first
  def normalize(start_id, start_x, end_id, end_x)
    if start_id > end_id || (start_id == end_id && start_x > end_x)
      [end_id, end_x, start_id, start_x]
    else
      [start_id, start_x, end_id, end_x]
    end
  end

  # Extract the selected text from a buffer by stable line IDs.
  # Lines that have been evicted (past max buffer size) or not yet
  # appended are skipped; column bounds are clamped to line length.
  #
  # Buffer entries may carry a wrap-continuation flag at index 2 (set by
  # BaseWindow#wrap_text). Consecutive selected display lines that belong
  # to one logical line are rejoined without the hard wrap: the previous
  # piece keeps its break whitespace (StyledText#wrap leaves it there) and
  # the continuation's artificial indent is stripped, so copied text has
  # no mid-sentence line breaks.
  #
  # @param buffer [Array<Array(String, Array<Hash>, Boolean)>] line buffer, newest first
  # @param lines_appended [Integer] monotonic append counter
  # @param start_id [Integer] anchor line ID
  # @param start_x [Integer] anchor column
  # @param end_id [Integer] endpoint line ID
  # @param end_x [Integer] endpoint column
  # @return [String] selected text, logical lines joined by newlines
  def extract(buffer, lines_appended, start_id, start_x, end_id, end_x)
    start_id, start_x, end_id, end_x = normalize(start_id, start_x, end_id, end_x)

    lines = []
    prev_id = nil
    (start_id..end_id).each do |id|
      index = lines_appended - id
      next if index.negative? || index >= buffer.length

      entry = buffer[index]
      text = entry[0] || ''
      from = id == start_id ? start_x : 0
      to = id == end_id ? end_x : text.length
      from = from.clamp(0, text.length)
      to = to.clamp(from, text.length)
      piece = text[from...to]

      if entry[2] && prev_id == id - 1 && !lines.empty?
        lines[-1] += piece.lstrip
      else
        lines << piece
      end
      prev_id = id
    end
    lines.join("\n")
  end

  # Text of the buffer line with the given stable ID.
  #
  # @param buffer [Array<Array(String, Array<Hash>)>] line buffer, newest first
  # @param lines_appended [Integer] monotonic append counter
  # @param id [Integer] stable line ID
  # @return [String, nil] line text, or nil if evicted / never appended
  def line_at(buffer, lines_appended, id)
    index = lines_appended - id
    return nil if index.negative? || index >= buffer.length

    buffer[index][0]
  end

  # Span of the whitespace-delimited word at column x, for double-click
  # word selection.
  #
  # @param text [String] the line text
  # @param x [Integer] column within the line
  # @return [Array<Integer>, nil] [from, to) span, or nil if the line is
  #   empty or the column is on whitespace
  def word_span(text, x)
    return nil if text.nil? || text.empty?

    x = x.clamp(0, text.length - 1)
    return nil if text[x].match?(/\s/)

    from = x
    from -= 1 while from.positive? && !text[from - 1].match?(/\s/)
    to = x + 1
    to += 1 while to < text.length && !text[to].match?(/\s/)
    [from, to]
  end

  # IDs of the first and last display lines of the logical (unwrapped)
  # line containing the given ID, for triple-click line selection.
  # Walks continuation flags backward to the wrap start and forward to
  # the last continuation, stopping at evicted/missing lines.
  #
  # @param buffer [Array<Array(String, Array<Hash>, Boolean)>] line buffer, newest first
  # @param lines_appended [Integer] monotonic append counter
  # @param id [Integer] stable line ID anywhere within the logical line
  # @return [Array<Integer>] [first_id, last_id]
  def logical_line_span(buffer, lines_appended, id)
    continuation = lambda do |line_id|
      index = lines_appended - line_id
      index >= 0 && index < buffer.length && buffer[index][2]
    end
    present = lambda do |line_id|
      index = lines_appended - line_id
      index >= 0 && index < buffer.length
    end

    first = id
    first -= 1 while continuation.call(first) && present.call(first - 1)
    last = id
    last += 1 while continuation.call(last + 1)
    [first, last]
  end
end
