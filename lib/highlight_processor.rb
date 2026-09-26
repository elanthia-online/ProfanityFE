# frozen_string_literal: true

# highlight_processor.rb: Centralized highlight pattern application and colored
# text rendering for all ProfanityFE windows.

# Centralized highlight processing for all windows.
# Applies HIGHLIGHT regex patterns to text and renders colored text segments
# to curses windows with proper color pair management.
#
# @example Apply highlights to text
#   colors = HighlightProcessor.apply_highlights("a goblin attacks", [])
#   # => [{ start: 2, end: 8, fg: 'ff0000', bg: nil, ul: nil }]
#
# @example Render colored text to a window
#   HighlightProcessor.render_colored_text(window, "hello", colors, newline: true)
module HighlightProcessor
  module_function

  # Apply all HIGHLIGHT patterns to text and append matches to line_colors.
  # Thread-safe — acquires SETTINGS_LOCK while iterating patterns.
  #
  # @param text [String] the text to apply highlights to
  # @param line_colors [Array<Hash>] existing color regions to append to
  # @return [Array<Hash>] the updated line_colors array with any new matches
  def apply_highlights(text, line_colors = [])
    SETTINGS_LOCK.synchronize do
      HIGHLIGHT.each_pair do |regex, colors|
        pos = 0
        # Bound pos explicitly: String#match with a start past the end still
        # returns a zero-width match at the end of the string.
        while pos <= text.length && (match_data = text.match(regex, pos))
          if match_data.end(0) == match_data.begin(0)
            # A zero-width match (e.g. /\b/, /x*/ or an empty pattern) colors
            # nothing; step past it so the scan always advances.
            pos = match_data.end(0) + 1
            next
          end

          h = {
            start: match_data.begin(0),
            end: match_data.end(0),
            fg: colors[0],
            bg: colors[1],
            ul: colors[2]
          }
          line_colors.push(h)
          pos = match_data.end(0)
        end
      end
    end
    line_colors
  end

  # Render text with color regions to a curses window.
  # Splits text at color region boundaries and applies the most specific
  # (smallest range) color to each segment.
  #
  # @param window [Curses::Window] the window to render to
  # @param text [String] the text to render
  # @param line_colors [Array<Hash>] color regions with :start, :end, :fg, :bg, :ul keys
  # @param options [Hash] rendering options
  # @option options [Boolean] :newline append newline after text (default: false)
  # @option options [Boolean] :refresh call noutrefresh after rendering (default: false)
  # @return [void]
  def render_colored_text(window, text, line_colors = [], options = {})
    return if text.nil? || text.empty?

    # Build boundary points from all color regions
    part = [0, text.length]
    line_colors.each do |h|
      part.push(h[:start]) if h[:start]
      part.push(h[:end]) if h[:end]
    end
    part.uniq!
    part.sort!

    # Render each segment with appropriate colors
    (0...(part.length - 1)).each do |i|
      str = text[part[i]...part[i + 1]]
      next if str.nil? || str.empty?

      # Find all color rules that apply to this segment
      color_list = line_colors.find_all { |h| (h[:start] <= part[i]) && (h[:end] >= part[i + 1]) }

      if color_list.empty?
        window.addstr(str)
      else
        # Sort by specificity (smaller range = more specific = higher priority)
        color_list = color_list.sort_by { |h| h[:end] - h[:start] }
        fg = color_list.map { |h| h[:fg] }.find { |c| !c.nil? }
        bg = color_list.map { |h| h[:bg] }.find { |c| !c.nil? }
        ul = color_list.map { |h| h[:ul] == 'true' }.find { |u| u }

        attrs = Curses.color_pair(get_color_pair_id(fg, bg))
        attrs |= Curses::A_UNDERLINE if ul

        window.attron(attrs) do
          window.addstr(str)
        end
      end
    end

    window.addstr("\n") if options[:newline] && !text.chomp.empty?
    window.noutrefresh if options[:refresh]
  end
end
