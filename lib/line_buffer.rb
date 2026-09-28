# frozen_string_literal: true

# line_buffer.rb: Line storage and scroll position for text-buffer windows.

require_relative 'anchored_selection'

# The lines of a scrollable text view, its scroll position and its size cap.
#
# Lines are stored newest first (index 0 is the line added last), one
# entry per display row: +[text, colors, continuation]+, where
# +continuation+ is true for the 2nd+ row of a wrapped string. A
# monotonic append counter gives every line a stable ID for selection
# anchoring (see {AnchoredSelection}).
#
# The scroll position {#pos} counts lines scrolled back from the newest
# one (0 = live). Viewport math takes the height of the text area, so
# one buffer serves any window layout: a text window's whole height, or
# the rows below a tab bar.
#
# Pure data: no curses calls, so it can be tested headless. Drawing is
# the window's job.
class LineBuffer
  # @return [Array<Array(String, Array<Hash>, Boolean)>] the stored lines,
  #   newest first
  attr_reader :lines

  # @return [Integer] monotonic count of lines ever added. Gives each
  #   line a stable ID (see {AnchoredSelection}).
  attr_reader :lines_appended

  # @return [Integer] lines scrolled back from the newest one (0 = live)
  attr_accessor :pos

  # @return [Integer] maximum number of lines kept
  attr_reader :cap

  # Create an empty buffer.
  #
  # @param cap [Integer, #to_i] maximum number of lines kept
  def initialize(cap:)
    @lines = []
    @lines_appended = 0
    @pos = 0
    @cap = cap.to_i
  end

  # Set the maximum number of lines kept. Lines already over the new cap
  # are not trimmed here; each later {#push} evicts one oldest line.
  #
  # @param val [Integer, #to_i] new cap
  # @return [void]
  def cap=(val)
    @cap = val.to_i
  end

  # Add a line at the newest end and evict the oldest line if the
  # buffer is over its cap. The scroll position is left alone: a window
  # showing this buffer scrolled back moves {#pos} itself to keep its
  # place.
  #
  # @param text [String] the line text
  # @param colors [Array<Hash>] color regions for the line
  # @param continuation [Boolean] whether the line continues a wrapped string
  # @return [void]
  def push(text, colors, continuation)
    @lines.unshift([text, colors, continuation])
    @lines_appended += 1
    @lines.pop if @lines.length > @cap
  end

  # @return [Integer] number of stored lines
  def length
    @lines.length
  end

  # @return [Boolean] whether no lines are stored
  def empty?
    @lines.empty?
  end

  # @return [Boolean] whether the view is at the newest line (not scrolled back)
  def live?
    @pos.zero?
  end

  # Move the view back toward older lines, stopping when the oldest line
  # reaches the top of a text area of the given height.
  #
  # @param count [Integer] lines to move back (positive)
  # @param height [Integer] rows in the text area
  # @return [Integer] lines actually moved (0 when already at the oldest)
  def scroll_back(count, height)
    count = [count, @lines.length - @pos - height].min
    return 0 unless count.positive?

    @pos += count
    count
  end

  # Move the view forward toward newer lines, stopping at the newest.
  #
  # @param count [Integer] lines to move forward (positive)
  # @return [Integer] lines actually moved (0 when already live)
  def scroll_forward(count)
    count = [count, @pos].min
    return 0 unless count.positive?

    @pos -= count
    count
  end

  # Number of lines shown in a text area of the given height: the
  # height, or fewer when the buffer doesn't reach the top row.
  #
  # @param height [Integer] rows in the text area
  # @return [Integer] visible line count (zero or negative when nothing shows)
  def visible_count(height)
    AnchoredSelection.visible_lines(@lines.length, @pos, height)
  end

  # Line shown on a row of a text area. Lines fill the area from its top
  # row, oldest visible line first.
  #
  # @param row [Integer] row within the text area (0 = top)
  # @param height [Integer] rows in the text area
  # @return [Array(Integer, Array), nil] [stable line ID, line entry], or
  #   nil when no line is shown on that row
  def line_at_row(row, height)
    index = @pos + (visible_count(height) - 1 - row)
    return nil if index.negative? || index >= @lines.length

    [@lines_appended - index, @lines[index]]
  end

  # Stable ID of the line at a row, for anchoring a selection. Rows
  # outside the shown lines clamp to the nearest one.
  #
  # @param row [Integer] row within the text area (0 = top, may be out of range)
  # @param height [Integer] rows in the text area
  # @return [Integer, nil] stable line ID, or nil if nothing is shown
  def id_at_row(row, height)
    AnchoredSelection.id_at_row(row, lines_appended: @lines_appended, buffer_pos: @pos,
                                     buffer_length: @lines.length, height: height)
  end

  # Text of a selection anchored to stable line IDs. Evicted lines are
  # skipped.
  #
  # @param start_id [Integer] starting line ID
  # @param start_x [Integer] starting column
  # @param end_id [Integer] ending line ID
  # @param end_x [Integer] ending column
  # @return [String] the selected text, logical lines joined by newlines
  def extract(start_id, start_x, end_id, end_x)
    AnchoredSelection.extract(@lines, @lines_appended, start_id, start_x, end_id, end_x)
  end

  # Whether the newest non-empty line has exactly the given text. Used
  # to suppress a repeated bare prompt.
  #
  # @param text [String] the text to compare
  # @return [Boolean, nil] false for an empty buffer, nil when every line
  #   is empty, else whether the newest non-empty line equals +text+
  def newest_text?(text)
    return false if @lines.empty?

    recent_line = @lines.find { |entry| entry[0] && !entry[0].empty? }
    recent_line && recent_line[0] == text
  end
end
