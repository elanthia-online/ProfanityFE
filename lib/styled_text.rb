# frozen_string_literal: true

# Bundles a text string with its color/style runs.
#
# Replaces the fragile pattern of passing a String and a parallel
# Array<Hash> of color regions through the rendering pipeline. All
# position-sensitive operations (slicing, lstrip, wrapping) adjust
# the run positions automatically so callers never do manual arithmetic.
#
# Runs are hashes with :start, :end (character positions in the text),
# and optional :fg, :bg, :ul, :cmd, :priority keys. They are stored in
# insertion order but may overlap — the renderer resolves priority by
# smallest range first (most specific wins).
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
  #   :fg, :bg, :ul, :cmd, :priority
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
    end_pos = range.end || @text.length
    @text.length if end_pos > @text.length
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

  # Word-wrap the text to the given width, returning an array of
  # StyledText instances — one per wrapped line. Run positions are
  # correctly split across lines.
  #
  # @param width [Integer] maximum line width in characters
  # @param indent [Boolean] whether continuation lines get 2-space indent
  # @return [Array<StyledText>] wrapped lines
  def wrap(width, indent: true)
    return [dup_with_runs] if @text.length <= width

    # Disable indent when width is too narrow (indent adds 2 chars,
    # which would make continuation lines wider than the width and
    # cause an infinite loop).
    indent = false if indent && width <= 3

    lines = []
    remaining_text = @text.dup
    remaining_runs = @runs.map(&:dup)

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
          if candidate.strip.length > 0
            line = candidate
          else
            line = remaining_text[0, width]
          end
        end
      end

      line_len = line.length

      # Build runs for this line segment
      line_runs = remaining_runs.filter_map do |run|
        next if (run[:start] || 0) >= line_len
        next if (run[:end] || 0) <= 0

        run.dup.merge(
          start: [(run[:start] || 0), 0].max,
          end: [(run[:end] || 0), line_len].min
        )
      end

      lines << self.class.new(line, line_runs)

      # Advance remaining text and shift run positions
      remaining_text = remaining_text[line_len..]
      break if remaining_text.nil? || remaining_text.chomp.empty?

      remaining_runs.each do |run|
        run[:start] = [(run[:start] || 0) - line_len, 0].max
        run[:end] = (run[:end] || 0) - line_len
      end
      remaining_runs.delete_if { |run| (run[:end] || 0) <= 0 }

      # Handle indent/dedent for continuation lines
      if indent
        if remaining_text[0] == ' '
          remaining_text = " #{remaining_text}"
          remaining_runs.each do |run|
            run[:start] = (run[:start] || 0) + (run[:start] == 0 ? 2 : 1)
            run[:end] = (run[:end] || 0) + 1
          end
        else
          remaining_text = "  #{remaining_text}"
          remaining_runs.each do |run|
            run[:start] = (run[:start] || 0) + 2
            run[:end] = (run[:end] || 0) + 2
          end
        end
      elsif remaining_text[0] == ' '
        remaining_text = remaining_text[1..]
        remaining_runs.each do |run|
          run[:start] = (run[:start] || 0) - 1
          run[:end] = (run[:end] || 0) - 1
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
end
