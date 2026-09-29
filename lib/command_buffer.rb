# frozen_string_literal: true

# Single-line command buffer with horizontal scrolling, kill ring, and history.
# Wraps a Curses::Window for editing; all screen updates use noutrefresh.
#
# Every mutation or cursor move ends in a single repaint (+render+) that
# clamps the horizontal scroll offset so the cursor is visible and redraws
# the visible slice of the text. There is no incremental insch/delch
# bookkeeping to drift out of sync with the buffer.

require_relative 'command_history'
require_relative 'kill_ring'
require_relative 'string_classification'
using StringClassification

# Command-line input buffer backed by a Curses::Window.
#
# Provides single-line editing with horizontal scrolling when the text
# exceeds the window width. Cursor movement, deletion, word-level
# operations, kill/yank (via KillRing), and command history are all
# supported.
#
# History has two parts. The lines sent are kept in a {CommandHistory}
# ({#history}, {#recent_command}), which the resend keys and autocomplete
# read. The up and down arrows browse a separate list: every line sent is
# added to it too, and it also keeps what browsing leaves behind, edits
# left in recalled entries and lines saved by the down arrow. Neither of
# those is ever added to the lines sent.
#
# The window shows +text[offset, maxx]+ on row 0 with the cursor at
# column +pos - offset+. The offset is recomputed after every change:
# the cursor always stays within columns 0..maxx-1, and the view never
# stays scrolled past what the text needs (so deleting text scrolls
# hidden leading text back into view). Widths are counted in characters;
# double-width characters are not accounted for.
#
# All cursor and editing methods call +noutrefresh+ on the underlying
# window but never call +Curses.doupdate+; the caller is responsible
# for flushing the virtual screen to the terminal, with {#flush_screen}
# on the input path.
#
# @example Basic usage
#   buf = CommandBuffer.new
#   buf.window = Curses::Window.new(1, Curses.cols, Curses.lines - 1, 0)
#   buf.put_ch('h')
#   buf.put_ch('i')
#   cmd = buf.clear_and_get  #=> "hi"
class CommandBuffer
  # The characters that make up a word, for every word key (Ctrl+left,
  # Ctrl+right, {#backspace_word} and {#delete_word}), as the body of a
  # regex bracket expression. POSIX +[:word:]+ is Unicode-aware: letters,
  # combining marks, digits and connector punctuation, so +é+ (precomposed
  # or +e+ plus U+0301) is a word character, unlike with +\w+. On ASCII it
  # matches +\w+ exactly, so +_+ joins words: +foo_bar+ is one word.
  WORD_CHAR = '[:word:]'

  # Two characters that end one word and start the next, for Ctrl+left
  # and Ctrl+right: a word character then punctuation, anything else then
  # a word character, or a space then a non-space. Word characters are
  # {WORD_CHAR}; +[:space:]+ matches +\s+ exactly on ASCII.
  WORD_START = /[#{WORD_CHAR}][^#{WORD_CHAR}[:space:]]|[^#{WORD_CHAR}][#{WORD_CHAR}]|[[:space:]][^[:space:]]/

  # @return [Integer] cursor position within the buffer (0-based)
  attr_reader :pos

  # @return [Integer] horizontal scroll offset into the buffer
  attr_reader :offset

  # @return [Curses::Window, nil] the curses window used for display
  attr_accessor :window

  # @return [Integer] which line the up and down arrows show: 0 is the
  #   line being edited, 1 the newest entry
  attr_reader :history_pos

  # Create a new command buffer.
  #
  # @param min_history_length [Integer] commands shorter than this are
  #   not saved to history (numeric-only commands are always saved)
  # @return [CommandBuffer]
  def initialize(min_history_length: 4)
    @text               = String.new
    @pos                = 0
    @offset             = 0
    @window             = nil
    @sent               = CommandHistory.new(min_length: min_history_length)
    @recall             = []
    @history_pos        = 0
    @draft              = nil
    @kill               = KillRing.new
  end

  # The current buffer contents.
  #
  # @return [String] a frozen copy; edit the line through the editing
  #   methods, which keep the cursor and the screen in step
  def text
    @text.dup.freeze
  end

  # The lines sent, newest first (see {CommandHistory}). Lines left by
  # browsing (edits of recalled entries, lines saved by the down arrow)
  # are not included.
  #
  # @return [Array<String>] a frozen copy
  def history
    @sent.to_a
  end

  # The +n+th most recent line sent, for the resend keys.
  #
  # @param n [Integer] 1 = the last line sent
  # @return [String, nil] the line, or nil when fewer than +n+ were sent
  def recent_command(n)
    @sent.recent(n)
  end

  # @return [Integer] minimum command length to save to history
  #   (all-digit commands are always saved)
  def min_history_length
    @sent.min_length
  end

  # @param length [Integer] minimum command length to save to history
  # @return [void]
  def min_history_length=(length)
    @sent.min_length = length
  end

  # -------------------------------------------------------------------
  # Window management
  # -------------------------------------------------------------------

  # Return the width of the attached window.
  # Falls back to DEFAULT_TERMINAL_WIDTH when no window is attached.
  #
  # @return [Integer] maximum number of columns in the window
  def maxx
    @window&.maxx || DEFAULT_TERMINAL_WIDTH
  end

  # Recompute the scroll offset for the window's current width and
  # repaint the command line.
  #
  # Call after the command window is resized or replaced so the cursor
  # and scroll offset match the new width. No-op when no window is
  # attached.
  #
  # @return [void]
  def redraw
    return unless @window

    render
    @window.noutrefresh
  end

  # -------------------------------------------------------------------
  # Character insertion
  # -------------------------------------------------------------------

  # Insert a character at the current cursor position.
  # Scrolls the view when the cursor would pass the right edge.
  #
  # Does not call +noutrefresh+; the caller is responsible for flushing.
  #
  # @param ch [String] single character to insert
  # @return [void]
  def put_ch(ch)
    @kill.end_sequence
    return unless @window

    @text.insert(@pos, ch)
    @pos += 1
    render
  end

  # -------------------------------------------------------------------
  # Cursor movement
  # -------------------------------------------------------------------

  # Move cursor left one position with horizontal scroll support.
  #
  # @return [void]
  def cursor_left
    @kill.end_sequence
    return unless @window

    @pos = [@pos - 1, 0].max
    render
    @window.noutrefresh
  end

  # Move cursor right one position with horizontal scroll support.
  #
  # @return [void]
  def cursor_right
    @kill.end_sequence
    return unless @window

    @pos = [@pos + 1, @text.length].min
    render
    @window.noutrefresh
  end

  # Move cursor left to the beginning of the word the cursor is in or
  # just after (the previous word when already at a word start), so it
  # stops at the same places as {#cursor_word_right}.
  # Scrolls the view so the target position is at the left edge when it
  # is before the current visible offset.
  #
  # @return [void]
  def cursor_word_left
    @kill.end_sequence
    return unless @window && @pos > 0

    # The last word start before the cursor; a match in text[0...pos]
    # ends at or before pos - 1, so the start is at most pos - 1.
    new_pos = if (m = @text[0...@pos].match(/.*(#{WORD_START})/o))
                m.begin(1) + 1
              else
                0
              end
    @pos = new_pos
    render
    @window.noutrefresh
  end

  # Move cursor right to the beginning of the next word.
  # Scrolls the view so the target position is at the right edge when it
  # exceeds the visible area.
  #
  # @return [void]
  def cursor_word_right
    @kill.end_sequence
    return unless @window && @pos < @text.length

    new_pos = if (m = @text[@pos..-1].match(WORD_START))
                @pos + m.begin(0) + 1
              else
                @text.length
              end
    @pos = new_pos
    render
    @window.noutrefresh
  end

  # Move cursor to the beginning of the buffer.
  # Scrolls the view back to reveal any off-screen leading text.
  #
  # @return [void]
  def cursor_home
    @kill.end_sequence
    return unless @window

    @pos = 0
    render
    @window.noutrefresh
  end

  # Move cursor to the end of the buffer.
  # Scrolls the view so the end of the text is visible.
  #
  # @return [void]
  def cursor_end
    @kill.end_sequence
    return unless @window

    @pos = @text.length
    render
    @window.noutrefresh
  end

  # -------------------------------------------------------------------
  # Deletion
  # -------------------------------------------------------------------

  # Delete the character before the cursor (backspace).
  # Scrolls hidden leading text back into view as the text shrinks.
  #
  # @return [void]
  def backspace
    @kill.end_sequence
    return unless @window && @pos > 0

    @pos -= 1
    delete_at_position(@pos)
    render
    @window.noutrefresh
  end

  # Delete the character at the cursor position.
  # No-op when the buffer is empty or the cursor is past the end.
  #
  # @return [void]
  def delete_char
    @kill.end_sequence
    return unless @window
    return if @text.empty? || @pos >= @text.length

    delete_at_position(@pos)
    render
    @window.noutrefresh
  end

  # -------------------------------------------------------------------
  # Word deletion with kill ring
  # -------------------------------------------------------------------

  # Delete the word before the cursor, saving deleted text to the kill ring.
  # Word boundaries follow readline-style rules: punctuation and
  # whitespace transitions delimit words. Word characters are
  # {WORD_CHAR}, as for Ctrl+left/right.
  #
  # @return [void]
  def backspace_word
    delete_word_in_direction(:backward)
  end

  # Delete the word after the cursor, saving deleted text to the kill ring.
  # Word boundaries follow readline-style rules: punctuation and
  # whitespace transitions delimit words. Word characters are
  # {WORD_CHAR}, as for Ctrl+left/right.
  #
  # @return [void]
  def delete_word
    delete_word_in_direction(:forward)
  end

  # Kill text from the cursor to the end of the line.
  # Appends the killed text to the kill ring buffer.
  #
  # @return [void]
  def kill_forward
    return unless @window && @pos < @text.length

    @kill.before(@text)
    if @pos == 0
      @kill.buffer += @text
      @text = String.new
    else
      @kill.buffer += @text[@pos..-1]
      @text = @text[0..(@pos - 1)]
    end
    @kill.after
    render
    @window.noutrefresh
  end

  # Kill the entire line, replacing the kill buffer with the original text.
  # Resets cursor position and scroll offset.
  #
  # @return [void]
  def kill_line
    return unless @window
    return if @text.empty?

    @kill.before(@text)
    @kill.buffer = @kill.original
    @text = String.new
    @pos = 0
    @offset = 0
    @kill.after
    render
    @window.noutrefresh
  end

  # Yank (paste) the current kill ring contents at the cursor position.
  # Each character is inserted via +put_ch+ so scrolling is handled
  # automatically.
  #
  # @return [void]
  def yank
    @kill.end_sequence
    @kill.buffer.each_char { |c| put_ch(c) }
  end

  # -------------------------------------------------------------------
  # History
  # -------------------------------------------------------------------

  # Navigate to the previous (older) command in history.
  #
  # Leaving the bottom of history (position 0) saves the unsent buffer
  # text as the draft, outside the history list, so it can be restored
  # by {#next_command} but is never sent or recalled as a history entry.
  # Leaving a recalled entry saves any edits back into that entry of the
  # list the arrows browse; the line sent stays unchanged in {#history}.
  # No-op when already at the oldest entry.
  #
  # @return [void]
  def previous_command
    @kill.end_sequence
    return unless @window && @history_pos < (@recall.length - 1)

    if @history_pos == 0
      @draft = @text.dup
    else
      @recall[@history_pos] = @text.dup
    end
    @history_pos += 1
    @text = @recall[@history_pos].dup
    @pos = @text.length
    render
    @window.noutrefresh
  end

  # Navigate to the next (newer) command in history.
  # Returning to position 0 restores the draft saved by
  # {#previous_command}. When already at position 0 and the buffer is
  # non-empty, pushes the current text into the list the arrows browse
  # (not into the lines sent, {#history}) and clears the buffer.
  #
  # @return [void]
  def next_command
    @kill.end_sequence
    return unless @window

    if @history_pos == 0
      unless @text.empty?
        @recall[@history_pos] = @text.dup
        @recall.unshift String.new
        trim_history
        @text.clear
        @pos = 0
        @offset = 0
        render
        @window.noutrefresh
      end
    else
      @recall[@history_pos] = @text.dup
      @history_pos -= 1
      @text = @history_pos == 0 ? take_draft : @recall[@history_pos].dup
      @pos = @text.length
      render
      @window.noutrefresh
    end
  end

  # -------------------------------------------------------------------
  # Buffer operations
  # -------------------------------------------------------------------

  # Clear the buffer and return its contents.
  # Resets position and offset, clears the curses window display.
  #
  # Does not call +noutrefresh+; the caller is responsible for flushing.
  #
  # @return [String] the buffer contents before clearing
  def clear_and_get
    @kill.end_sequence
    cmd = @text.dup
    @text.clear
    @pos = 0
    @offset = 0
    render if @window
    cmd
  end

  # Record a command that was sent: in the lines sent (see
  # {CommandHistory#add}) and in the list the up and down arrows browse.
  # Commands shorter than +min_history_length+ are skipped unless they
  # consist entirely of digits. In each list a command identical to the
  # newest entry is not added again (consecutive duplicates only; an
  # older identical entry is kept), and the oldest entries beyond
  # +CONFIG.history_size+ are dropped. Resets +history_pos+ to 0 and
  # discards any draft saved by {#previous_command}.
  #
  # @param cmd [String] the command to record
  # @return [void]
  def add_to_history(cmd)
    @history_pos = 0
    @draft = nil
    return unless @sent.keeps?(cmd)

    @sent.add(cmd)
    @recall.shift if @recall[0].to_s.empty? || @recall[0] == @recall[1]
    @recall.unshift cmd unless cmd == @recall[0]
    @recall.unshift String.new
    trim_history
  end

  # Refresh the window via noutrefresh.
  # Safe to call when no window is attached (no-op in that case).
  #
  # @return [void]
  def refresh
    @window&.noutrefresh
  end

  # Flush the virtual screen to the terminal, leaving the terminal cursor
  # on the command line: at the edit position, or where a macro's `\?`
  # moved the window's cursor (see {MacroInterpreter}).
  #
  # ncurses puts the terminal cursor where the window refreshed last left
  # it, so this refreshes the command window last, then calls
  # {CursesRenderer.doupdate}. Every flush from the input path (keys,
  # dot-commands, macros, autocomplete, the mouse) goes through here, so a
  # reply drawn in another window never leaves the cursor there. Call it
  # with the render lock held, as the input loop does for every key, so no
  # other thread refreshes a window in between.
  #
  # @return [void]
  def flush_screen
    refresh
    CursesRenderer.doupdate
  end

  # Clear the visible command line display.
  # Does not modify the buffer text, position, or offset.
  #
  # @return [void]
  def clear_display
    return unless @window

    @window.setpos(0, 0)
    @window.clrtoeol
    @window.noutrefresh
  end

  private

  # Return the saved draft and forget it.
  #
  # @return [String] the draft, or an empty string when none was saved
  # @api private
  def take_draft
    draft = @draft || String.new
    @draft = nil
    draft
  end

  # Drop the oldest entries of the list the arrows browse beyond
  # +CONFIG.history_size+. Index 0 is the edit line, not an entry, so it
  # is always kept.
  #
  # @return [void]
  # @api private
  def trim_history
    excess = @recall.length - 1 - CONFIG.history_size
    @recall.pop(excess) if excess.positive?
  end

  # Delete the character at the given position in the buffer.
  # Removes the character from +@text+ only; the caller repaints.
  #
  # @param delete_pos [Integer] 0-based index of the character to remove
  # @return [void]
  # @api private
  def delete_at_position(delete_pos)
    @text = if delete_pos == 0
              @text[(delete_pos + 1)..-1]
            else
              @text[0..(delete_pos - 1)] + @text[(delete_pos + 1)..-1]
            end
  end

  # Clamp the horizontal scroll offset for the current window width.
  #
  # The cursor column (+pos - offset+) is kept within 0..width-1, and the
  # offset never exceeds +text.length - width + 1+ so the view does not
  # stay scrolled right while leading text is hidden and trailing columns
  # are blank. With the cursor at the end of the text this places the
  # cursor in the last column, matching the historical scroll position.
  #
  # @param width [Integer] visible columns (at least 1)
  # @return [void]
  # @api private
  def clamp_offset(width)
    max_offset = [@text.length - width + 1, 0].max
    @offset = @offset.clamp(0, max_offset)
    @offset = @pos if @pos < @offset
    @offset = @pos - width + 1 if @pos - @offset >= width
  end

  # Repaint the command line from the buffer state.
  #
  # Clamps the offset (see {#clamp_offset}), then clears row 0 and
  # writes +text[offset, width]+ before placing the cursor at
  # +pos - offset+. The row is cleared before writing because writing
  # the last column leaves the curses cursor there, where a trailing
  # +clrtoeol+ would erase that character.
  #
  # Does not call +noutrefresh+; the caller is responsible for flushing.
  #
  # @return [void]
  # @api private
  def render
    width = [maxx.to_i, 1].max
    clamp_offset(width)
    @window.setpos(0, 0)
    @window.clrtoeol
    visible = @text[@offset, width]
    @window.addstr(visible) unless visible.nil? || visible.empty?
    @window.setpos(0, @pos - @offset)
  end

  # Whether a character is part of a word ({WORD_CHAR}).
  #
  # @param char [String] a single character
  # @return [Boolean]
  # @api private
  def word_char?(char)
    char.match?(/[#{WORD_CHAR}]/o)
  end

  # Delete a word in the given direction, saving deleted text to the kill ring.
  # Iterates character-by-character using readline-style word boundary rules
  # (punctuation and whitespace transitions delimit words), delegating each
  # single-character deletion to the appropriate public method.
  #
  # @param direction [:backward, :forward] direction to delete
  # @return [void]
  # @api private
  def delete_word_in_direction(direction)
    num_deleted = 0
    deleted_word = false
    deleted_nonspace = false
    backward = direction == :backward

    while backward ? @pos > 0 : @pos < @text.length
      next_char = backward ? @text[@pos - 1] : @text[@pos]
      word = word_char?(next_char)
      unless num_deleted == 0 || (!deleted_word && next_char.punct?) || (!deleted_nonspace && next_char.space?) || word
        break
      end

      deleted_word ||= word
      deleted_nonspace = !next_char.space?
      @kill.before(@text) if num_deleted.zero?
      num_deleted += 1
      if backward
        @kill.buffer = next_char + @kill.buffer
        backspace
      else
        @kill.buffer += next_char
        delete_char
      end
    end
    # backspace/delete_char end the kill sequence as they go, so mark the
    # whole word deletion as a kill once it is done.
    @kill.after if num_deleted.positive?
  end
end
