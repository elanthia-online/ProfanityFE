# frozen_string_literal: true

# The color spans open while a server line is parsed, and the color runs
# they have recorded for the text not yet handed off.
#
# A span opens at a tag (bold, a preset, a color, a style, a link) at a
# position in the line's text, and closes at the matching tag, where it
# records a color run (a Hash with +:start+, +:end+ and the span's colors).
# The text parsed so far is handed off at a mid-line flush (a stream
# switch, a room capture) and at the end of the line; each hand-off takes
# the runs recorded for its text. Each kind of span has its own rules for
# closing and for each hand-off, in {POLICIES}.
#
# Positions are offsets into the text since the last hand-off. A span
# carried past a hand-off restarts at 0.
#
# @example
#   spans = SpanTracker.new
#   spans.open(:bold, 0, fg: 'ffff00', bg: nil)
#   spans.close(:bold, 6)
#   spans.split_at_line_end(10) # => [{ start: 0, fg: 'ffff00', bg: nil, end: 6 }]
#   spans.end_line
class SpanTracker
  # How one kind of span behaves.
  #
  # @!attribute [r] stack
  #   @return [Boolean] true: spans nest, and a close ends the innermost;
  #     false: one slot, and an open replaces the span already open
  # @!attribute [r] record
  #   @return [Symbol] which closed spans record a run: +:always+,
  #     +:colored+ (with a fg or bg), or +:colored_text+ (with a fg or bg,
  #     and around some text)
  # @!attribute [r] at_flush
  #   @return [Symbol] at a mid-line flush: +:split+ (record a run up to the
  #     flush and restart at 0 in the text that follows), +:split_colored+
  #     (the same, but record the run only with a fg or bg), or +:drop+
  # @!attribute [r] at_last_text
  #   @return [Symbol] when the line's last text is handed off: +:split+
  #     (as at a flush), +:drop+, or +:keep+ (record nothing)
  # @!attribute [r] at_line_end
  #   @return [Symbol] after the line: +:drop+, +:keep+ for the next line,
  #     or +:until_prompt+ (keep for the next line, unless the line had a
  #     prompt; see {#prompt})
  Policy = Data.define(:stack, :record, :at_flush, :at_last_text, :at_line_end)

  # The rules for each kind of span, in the order a hand-off records their
  # runs.
  #
  # A link is dropped with every text handed off: one without a cmd
  # attribute takes its command from its text, which a flush would cut. So
  # none is left at the end of a line. Bold left open at the end of a line
  # is carried to the next by GameTextProcessor#carry_bold, which closes it
  # on each line and reopens it on the next. A style left open is kept for
  # the next line here, and like carried bold it ends with a line that has
  # a prompt.
  POLICIES = [
    # kind   stack  record         at_flush        at_last_text  at_line_end
    [:bold,   true,  :colored,      :split_colored, :keep,        :drop],
    [:preset, true,  :colored,      :split_colored, :keep,        :drop],
    [:style,  false, :colored_text, :split,         :split,       :until_prompt],
    [:color,  true,  :always,       :split,         :split,       :drop],
    [:link,   true,  :colored,      :drop,          :drop,        :keep]
  ].to_h { |kind, *rules| [kind, Policy.new(*rules)] }.freeze

  # Start with no span open and no run recorded.
  def initialize
    @open = POLICIES.keys.to_h { |kind| [kind, []] }
    @runs = []
    @prompt = false
  end

  # Open a span.
  #
  # @param kind [Symbol] a key of {POLICIES}
  # @param start [Integer] position in the text where the span starts
  # @param attrs [Hash] the span's colors (+fg+, +bg+, +ul+) and, for a
  #   link, its +cmd+; they become the run's keys, in the order given
  # @return [void]
  def open(kind, start, **attrs)
    span = { start: start, **attrs }
    POLICIES.fetch(kind).stack ? @open[kind].push(span) : @open[kind].replace([span])
  end

  # Close the innermost open span of a kind, recording its run if the
  # kind's policy says so. Does nothing if none is open.
  #
  # @param kind [Symbol] a key of {POLICIES}
  # @param end_pos [Integer] position in the text where the span ends
  # @yieldparam span [Hash] the span, with its +:end+ set, before its run is
  #   recorded (a link fills in its command here)
  # @return [Hash, nil] the closed span, or nil if none was open
  def close(kind, end_pos)
    return unless (span = @open.fetch(kind).pop)

    span[:end] = end_pos
    yield span if block_given?
    @runs.push(span) if record?(span, POLICIES[kind].record)
    span
  end

  # Hand off the text parsed so far at a mid-line flush.
  #
  # @param length [Integer] length of the text flushed
  # @return [Array<Hash>] the runs for that text; recording starts afresh
  def split_at_flush(length)
    hand_off(length, :at_flush)
  end

  # Hand off the line's last text (possibly empty). Call {#end_line} once
  # the line is done.
  #
  # @param length [Integer] length of the text
  # @return [Array<Hash>] the runs for that text; recording starts afresh
  def split_at_line_end(length)
    hand_off(length, :at_last_text)
  end

  # Note a prompt in the line: the spans that last +:until_prompt+ end
  # with the line (see {#end_line}).
  #
  # @return [void]
  def prompt
    @prompt = true
  end

  # End the line: drop the spans the next line doesn't inherit. Called
  # even when parsing the line failed.
  #
  # @return [void]
  def end_line
    ending = @prompt ? %i[drop until_prompt] : %i[drop]
    POLICIES.each { |kind, policy| @open[kind].clear if ending.include?(policy.at_line_end) }
    @prompt = false
  end

  # The runs recorded since the last hand-off, for text that is used
  # without being handed off (an empty room component).
  #
  # @return [Array<Hash>] a copy of the list
  def runs
    @runs.dup
  end

  # The innermost open span of a kind.
  #
  # @param kind [Symbol] a key of {POLICIES}
  # @return [Hash, nil] a copy of the span, or nil if none is open
  def open_span(kind)
    @open.fetch(kind).last&.dup
  end

  private

  # Record each open span's run up to a hand-off as its policy says, and
  # take the runs recorded.
  #
  # @param length [Integer] length of the text handed off
  # @param rule [Symbol] the {Policy} member that applies (+:at_flush+ or
  #   +:at_last_text+)
  # @return [Array<Hash>] the runs for the text handed off
  def hand_off(length, rule)
    POLICIES.each do |kind, policy|
      case (action = policy.public_send(rule))
      when :split, :split_colored
        @open[kind].each do |span|
          @runs.push(span.merge(end: length)) if action == :split || colored?(span)
          span[:start] = 0
        end
      when :drop
        @open[kind].clear
      end
    end
    runs = @runs
    @runs = []
    runs
  end

  # Whether a closed span records a run.
  #
  # @param span [Hash] the span, with +:start+ and +:end+
  # @param rule [Symbol] the kind's {Policy#record}
  # @return [Boolean]
  def record?(span, rule)
    case rule
    when :always then true
    when :colored then colored?(span)
    when :colored_text then span[:start] < span[:end] && colored?(span)
    end
  end

  # Whether a span has a foreground or background color.
  #
  # @param span [Hash] the span
  # @return [Boolean]
  def colored?(span)
    !!(span[:fg] || span[:bg])
  end
end
