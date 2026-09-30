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
# A buffer nobody shows (a tabbed window's hidden tab) can put off
# re-wrapping to a new width ({#fit} with +later: true+) and take lines
# without wrapping them ({#push_unseen}). Until something reads its
# rows, it keeps its view as the logical line on its bottom row (and how
# many of that line's rows are below the bottom row), so a view kept in
# place across many resizes and lines ends up where re-wrapping at every
# step would have put it. The first read of its rows ({#lines},
# {#length}, {#pos} and the rest) wraps every line to {#width} once.
#
# Pure data: no curses calls, so it can be tested headless. Drawing is
# the window's job (see {LineBuffered}).
class LineBuffer
  # @return [Integer] maximum number of logical lines kept
  attr_reader :cap

  # @return [Integer] column width lines are wrapped to, including a
  #   width a re-wrap was put off to (see {#fit})
  attr_reader :width

  # Create an empty buffer.
  #
  # @param cap [Integer, #to_i] maximum number of logical lines kept
  # @param width [Integer] column width lines are wrapped to
  def initialize(cap:, width:)
    @lines = []
    # [StyledText, indent, row count, width the rows were counted at],
    # newest first
    @logical = []
    @logical_added = 0
    @lines_appended = 0
    @pos = 0
    @cap = cap.to_i
    @width = width
    # While a re-wrap is put off (see #fit), @lines and @pos are out of
    # date and @view holds the view: nil when live, else [serial of the
    # logical line on the bottom row, rows of it below the bottom row],
    # where a line's serial is @logical_added when it was added, less 1
    @unwrapped = false
    @view = nil
  end

  # @return [Array<Array(String, Array<Hash>, Boolean)>] the display rows,
  #   newest first: each is its text, its color runs, and whether it
  #   continues the row before it (a wrapped line's second and later rows)
  def lines
    wrap_now
    @lines
  end

  # @return [Integer] monotonic count of rows ever added. Gives each row
  #   a stable ID (see {AnchoredSelection}).
  def lines_appended
    wrap_now
    @lines_appended
  end

  # @return [Integer] rows scrolled back from the newest one (0 = live)
  def pos
    wrap_now
    @pos
  end

  # @param val [Integer] rows scrolled back from the newest one (0 = live)
  # @return [void]
  def pos=(val)
    wrap_now
    @pos = val
  end

  # Set the maximum number of logical lines kept, evicting the oldest
  # logical lines, all their rows, that are over the new cap. The scroll
  # position is left alone, as in {#push}: rows are evicted from the
  # oldest end, so the rows it counts don't move, but it may now reach
  # past the oldest row left.
  #
  # @param val [Integer, #to_i] new cap
  # @return [void]
  def cap=(val)
    @cap = val.to_i
    evict_over_cap
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

    wrap_now
    bottom = logical_index_at_row(@pos)
    @width = val
    wrap_rows
    @pos = bottom ? rows_newer_than(bottom) : 0
  end

  # Fit the buffer to a text area of a new size: re-wrap it to +width+
  # (see {#width=}), then move a view scrolled back past the oldest row
  # down onto it (a view reaches no further back than the oldest row at
  # the top of the text area).
  #
  # With +later: true+, for a buffer nobody shows, the re-wrap is put
  # off until its rows are next read, and only the view is kept: what
  # those rows and {#pos} are then is what fitting now would have made
  # them, whatever {#fit} and {#push_unseen} calls come in between.
  #
  # @param width [Integer] new width in columns
  # @param height [Integer] rows in the text area
  # @param later [Boolean] whether to put off the re-wrap
  # @return [void]
  def fit(width, height, later: false)
    if later && (@unwrapped || width != @width)
      defer_width(width)
      keep_view_in(height)
    else
      self.width = width
      wrap_now
      @pos = @pos.clamp(0, [@lines.length - height, 0].max)
    end
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
    wrap_now
    styled = StyledText.new(text, colors)
    count = add_rows(styled, indent)
    @lines_appended += count
    @logical.unshift([styled, indent, count, @width])
    @logical_added += 1
    evict_over_cap
    count
  end

  # Add a logical line to a buffer nobody shows, as {#push} does, and
  # keep its view: a view scrolled back keeps its place (the rows it
  # counts move back by the new line's rows) and, after an eviction,
  # stays within a text area of +height+ rows as {#fit} keeps it. A
  # buffer whose re-wrap was put off (see {#fit}) doesn't wrap the line
  # now either.
  #
  # @param text [String] the line text
  # @param colors [Array<Hash>] color regions for the line
  # @param indent [Boolean] whether continuation rows are indented
  # @param height [Integer] rows in the text area
  # @return [void]
  def push_unseen(text, colors, indent:, height:)
    if @unwrapped
      @logical.unshift([StyledText.new(text, colors), indent, nil, nil])
      @logical_added += 1
      evict_over_cap
      keep_view_in(height)
    else
      added = push(text, colors, indent: indent)
      @pos += added unless @pos.zero?
      @pos = @pos.clamp(0, [length - height, 0].max)
    end
  end

  # @return [Integer] number of stored rows
  def length
    wrap_now
    @lines.length
  end

  # @return [Boolean] whether no rows are stored
  def empty?
    @logical.empty?
  end

  # @return [Boolean] whether the view is at the newest row (not scrolled back)
  def live?
    pos.zero?
  end

  # Move the view back toward older rows, stopping when the oldest row
  # reaches the top of a text area of the given height.
  #
  # @param count [Integer] rows to move back (positive)
  # @param height [Integer] rows in the text area
  # @return [Integer] rows actually moved (0 when already at the oldest)
  def scroll_back(count, height)
    wrap_now
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
    wrap_now
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
    wrap_now
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
    wrap_now
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
    wrap_now
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
    wrap_now
    AnchoredSelection.extract(@lines, @lines_appended, start_id, start_x, end_id, end_x)
  end

  # Whether the newest non-empty row has exactly the given text. Used
  # to suppress a repeated bare prompt.
  #
  # @param text [String] the text to compare
  # @return [Boolean, nil] false for an empty buffer, nil when every row
  #   is empty, else whether the newest non-empty row equals +text+
  def newest_text?(text)
    return false if @logical.empty?

    recent_line = newest_row { |entry| entry[0] && !entry[0].empty? }
    recent_line && recent_line[0] == text
  end

  # The newest row the block accepts. A buffer whose re-wrap was put off
  # (see {#fit}) wraps only its newest lines, up to the one holding that
  # row, to find it.
  #
  # @yieldparam row [Array(String, Array<Hash>, Boolean)] a row, as in
  #   {#lines}, newest first
  # @yieldreturn [Boolean] whether this is the row wanted
  # @return [Array(String, Array<Hash>, Boolean), nil] the row, or nil
  #   when the block accepts none
  def newest_row
    return @lines.find { |row| yield row } unless @unwrapped

    @logical.each do |styled, indent|
      rows = styled.wrap(@width, indent: indent)
      (rows.length - 1).downto(0) do |index|
        row = [rows[index].text, rows[index].runs, index.positive?]
        return row if yield row
      end
    end
    nil
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

  # Evict the oldest logical lines, all their rows, while the buffer is
  # over its cap. A cap below zero keeps nothing, like a cap of zero.
  #
  # @return [void]
  def evict_over_cap
    excess = @logical.length - @cap
    return unless excess.positive?

    evicted = @logical.pop(excess)
    @lines.pop(evicted.sum { |entry| entry[2] }) unless @unwrapped
  end

  # Wrap every stored line to {#width} again, rebuilding the rows under
  # new IDs.
  #
  # @return [void]
  def wrap_rows
    @lines = []
    @logical.reverse_each do |entry|
      entry[2] = add_rows(entry[0], entry[1])
      entry[3] = @width
    end
    @lines_appended += @lines.length
  end

  # Number of rows in the newest +count+ logical lines.
  #
  # @param count [Integer] logical lines, newest first
  # @return [Integer]
  def rows_newer_than(count)
    @logical.first(count).sum { |entry| entry[2] }
  end

  # Do the re-wrap {#fit} put off, if any: wrap every line to {#width}
  # and set {#pos} to the view kept meanwhile.
  #
  # @return [void]
  def wrap_now
    return unless @unwrapped

    @unwrapped = false
    wrap_rows
    @pos = 0
    if @view
      index = logical_index(@view[0])
      @pos = (index < @logical.length ? rows_newer_than(index) : @lines.length) + @view[1]
    end
    @view = nil
  end

  # Put off re-wrapping to +val+ (see {#fit}): keep the view as the
  # logical line on the bottom row, and where in it, and move it as
  # {#width=} would.
  #
  # @param val [Integer] new width in columns
  # @return [void]
  def defer_width(val)
    unless @unwrapped
      index = logical_index_at_row(@pos) || @logical.length
      offset = @pos - rows_newer_than(index)
      view_at(index, offset)
      @unwrapped = true
      @lines = nil
    end
    return if val == @width

    @width = val
    return unless @view

    # As #width=: the bottom logical line keeps the bottom row, with its
    # newest row there; past the oldest row the view goes live
    index = logical_index(@view[0])
    if index < @logical.length
      view_at(index, 0)
    else
      @view = nil
    end
  end

  # While a re-wrap is put off, move a view that reaches past the oldest
  # row of a text area of +height+ rows down onto it, as {#fit} does: a
  # view reaches back no further than the oldest row at the top of the
  # text area, and goes live when every row fits in it. Rows are counted
  # from the oldest line only until they fill the text area, so only
  # that many lines are wrapped.
  #
  # @param height [Integer] rows in the text area
  # @return [void]
  def keep_view_in(height)
    return unless @view

    bottom = logical_index(@view[0])
    if bottom <= @logical.length
      # Rows from the oldest one up to the bottom row; the view has room
      # once they fill the text area
      index = @logical.length
      rows = 0
      while index > bottom && rows < height
        index -= 1
        rows += row_count(@logical[index])
      end
      return if index > bottom || rows - @view[1] >= height
    end

    # The bottom row moves to the height-th row from the oldest one
    index = @logical.length
    rows = 0
    while rows < height
      return @view = nil if index.zero?

      index -= 1
      rows += row_count(@logical[index])
    end
    view_at(index, rows - height)
  end

  # Rows a logical line wraps to at {#width}, counted once per width.
  #
  # @param entry [Array] a logical line entry
  # @return [Integer]
  def row_count(entry)
    unless entry[3] == @width
      entry[2] = entry[0].wrap(@width, indent: entry[1]).length
      entry[3] = @width
    end
    entry[2]
  end

  # Set the view kept while a re-wrap is put off.
  #
  # @param index [Integer] logical line on the bottom row, newest first
  # @param offset [Integer] rows of it below the bottom row
  # @return [void]
  def view_at(index, offset)
    @view = index.zero? && offset.zero? ? nil : [@logical_added - 1 - index, offset]
  end

  # Current index (newest first) of the logical line with a serial.
  #
  # @param serial [Integer] the line's serial (see #initialize)
  # @return [Integer] its index; at least the number of stored lines when
  #   it was evicted
  def logical_index(serial)
    @logical_added - 1 - serial
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
