# frozen_string_literal: true

# Main scrollable text buffer window with word wrap, timestamps, and selection.

require_relative 'line_buffered'

# Scrollable text buffer window.
#
# Displays a reverse-ordered buffer of word-wrapped lines with optional
# timestamps. Supports keyboard scrolling, scrollbar rendering, and
# mouse-based text selection with copy support. The text area is the
# whole window (see {LineBuffered}).
class TextWindow < BaseWindow
  include LineBuffered

  # Create a new scrollable text window.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @line_buffer = LineBuffer.new(cap: DEFAULT_BUFFER_SIZE)
    @indent_word_wrap = true
    super
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
  # @param indent [Boolean, nil] indent continuation lines (nil = window default)
  # @return [void]
  def add_string(string, string_colors = [], indent: nil)
    append_string(@line_buffer, string, string_colors, indent: indent, shown: true)
  end

  # Check if the most recent non-empty line matches the given prompt text.
  # Used to suppress duplicate bare prompts.
  #
  # @param prompt_text [String] the prompt string to check against
  # @return [Boolean] true if the last non-empty buffer line equals prompt_text
  def duplicate_prompt?(prompt_text)
    @line_buffer.newest_text?(prompt_text)
  end

  # The window's one buffer, always shown.
  #
  # @return [LineBuffer]
  private def shown_buffer
    @line_buffer
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
