# frozen_string_literal: true

require_relative '../streams'
require_relative 'stream_window'

# Active spells/effects display with duration-based sorting.

# Active spells and effects display window.
#
# The server sends the full list of active spells as one block:
# +<clearStream id="percWindow"/>+ ({#clear_spells}) followed by one line
# per spell ({#add_string}). The window keeps that batch as logical
# (unwrapped) entries, sorts them by remaining duration (highest first),
# and wraps each entry only when drawing, so a long spell's continuation
# lines stay directly beneath it. Cyclic spells, percentage-based effects,
# and the "Fading" state each receive a fixed sort weight so the most
# important entries appear at the top.
#
# The window is redrawn after every change, so it always shows the batch
# received so far; {#redraw} (used on terminal resize) repaints the same
# batch at the current width.
class PercWindow < BaseWindow
  include StreamWindow

  # The layout's last column is left blank, both when the window is built
  # and when it is resized, so the window doesn't widen on resize.
  #
  # @return [Integer]
  def self.right_margin
    1
  end

  # Resized after the exp window (see {BaseWindow.resize_order}).
  #
  # @return [Integer]
  def self.resize_order
    40
  end

  # Sort weight for entries without a parenthesised duration.
  NO_DURATION_WEIGHT = 1000

  # Create a new active spells window.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @spells = {}.freeze
    @indent_word_wrap = true
    super
  end

  # The displayed lines, top to bottom, for selection support.
  #
  # @return [Array<Array(String, Array<Hash>, Boolean)>] each wrapped line,
  #   its color regions, and whether it continues the previous line
  def buffer_content
    display_lines
  end

  # Add a spell/effect line to the current batch and redraw the window.
  #
  # The line is stored unwrapped; wrapping happens when drawing. A line
  # identical to one already in the batch replaces it. Blank lines are
  # ignored.
  #
  # @param string [String] the spell/effect text
  # @param string_colors [Array<Hash>] color region descriptors
  # @param indent [Boolean, nil] indent wrapped continuation lines
  #   (nil uses the window default, true)
  # @return [void]
  def add_string(string, string_colors = [], indent: nil)
    return if string.to_s.strip.empty?

    effective_indent = indent.nil? ? @indent_word_wrap : indent
    # Copy the caller's text and colors, and replace the hash rather than
    # mutating it, so a redraw from another thread always iterates a
    # complete, unchanging batch.
    @spells = @spells.merge(string.dup.freeze => [string_colors.dup.freeze, effective_indent]).freeze
    redraw
  end

  # Redraw the current batch, sorted by remaining duration (longest first)
  # and wrapped to the current window width. The batch is kept, so a
  # redraw after a terminal resize shows the same spells.
  #
  # @return [void]
  def redraw
    erase
    display_lines.first(maxy).each_with_index do |(line, line_colors), row|
      setpos(row, 0)
      add_line(line, line_colors, newline: true, refresh: true)
    end
    noutrefresh
  rescue StandardError => e
    ProfanityLog.write('perc_window', "Error drawing spells: #{e}", backtrace: e.backtrace)
  end

  # Show the window again after {#move_to_layout} moved it: redraw its
  # contents at the new size.
  #
  # @return [void]
  # @api private
  def redraw_after_resize
    redraw
    noutrefresh
  end

  # Start a new batch of spells and redraw the (now empty) window.
  # Called for +<clearStream id="percWindow"/>+; the spell lines that
  # follow are added with {#add_string}.
  #
  # @return [void]
  def clear_spells
    @spells = {}.freeze
    redraw
  end

  private

  # The current batch sorted by duration and wrapped to the window width.
  # Entries with equal weight keep their arrival order.
  #
  # @return [Array<Array(String, Array<Hash>, Boolean)>] wrapped lines with
  #   their color regions and continuation flags, top to bottom
  # @api private
  def display_lines
    width = [maxx - 1, 1].max
    sorted = @spells.each_with_index.sort_by { |(text, _), index| [-spell_weight(text), index] }
    sorted.flat_map do |(text, (colors, indent)), _index|
      lines = []
      wrap_text(text, width, colors, indent: indent) do |line, line_colors, continuation|
        lines << [line, line_colors, continuation]
      end
      lines
    end
  end

  # Wrap a string to the given width, splitting color regions across lines.
  # Yields each [line, line_colors, continuation] triple to the caller.
  #
  # Delegates to {StyledText#wrap} which encapsulates all the position
  # arithmetic. This eliminates the manual start/end adjustment loops
  # that were the primary source of off-by-one color region bugs.
  #
  # @param string [String] the text to wrap
  # @param width [Integer] maximum line width in characters
  # @param string_colors [Array<Hash>] color region descriptors for the full string
  # @param indent [Boolean] whether continuation lines should be indented
  # @yield [line, line_colors, continuation] each wrapped line, its adjusted
  #   color regions, and whether it continues the previous wrapped line
  # @yieldparam line [String] one wrapped line of text
  # @yieldparam line_colors [Array<Hash>] color regions scoped to this line
  # @yieldparam continuation [Boolean] true for the 2nd+ line of a wrapped string
  # @return [void]
  # @api private
  def wrap_text(string, width, string_colors, indent: true)
    styled = StyledText.new(string, string_colors)
    styled.wrap(width, indent: indent).each_with_index do |wrapped_line, idx|
      yield wrapped_line.text, wrapped_line.runs, idx.positive?
    end
  end

  # Sort weight of a spell line: higher sorts first. Parsed from the first
  # parenthesised part, e.g. "Spell Name (5)" is 5; percentages weigh 3000,
  # "OM" 2000, "Cyclic" 1500, "Fading" 0, and lines without a duration
  # {NO_DURATION_WEIGHT}.
  #
  # @param text [String] the spell line
  # @return [Integer] the sort weight
  # @api private
  def spell_weight(text)
    duration_part = text.to_s.split(/\s+(?=\()/)[1]
    return NO_DURATION_WEIGHT unless duration_part

    duration_part.gsub(/\(|\)/, '')
                 .sub(/\d+%/, '3000')
                 .sub(/Cyclic/, '1500')
                 .sub(/OM/, '2000')
                 .sub(/Fading/, '0')
                 .to_i
  end
end

BaseWindow.register_type('percWindow') do |height, width, top, left, _element, wm|
  window = PercWindow.new(height, width - PercWindow.right_margin, top, left)
  wm.stream[Streams::PERC] = window
  window
end
