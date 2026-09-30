# frozen_string_literal: true

# Bundles a text string with its color/style runs.
#
# Replaces the fragile pattern of passing a String and a parallel
# Array<Hash> of color regions through the rendering pipeline. All
# position-sensitive operations (slicing, lstrip, wrapping) adjust
# the run positions automatically so callers never do manual arithmetic.
#
# Runs are hashes with :start, :end (character positions in the text),
# and optional :fg, :bg, :ul, :cmd keys. They are stored in insertion
# order but may overlap — the renderer resolves priority by smallest
# range first (most specific wins).
#
# @example Build styled text
#   st = StyledText.new('Hello world')
#   st.add_run(start: 0, end: 5, fg: 'ff0000')
#   st.add_run(start: 6, end: 11, fg: '00ff00')
#   st.text    # => "Hello world"
#   st.runs    # => [{start: 0, end: 5, fg: 'ff0000'}, {start: 6, end: 11, fg: '00ff00'}]
#
# @example Word-wrap
#   lines = StyledText.new('Hello world foo bar').wrap(10)
#   lines.map(&:text)  # => ["Hello ", "world foo ", "bar"]
class StyledText
  # @return [String] the plain text content
  attr_reader :text

  # @return [Array<Hash>] color/style run descriptors
  attr_reader :runs

  # Create a new StyledText from text and optional runs.
  #
  # @param text [String] the text content
  # @param runs [Array<Hash>] color/style runs (will be duped)
  def initialize(text = '', runs = [])
    @text = text.is_a?(String) ? text.dup : text.to_s
    @runs = runs.map(&:dup)
  end

  # @return [Integer] length of the text content
  def length
    @text.length
  end

  # @return [Boolean] true if the text is empty
  def empty?
    @text.empty?
  end

  # @return [Boolean] true if the text is empty or whitespace-only
  def blank?
    @text.strip.empty?
  end

  # Append text to the end. No new runs are added — the appended text
  # inherits whatever styling context the caller sets up afterward.
  #
  # @param str [String] text to append
  # @return [self]
  def <<(str)
    @text << str
    self
  end

  # Add a style run at the given positions.
  #
  # @param attrs [Hash] must include :start and :end, may include
  #   :fg, :bg, :ul, :cmd
  # @return [self]
  def add_run(**attrs)
    @runs << attrs
    self
  end

  # Return a new StyledText containing the substring at the given range.
  # Run positions are adjusted relative to the slice start. Runs that
  # fall entirely outside the range are excluded. Runs that partially
  # overlap are clamped.
  #
  # @param range [Range] character range (e.g., 0...10)
  # @return [StyledText] a new instance with adjusted positions
  def slice(range)
    start_pos = range.begin || 0
    sliced_text = @text[range] || ''
    sliced_len = sliced_text.length

    sliced_runs = @runs.filter_map do |run|
      new_start = [(run[:start] || 0) - start_pos, 0].max
      new_end = [(run[:end] || 0) - start_pos, sliced_len].min
      next if new_end <= new_start

      run.dup.merge(start: new_start, end: new_end)
    end

    self.class.new(sliced_text, sliced_runs)
  end

  # Return a new StyledText with leading whitespace removed.
  # Run positions are shifted left by the number of stripped characters.
  # Runs that end up entirely before position 0 are dropped.
  #
  # @return [StyledText] a new instance with adjusted positions
  def lstrip
    stripped = @text.lstrip
    offset = @text.length - stripped.length
    return dup_with_runs if offset == 0

    adjusted_runs = @runs.filter_map do |run|
      new_start = [(run[:start] || 0) - offset, 0].max
      new_end = (run[:end] || 0) - offset
      next if new_end <= 0

      run.dup.merge(start: new_start, end: new_end)
    end

    self.class.new(stripped, adjusted_runs)
  end

  # Return a new StyledText with parts of the text replaced, keeping every
  # run on the text it colored.
  #
  # Each edit replaces the characters +from...to+ (positions in this text)
  # with +replacement+. Edits must not overlap; they are applied together,
  # so every position refers to this text, not to the result of an earlier
  # edit. Runs follow the text:
  # - text that is kept keeps its runs, at its new position;
  # - a run covering any part of a replaced span covers the whole
  #   replacement (a highlight on "Persistence of Mana" colors "POM");
  # - deleted text drops out of its runs, and a run left empty is dropped;
  # - inserted text (+from == to+) is colored only by runs that span it.
  #
  # @example
  #   st = StyledText.new('Persistence of Mana  (OM)', [{ start: 0, end: 19, fg: 'ff0000' }])
  #   st.replace_ranges([[0, 19, 'POM']]).runs  # => [{ start: 0, end: 3, fg: 'ff0000' }]
  #
  # @param edits [Array<Array(Integer, Integer, String)>] +[from, to, replacement]+ triples
  # @return [StyledText] a new instance with the edits applied
  def replace_ranges(edits)
    edits = edits.sort_by { |from, to, _| [from, to] }
    new_text = +''
    cursor = 0
    edits.each do |from, to, replacement|
      new_text << @text[cursor...from] << replacement
      cursor = to
    end
    new_text << @text[cursor..]

    new_runs = @runs.filter_map do |run|
      new_start = map_run_start(run[:start] || 0, edits)
      new_end = map_run_end(run[:end] || 0, edits)
      next if new_end <= new_start

      run.merge(start: new_start, end: new_end)
    end

    self.class.new(new_text, new_runs)
  end

  # Like String#sub (including +\\1+ backreferences in +replacement+), with
  # runs moved as described in {#replace_ranges}.
  #
  # @param pattern [Regexp, String] what to replace (a String matches literally)
  # @param replacement [String] the replacement text
  # @return [StyledText] a new instance; an unchanged copy when nothing matches
  def sub(pattern, replacement)
    pattern = Regexp.new(Regexp.escape(pattern)) if pattern.is_a?(String)
    match = @text.match(pattern)
    return dup_with_runs unless match

    # String#sub changes only the matched span, so the replacement is what
    # lies between the unchanged head and tail of the result.
    replaced = @text.sub(pattern, replacement)
    tail = @text.length - match.end(0)
    replace_ranges([[match.begin(0), match.end(0), replaced[match.begin(0)...(replaced.length - tail)]]])
  end

  # Replace every match of +pattern+ with +replacement+, inserted literally
  # (no backreferences), with runs moved as described in {#replace_ranges}.
  #
  # @param pattern [Regexp] what to replace
  # @param replacement [String] the literal replacement text
  # @return [StyledText] a new instance
  def gsub(pattern, replacement)
    edits = []
    @text.scan(pattern) { edits << [Regexp.last_match.begin(0), Regexp.last_match.end(0), replacement] }
    replace_ranges(edits)
  end

  # Like String#strip, with runs moved as described in {#replace_ranges}.
  #
  # @return [StyledText] a new instance without leading or trailing whitespace
  def strip
    leading = @text.length - @text.lstrip.length
    return replace_ranges([[0, @text.length, '']]) if leading == @text.length

    trailing = @text.length - @text.rstrip.length
    replace_ranges([[0, leading, ''], [@text.length - trailing, @text.length, '']])
  end

  # Word-wrap the text to the given width, returning an array of
  # StyledText instances — one per wrapped line. Run positions are
  # correctly split across lines.
  #
  # The work per row is proportional to the runs on or around that row,
  # not to every run of the line: runs the wrap hasn't reached yet all
  # move by the same amount at each row, so they wait under one shared
  # offset and are only adjusted one by one once the row being cut could
  # reach them. A long line with many links wraps in time proportional to
  # its rows plus its runs.
  #
  # @param width [Integer] maximum line width in characters; values below 1
  #   (a window only one or two columns wide) are treated as 1
  # @param indent [Boolean] whether continuation lines get 2-space indent
  # @return [Array<StyledText>] wrapped lines
  def wrap(width, indent: true)
    # A width of 0 never consumes text and loops forever; a negative width
    # makes the slices nil.
    width = [width, 1].max
    return [dup_with_runs] if @text.length <= width

    # Disable indent when width is too narrow (indent adds 2 chars,
    # which would make continuation lines wider than the width and
    # cause an infinite loop).
    indent = false if indent && width <= 3

    lines = []
    remaining_text = @text.dup

    # Runs not reached yet, ordered by where they begin (the nearer of
    # their start and end), all offset by +shift+ from their positions in
    # @runs. A run joins +active+, as [index in @runs, run, start, end]
    # kept in @runs order, once the row being cut reaches that position.
    # Until then it starts and ends past the cut, so moving it never hits
    # the clamp at 0, the removal of ended runs or the indent's start-at-0
    # case below: the shared offset moves it exactly as they would.
    waiting = @runs.each_with_index.sort_by { |run, index| [[run[:start] || 0, run[:end] || 0].min, index] }
    next_waiting = 0
    shift = 0
    active = []

    while remaining_text.length > 0
      # Find a good break point
      if remaining_text.length <= width
        line = remaining_text
      else
        line = remaining_text[0, width]
        if (break_pos = line.rindex(/\s/))
          # Only break at whitespace if it would leave non-whitespace
          # content on this line. Otherwise we'd emit a whitespace-only
          # line and indent would re-add whitespace → infinite loop.
          candidate = remaining_text[0, break_pos + 1]
          line = candidate if candidate.strip.length > 0
        end
      end

      line_len = line.length

      # Activate the waiting runs this row reaches
      while next_waiting < waiting.length
        run, index = waiting[next_waiting]
        start = (run[:start] || 0) + shift
        stop = (run[:end] || 0) + shift
        break if [start, stop].min > line_len

        active.insert(active.bsearch_index { |entry| entry[0] > index } || active.length, [index, run, start, stop])
        next_waiting += 1
      end

      # Build runs for this line segment
      line_runs = active.filter_map do |_index, run, start, stop|
        next if start >= line_len
        next if stop <= 0

        run.merge(start: [start, 0].max, end: [stop, line_len].min)
      end

      lines << self.class.allocate.adopt(line, line_runs)

      # Advance remaining text, and stop when nothing but a line ending is
      # left (the length test spares chomping a copy of the rest on every
      # row)
      remaining_text = remaining_text[line_len..]
      break if remaining_text.nil? || (remaining_text.length <= 2 && remaining_text.chomp.empty?)

      # Shift run positions
      shift -= line_len
      active.each do |entry|
        entry[2] = [entry[2] - line_len, 0].max
        entry[3] -= line_len
      end
      active.delete_if { |entry| entry[3] <= 0 }

      # Handle indent/dedent for continuation lines
      if indent
        if remaining_text[0] == ' '
          remaining_text = " #{remaining_text}"
          shift += 1
          active.each do |entry|
            entry[2] += (entry[2] == 0 ? 2 : 1)
            entry[3] += 1
          end
        else
          remaining_text = "  #{remaining_text}"
          shift += 2
          active.each do |entry|
            entry[2] += 2
            entry[3] += 2
          end
        end
      elsif remaining_text[0] == ' '
        remaining_text = remaining_text[1..]
        shift -= 1
        active.each do |entry|
          entry[2] -= 1
          entry[3] -= 1
        end
      end
    end

    lines
  end

  # Create a deep copy with independent text and runs.
  #
  # @return [StyledText]
  def dup_with_runs
    self.class.new(@text, @runs)
  end

  # @return [String] inspection string for debugging
  def inspect
    "#<StyledText text=#{@text.inspect} runs=#{@runs.length}>"
  end

  protected

  # Fill an allocated, uninitialized instance with text and runs the
  # caller built for it and hands over, without copying them (unlike
  # {#initialize}). {#wrap} builds every row this way.
  #
  # @param text [String] the text, owned by this instance from now on
  # @param runs [Array<Hash>] the runs, owned by this instance from now on
  # @return [self]
  def adopt(text, runs)
    @text = text
    @runs = runs
    self
  end

  private

  # Where a run starting at +pos+ starts after +edits+ (sorted, as in
  # {#replace_ranges}): a start inside a replaced span moves to the start
  # of its replacement; a start at an insertion point moves past it.
  #
  # @param pos [Integer] run start in the original text
  # @param edits [Array<Array(Integer, Integer, String)>] sorted edits
  # @return [Integer] run start in the edited text
  def map_run_start(pos, edits)
    shift = 0
    edits.each do |from, to, replacement|
      return pos + shift if pos < from
      return from + shift if pos < to

      shift += replacement.length - (to - from)
    end
    pos + shift
  end

  # Where a run ending at +pos+ (exclusive) ends after +edits+: an end
  # inside a replaced span moves to the end of its replacement; an end at
  # an insertion point stays before it.
  #
  # @param pos [Integer] run end in the original text
  # @param edits [Array<Array(Integer, Integer, String)>] sorted edits
  # @return [Integer] run end in the edited text
  def map_run_end(pos, edits)
    shift = 0
    edits.each do |from, to, replacement|
      return pos + shift if pos <= from
      return from + shift + replacement.length if pos <= to

      shift += replacement.length - (to - from)
    end
    pos + shift
  end
end
