# frozen_string_literal: true

# line_buffer.rb: Line storage and scroll position for text-buffer windows.

require_relative 'anchored_selection'
require_relative 'styled_text'

# The lines of a scrollable text view, its scroll position and its size cap.
#
# The buffer stores logical lines: each string added, unwrapped, with its
# color runs and whether its continuation rows are indented. The display
# rows are derived from them, word-wrapped to {#width}, and kept newest
# first in {#lines} (index 0 is the row added last), one entry per row:
# +[text, colors, continuation]+, where +continuation+ is true for the
# 2nd+ row of a wrapped line. A monotonic row counter gives every row a
# stable ID for selection anchoring (see {AnchoredSelection}).
#
# The cap counts logical lines, and eviction drops the oldest logical
# line with all its rows, never part of one.
#
# The scroll position {#pos} counts rows scrolled back from the newest
# one (0 = live). Viewport math takes the height of the text area, so
# one buffer serves any window layout: a text window's whole height, or
# the rows below a tab bar.
#
# Pure data: no curses calls, so it can be tested headless. Drawing is
# the window's job (see {LineBuffered}).
class LineBuffer
  # @return [Array<Array(String, Array<Hash>, Boolean)>] the display rows,
  #   newest first
  attr_reader :lines

  # @return [Integer] monotonic count of rows ever added. Gives each row
  #   a stable ID (see {AnchoredSelection}).
  attr_reader :lines_appended

  # @return [Integer] rows scrolled back from the newest one (0 = live)
  attr_accessor :pos

  # @return [Integer] maximum number of logical lines kept
  attr_reader :cap

  # @return [Integer] column width new lines are wrapped to
  attr_reader :width

  # Create an empty buffer.
  #
  # @param cap [Integer, #to_i] maximum number of logical lines kept
  # @param width [Integer] column width lines are wrapped to
  def initialize(cap:, width:)
    @lines = []
    @logical = [] # [StyledText, indent, row count], newest first
    @lines_appended = 0
    @pos = 0
    @cap = cap.to_i
    @width = width
  end

  # Set the maximum number of logical lines kept. Lines already over the
  # new cap are not trimmed here; each later {#push} evicts one oldest
  # logical line.
  #
  # @param val [Integer, #to_i] new cap
  # @return [void]
  def cap=(val)
    @cap = val.to_i
  end

  # Re-wrap every stored line to a new width, rebuilding the rows. The
  # logical line on the row at {#pos} (the bottom row of a full text
  # area) stays there: {#pos} moves to its last row. The rebuilt rows get
  # new IDs, so anchors to the old rows match nothing. Does nothing when
  # the width is unchanged.
  #
  # @param val [Integer] new width in columns
  # @return [void]
  def width=(val)
    return if val == @width

    bottom = logical_index_at_row(@pos)
    @width = val
    @lines = []
    @logical.reverse_each do |entry|
      entry[2] = add_rows(entry[0], entry[1])
    end
    @lines_appended += @lines.length
    @pos = bottom ? @logical.first(bottom).sum { |entry| entry[2] } : 0
  end

  # Add a logical line at the newest end, wrapped to {#width}, and evict
  # the oldest logical line, all its rows, if the buffer is over its
  # cap. The scroll position is left alone: a window showing this buffer
  # scrolled back moves {#pos} itself to keep its place.
  #
  # @param text [String] the line text
  # @param colors [Array<Hash>] color regions for the line
  # @param indent [Boolean] whether continuation rows are indented
  # @return [Integer] number of rows the line was wrapped to
  def push(text, colors, indent:)
    styled = StyledText.new(text, colors)
    count = add_rows(styled, indent)
    @lines_appended += count
    @logical.unshift([styled, indent, count])
    @lines.pop(@logical.pop[2]) if @logical.length > @cap
    count
  end

  # @return [Integer] number of stored rows
  def length
    @lines.length
  end

  # @return [Boolean] whether no rows are stored
  def empty?
    @lines.empty?
  end

  # @return [Boolean] whether the view is at the newest row (not scrolled back)
  def live?
    @pos.zero?
  end

  # Move the view back toward older rows, stopping when the oldest row
  # reaches the top of a text area of the given height.
  #
  # @param count [Integer] rows to move back (positive)
  # @param height [Integer] rows in the text area
  # @return [Integer] rows actually moved (0 when already at the oldest)
  def scroll_back(count, height)
    count = [count, @lines.length - @pos - height].min
    return 0 unless count.positive?

    @pos += count
    count
  end

  # Move the view forward toward newer rows, stopping at the newest.
  #
  # @param count [Integer] rows to move forward (positive)
  # @return [Integer] rows actually moved (0 when already live)
  def scroll_forward(count)
    count = [count, @pos].min
    return 0 unless count.positive?

    @pos -= count
    count
  end

  # Number of buffer rows shown in a text area of the given height: the
  # height, or fewer when the buffer doesn't reach the top row.
  #
  # @param height [Integer] rows in the text area
  # @return [Integer] visible row count (zero or negative when nothing shows)
  def visible_count(height)
    AnchoredSelection.visible_lines(@lines.length, @pos, height)
  end

  # Buffer row shown on a row of a text area. Rows fill the area from
  # its top, oldest visible row first.
  #
  # @param row [Integer] row within the text area (0 = top)
  # @param height [Integer] rows in the text area
  # @return [Array(Integer, Array), nil] [stable row ID, row entry], or
  #   nil when no row is shown there
  def line_at_row(row, height)
    index = @pos + (visible_count(height) - 1 - row)
    return nil if index.negative? || index >= @lines.length

    [@lines_appended - index, @lines[index]]
  end

  # Stable ID of the buffer row shown on a row, for anchoring a
  # selection. Rows outside the shown ones clamp to the nearest one.
  #
  # @param row [Integer] row within the text area (0 = top, may be out of range)
  # @param height [Integer] rows in the text area
  # @return [Integer, nil] stable row ID, or nil if nothing is shown
  def id_at_row(row, height)
    AnchoredSelection.id_at_row(row, lines_appended: @lines_appended, buffer_pos: @pos,
                                     buffer_length: @lines.length, height: height)
  end

  # Text of a selection anchored to stable row IDs. Evicted rows are
  # skipped.
  #
  # @param start_id [Integer] starting row ID
  # @param start_x [Integer] starting column
  # @param end_id [Integer] ending row ID
  # @param end_x [Integer] ending column
  # @return [String] the selected text, logical lines joined by newlines
  def extract(start_id, start_x, end_id, end_x)
    AnchoredSelection.extract(@lines, @lines_appended, start_id, start_x, end_id, end_x)
  end

  # Whether the newest non-empty row has exactly the given text. Used
  # to suppress a repeated bare prompt.
  #
  # @param text [String] the text to compare
  # @return [Boolean, nil] false for an empty buffer, nil when every row
  #   is empty, else whether the newest non-empty row equals +text+
  def newest_text?(text)
    return false if @lines.empty?

    recent_line = @lines.find { |entry| entry[0] && !entry[0].empty? }
    recent_line && recent_line[0] == text
  end

  private

  # Wrap a logical line to {#width} and add its rows at the newest end.
  #
  # @param styled [StyledText] the line
  # @param indent [Boolean] whether continuation rows are indented
  # @return [Integer] number of rows added
  def add_rows(styled, indent)
    rows = styled.wrap(@width, indent: indent)
    rows.each_with_index { |row, idx| @lines.unshift([row.text, row.runs, idx.positive?]) }
    rows.length
  end

  # Index (newest first) of the logical line a row belongs to.
  #
  # @param row_index [Integer] row index, newest first
  # @return [Integer, nil] logical line index, or nil past the oldest row
  def logical_index_at_row(row_index)
    rows = 0
    @logical.each_with_index do |entry, index|
      rows += entry[2]
      return index if row_index < rows
    end
    nil
  end
end
