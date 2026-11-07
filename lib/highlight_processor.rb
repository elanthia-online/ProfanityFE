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
  # Texts whose regions are remembered, per generation of HIGHLIGHT. A few
  # minutes of travel shows about 400 distinct texts; a crafting session's
  # repeated inventory and room texts fewer.
  SPANS_MEMO_CAPACITY = 2048

  # Longest text (in bytes) whose regions are remembered. Longer texts are
  # matched every time, so the memo holds at most about 8 MB of text.
  SPANS_MEMO_MAX_BYTES = 4096

  module_function

  # Apply all HIGHLIGHT patterns to text and append matches to line_colors,
  # pattern by pattern in HIGHLIGHT's order, each pattern's matches left to
  # right. Thread-safe - acquires SETTINGS_LOCK while reading the patterns.
  #
  # Every displayed text is highlighted, and most texts repeat (room text on
  # every visit, the inventory list while crafting), so the regions found
  # for a text are remembered until HIGHLIGHT next changes (see
  # HighlightTable#generation). Each call gets new region hashes, so a
  # caller may change the ones it is given.
  #
  # @param text [String] the text to apply highlights to
  # @param line_colors [Array<Hash>] existing color regions to append to
  # @return [Array<Hash>] the updated line_colors array with any new matches
  def apply_highlights(text, line_colors = [])
    SETTINGS_LOCK.synchronize do
      highlight_spans(text, HIGHLIGHT).each do |start, finish, colors|
        line_colors.push({ start: start, end: finish, fg: colors[0], bg: colors[1], ul: colors[2] })
      end
    end
    line_colors
  end

  # The regions of +text+ for +table+, remembered or found now. A table
  # that does not count its changes (a plain Hash) is matched every time.
  #
  # @param text [String]
  # @param table [HighlightTable, Hash] the highlight patterns
  # @return [Array<Array(Integer, Integer, Array)>] frozen [start, end,
  #   colors] per region
  # @api private
  def highlight_spans(text, table)
    return scan_highlights(text, table) if text.bytesize > SPANS_MEMO_MAX_BYTES || !table.respond_to?(:generation)

    memo = spans_memo(table)
    spans = memo[text]
    return spans if spans

    spans = scan_highlights(text, table)
    memo.shift if memo.size >= SPANS_MEMO_CAPACITY
    memo[text] = spans
  end

  # The memo of regions for +table+ as it is now: emptied when the table
  # is another one or has changed since the regions were found.
  #
  # @param table [HighlightTable]
  # @return [Hash{String => Array}] regions by text, oldest first
  # @api private
  def spans_memo(table)
    unless @spans_memo_table.equal?(table) && @spans_memo_generation == table.generation
      @spans_memo = {}
      @spans_memo_table = table
      @spans_memo_generation = table.generation
    end
    @spans_memo
  end

  # Match every pattern of +table+ against +text+.
  #
  # @param text [String]
  # @param table [Hash{Regexp => Array}] the highlight patterns
  # @return [Array<Array(Integer, Integer, Array)>] frozen [start, end,
  #   colors] per region, colors being the pattern's own array
  # @api private
  def scan_highlights(text, table)
    spans = []
    table.each_pair do |regex, colors|
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

        spans.push([match_data.begin(0), match_data.end(0), colors].freeze)
        pos = match_data.end(0)
      end
    end
    spans.freeze
  end

  private_class_method :highlight_spans, :spans_memo, :scan_highlights

  # Render text with color regions to a curses window.
  # Splits text at color region boundaries and applies the most specific
  # (smallest range) color to each segment, except that a link's color
  # (a region with a :cmd) yields to every other color: it shows only on
  # text no other region colors. A creature's name, a highlight or a
  # preset under a link keeps its own color, and the link stays clickable
  # (clicks read the regions, not the color drawn). DragonRealms wraps
  # every object, creature and player in a link when Lich identifies as
  # the Saga client.
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
        # Links last, then by specificity (smaller range = more specific =
        # higher priority)
        color_list = color_list.sort_by { |h| [h[:cmd] ? 1 : 0, h[:end] - h[:start]] }
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
