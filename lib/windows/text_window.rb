# frozen_string_literal: true

# Main scrollable text buffer window with word wrap, timestamps, and selection.

require_relative 'line_buffered'
require_relative 'stream_window'

# Scrollable text buffer window.
#
# Displays a reverse-ordered buffer of word-wrapped lines with optional
# timestamps. Supports keyboard scrolling, scrollbar rendering, and
# mouse-based text selection with copy support. The text area is the
# whole window (see {LineBuffered}).
class TextWindow < BaseWindow
  include LineBuffered
  include StreamWindow

  # The layout's last column holds the scrollbar.
  #
  # @return [Integer]
  def self.right_margin
    1
  end

  # Text windows are resized first (see {BaseWindow.resize_order}).
  #
  # @return [Integer]
  def self.resize_order
    10
  end

  # Fit every text window to the current terminal size. Resizing clears
  # each window's scrollbar (and marks the window inactive); only the
  # first text window moved gets its scrollbar drawn again.
  #
  # @return [void]
  def self.resize_all
    scrollbar_shown = false
    list.to_a.each do |window|
      next unless window.move_to_layout

      window.redraw_after_resize(show_scrollbar: !scrollbar_shown)
      scrollbar_shown = true
    end
  end

  # Create a new scrollable text window.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @indent_word_wrap = true
    super
    @line_buffer = LineBuffer.new(cap: DEFAULT_BUFFER_SIZE, width: wrap_width)
  end

  # @return [Integer] maximum number of logical lines retained in the buffer
  def max_buffer_size
    @line_buffer.cap
  end

  # Set the maximum number of logical lines retained in the buffer. The
  # oldest lines over a lowered limit are dropped at once.
  #
  # @param val [Integer, #to_i] new buffer size limit
  # @return [void]
  def max_buffer_size=(val)
    cap_line_buffers(val)
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

  # Prompts land in the window's one buffer.
  #
  # @return [LineBuffer]
  private def prompt_buffer
    @line_buffer
  end

  # Show the window again after {#move_to_layout} moved it: move its
  # scrollbar beside it, re-wrap every line to the new width, repaint the
  # text and clear the scrollbar.
  #
  # @param show_scrollbar [Boolean] draw the scrollbar again after
  #   clearing it
  # @return [void]
  # @api private
  def redraw_after_resize(show_scrollbar: true)
    fit_scrollbar
    rewrap
    repaint
    clear_scrollbar
    update_scrollbar if show_scrollbar
    noutrefresh
  end

  # The window's one buffer, always shown.
  #
  # @return [LineBuffer]
  private def shown_buffer
    @line_buffer
  end

  # The window's one buffer.
  #
  # @return [Array<LineBuffer>]
  private def line_buffers
    [@line_buffer]
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
    window = TextWindow.new(height, width - TextWindow.right_margin, top, left)
    window.add_scrollbar
  end
  window.scrollok(true)
  window.max_buffer_size = element.attributes['buffer-size'] || 1000
  window.time_stamp = BaseWindow.parse_flag_attr(element, 'timestamp')
  window.clock = wm.clock
  element.attributes['value'].split(',').each do |str|
    wm.stream[str] = window
  end
  SCROLL_WINDOW.push(window) unless SCROLL_WINDOW.include?(window)
  window
end
