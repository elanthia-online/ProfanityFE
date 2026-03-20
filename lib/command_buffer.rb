# frozen_string_literal: true

# Single-line command buffer with horizontal scrolling, kill ring, and history.
# Wraps a Curses::Window for editing; all screen updates use noutrefresh.

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
# All cursor and editing methods call +noutrefresh+ on the underlying
# window but never call +Curses.doupdate+; the caller is responsible
# for flushing the virtual screen to the terminal.
#
# @example Basic usage
#   buf = CommandBuffer.new
#   buf.window = Curses::Window.new(1, Curses.cols, Curses.lines - 1, 0)
#   buf.put_ch('h')
#   buf.put_ch('i')
#   cmd = buf.clear_and_get  #=> "hi"
class CommandBuffer
  # @return [String] current buffer contents
  attr_reader :text

  # @return [Integer] cursor position within the buffer (0-based)
  attr_reader :pos

  # @return [Integer] horizontal scroll offset into the buffer
  attr_reader :offset

  # @return [Curses::Window, nil] the curses window used for display
  attr_accessor :window

  # @return [Array<String>] list of previously entered commands
  attr_reader :history

  # @return [Integer] current index into the history stack
  attr_reader :history_pos

  # @return [Integer] minimum command length to auto-save to history
  attr_accessor :min_history_length

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
    @history            = []
    @history_pos        = 0
    @min_history_length = min_history_length
    @kill               = KillRing.new
  end

  # -------------------------------------------------------------------
  # Window management
  # -------------------------------------------------------------------

  # Assign the curses window used for display.
  #
  # @param win [Curses::Window] the window to render into
  # @return [void]

  # Return the width of the attached window.
  # Falls back to DEFAULT_TERMINAL_WIDTH when no window is attached.
  #
  # @return [Integer] maximum number of columns in the window
  def maxx
    @window&.maxx || DEFAULT_TERMINAL_WIDTH
  end

  # -------------------------------------------------------------------
  # Character insertion
  # -------------------------------------------------------------------

  # Insert a character at the current cursor position.
  # Handles horizontal scrolling when content exceeds window width.
  #
  # @param ch [String] single character to insert
  # @return [void]
  def put_ch(ch)
    return unless @window

    if (@pos - @offset + 1) >= maxx
      @window.setpos(0, 0)
      @window.delch
      @offset += 1
      @window.setpos(0, @pos - @offset)
    end
    @text.insert(@pos, ch)
    @pos += 1
    @window.insch(ch)
    @window.setpos(0, @pos - @offset)
  end

  # -------------------------------------------------------------------
  # Cursor movement
  # -------------------------------------------------------------------

  # Move cursor left one position with horizontal scroll support.
  #
  # @return [void]
  def cursor_left
    return unless @window

    if (@offset > 0) && (@pos - @offset == 0)
      @pos -= 1
      @offset -= 1
      @window.insch(@text[@pos])
    else
      @pos = [@pos - 1, 0].max
    end
    @window.setpos(0, @pos - @offset)
    @window.noutrefresh
  end

  # Move cursor right one position with horizontal scroll support.
  #
  # @return [void]
  def cursor_right
    return unless @window

    if ((@text.length - @offset) >= (maxx - 1)) && (@pos - @offset + 1) >= maxx
      if @pos < @text.length
        @window.setpos(0, 0)
        @window.delch
        @offset += 1
        @pos += 1
        @window.setpos(0, @pos - @offset)
        @window.insch(@text[@pos]) unless @pos >= @text.length
      end
    else
      @pos = [@pos + 1, @text.length].min
      @window.setpos(0, @pos - @offset)
    end
    @window.noutrefresh
  end

  # Move cursor left to the beginning of the previous word.
  # Scrolls the window right when the target position is before the
  # current visible offset.
  #
  # @return [void]
  def cursor_word_left
    return unless @window && @pos > 0

    new_pos = if (m = @text[0...(@pos - 1)].match(/.*(\w[^\w\s]|\W\w|\s\S)/))
                m.begin(1) + 1
              else
                0
              end
    if @offset > new_pos
      @window.setpos(0, 0)
      @text[new_pos, (@offset - new_pos)].split('').reverse.each do |ch|
        @window.insch(ch)
      end
      @pos = new_pos
      @offset = new_pos
    else
      @pos = new_pos
    end
    @window.setpos(0, @pos - @offset)
    @window.noutrefresh
  end

  # Move cursor right to the beginning of the next word.
  # Scrolls the window left when the target position exceeds the
  # visible area.
  #
  # @return [void]
  def cursor_word_right
    return unless @window && @pos < @text.length

    new_pos = if (m = @text[@pos..-1].match(/\w[^\w\s]|\W\w|\s\S/))
                @pos + m.begin(0) + 1
              else
                @text.length
              end
    overflow = new_pos - maxx - @offset + 1
    if overflow > 0
      @window.setpos(0, 0)
      overflow.times do
        @window.delch
        @offset += 1
      end
      @window.setpos(0, maxx - overflow)
      @window.addstr @text[(maxx - overflow + @offset), overflow]
    end
    @pos = new_pos
    @window.setpos(0, @pos - @offset)
    @window.noutrefresh
  end

  # Move cursor to the beginning of the buffer.
  # Scrolls the window to reveal any off-screen leading text.
  #
  # @return [void]
  def cursor_home
    return unless @window

    @pos = 0
    @window.setpos(0, 0)
    (1..@offset).each do |num|
      @window.insch(@text[@offset - num])
    rescue StandardError => e
      ProfanityLog.write('command_buffer', "#{e} text=#{@text.inspect} offset=#{@offset.inspect} num=#{num.inspect}", backtrace: e.backtrace)
      return # rubocop:disable Lint/NonLocalExitFromIterator
    end
    @offset = 0
    @window.noutrefresh
  end

  # Move cursor to the end of the buffer.
  # Scrolls the window left when the text extends past the visible area.
  #
  # @return [void]
  def cursor_end
    return unless @window

    if @text.length < (maxx - 1)
      @pos = @text.length
      @window.setpos(0, @pos)
    else
      scroll_left_num = @text.length - maxx + 1 - @offset
      @window.setpos(0, 0)
      scroll_left_num.times do
        @window.delch
        @offset += 1
      end
      @pos = @offset + maxx - 1 - scroll_left_num
      @window.setpos(0, @pos - @offset)
      scroll_left_num.times do
        @window.addch(@text[@pos])
        @pos += 1
      end
    end
    @window.noutrefresh
  end

  # -------------------------------------------------------------------
  # Deletion
  # -------------------------------------------------------------------

  # Delete the character before the cursor (backspace).
  # Adjusts the display when content extends beyond the visible window.
  #
  # @return [void]
  def backspace
    return unless @window && @pos > 0

    @pos -= 1
    delete_at_position(@pos)
    @window.noutrefresh
  end

  # Delete the character at the cursor position.
  # No-op when the buffer is empty or the cursor is past the end.
  #
  # @return [void]
  def delete_char
    return unless @window
    return if @text.empty? || @pos >= @text.length

    delete_at_position(@pos)
    @window.noutrefresh
  end

  # -------------------------------------------------------------------
  # Word deletion with kill ring
  # -------------------------------------------------------------------

  # Delete the word before the cursor, saving deleted text to the kill ring.
  # Word boundaries follow readline-style rules: punctuation and
  # whitespace transitions delimit words.
  #
  # @return [void]
  def backspace_word
    delete_word_in_direction(:backward)
  end

  # Delete the word after the cursor, saving deleted text to the kill ring.
  # Word boundaries follow readline-style rules: punctuation and
  # whitespace transitions delimit words.
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

    @kill.before(@text, @pos)
    if @pos == 0
      @kill.buffer += @text
      @text = String.new
    else
      @kill.buffer += @text[@pos..-1]
      @text = @text[0..(@pos - 1)]
    end
    @kill.after(@text, @pos)
    @window.clrtoeol
    @window.noutrefresh
  end

  # Kill the entire line, replacing the kill buffer with the original text.
  # Resets cursor position and scroll offset.
  #
  # @return [void]
  def kill_line
    return unless @window
    return if @text.empty?

    @kill.before(@text, @pos)
    @kill.buffer = @kill.original
    @text = String.new
    @pos = 0
    @offset = 0
    @kill.after(@text, @pos)
    @window.setpos(0, 0)
    @window.clrtoeol
    @window.noutrefresh
  end

  # Yank (paste) the current kill ring contents at the cursor position.
  # Each character is inserted via +put_ch+ so scrolling is handled
  # automatically.
  #
  # @return [void]
  def yank
    @kill.buffer.each_char { |c| put_ch(c) }
  end

  # -------------------------------------------------------------------
  # History
  # -------------------------------------------------------------------

  # Navigate to the previous (older) command in history.
  # Saves the current buffer text at the current history position before
  # moving. No-op when already at the oldest entry.
  #
  # @return [void]
  def previous_command
    return unless @window && @history_pos < (@history.length - 1)

    @history[@history_pos] = @text.dup
    @history_pos += 1
    @text = @history[@history_pos].dup
    @offset = [(@text.length - maxx + 1), 0].max
    @pos = @text.length
    @window.setpos(0, 0)
    @window.deleteln
    @window.addstr @text[@offset, (@text.length - @offset)]
    @window.setpos(0, @pos - @offset)
    @window.noutrefresh
  end

  # Navigate to the next (newer) command in history.
  # When already at position 0 and the buffer is non-empty, pushes the
  # current text into history and clears the buffer.
  #
  # @return [void]
  def next_command
    return unless @window

    if @history_pos == 0
      unless @text.empty?
        @history[@history_pos] = @text.dup
        @history.unshift String.new
        @text.clear
        @window.deleteln
        @pos = 0
        @offset = 0
        @window.setpos(0, 0)
        @window.noutrefresh
      end
    else
      @history[@history_pos] = @text.dup
      @history_pos -= 1
      @text = @history[@history_pos].dup
      @offset = [(@text.length - maxx + 1), 0].max
      @pos = @text.length
      @window.setpos(0, 0)
      @window.deleteln
      @window.addstr @text[@offset, (@text.length - @offset)]
      @window.setpos(0, @pos - @offset)
      @window.noutrefresh
    end
  end

  # -------------------------------------------------------------------
  # Buffer operations
  # -------------------------------------------------------------------

  # Clear the buffer and return its contents.
  # Resets position and offset, clears the curses window display.
  #
  # @return [String] the buffer contents before clearing
  def clear_and_get
    cmd = @text.dup
    @text.clear
    @pos = 0
    @offset = 0
    if @window
      @window.deleteln
      @window.setpos(0, 0)
    end
    cmd
  end

  # Save a command string to the history list.
  # Commands shorter than +min_history_length+ are skipped unless they
  # consist entirely of digits. Duplicate consecutive entries are
  # suppressed. Resets +history_pos+ to 0.
  #
  # @param cmd [String] the command to record
  # @return [void]
  def add_to_history(cmd)
    @history_pos = 0
    return unless (cmd.length >= @min_history_length || cmd.match?(/^\d+$/)) && (cmd != @history[1])

    if @history[0].nil? || @history[0].empty?
      @history[0] = cmd
    else
      @history.unshift cmd
    end
    @history.unshift String.new
  end

  # Refresh the window via noutrefresh.
  # Safe to call when no window is attached (no-op in that case).
  #
  # @return [void]
  def refresh
    @window&.noutrefresh
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

  # Delete the character at the given position in the buffer.
  # Removes the character from +@text+, updates the window by deleting
  # the on-screen character, and compensates for horizontal scroll when
  # content extends beyond the visible window.
  #
  # Does not call +noutrefresh+; the caller is responsible for flushing.
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
    @window.setpos(0, delete_pos - @offset)
    @window.delch
    return unless (@text.length - @offset + 1) > maxx

    @window.setpos(0, maxx - 1)
    @window.addch @text[maxx - @offset - 1]
    @window.setpos(0, @pos - @offset)
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
    deleted_alnum = false
    deleted_nonspace = false
    backward = direction == :backward

    while backward ? @pos > 0 : @pos < @text.length
      next_char = backward ? @text[@pos - 1] : @text[@pos]
      unless num_deleted == 0 || (!deleted_alnum && next_char.punct?) || (!deleted_nonspace && next_char.space?) || next_char.alnum?
        break
      end

      deleted_alnum ||= next_char.alnum?
      deleted_nonspace = !next_char.space?
      num_deleted += 1
      @kill.before(@text, @pos)
      if backward
        @kill.buffer = next_char + @kill.buffer
        backspace
      else
        @kill.buffer += next_char
        delete_char
      end
      @kill.after(@text, @pos)
    end
  end
end
