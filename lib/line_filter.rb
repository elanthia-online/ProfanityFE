# frozen_string_literal: true

require_relative 'xml_tokenizer'

# Decides which server lines reach the parser: gags (general and
# multi-line), gag logging (--log-gags), and collapsing runs of blank lines.
#
# A gag drops a line's text but keeps its stream and style tags, so a
# gagged <popStream/> still closes its stream and a gagged <style id=""/>
# still closes its style.
class LineFilter
  # Safety cap: a multi-line gag whose end pattern (or prompt) never arrives
  # is released after this many suppressed lines so it cannot swallow the
  # stream. Real blocks (e.g. sanowret crystal knowledge) are 2-3 lines.
  MULTILINE_GAG_MAX_LINES = 100

  # Stream tags kept when a gag drops a line's text. Losing a <popStream/>
  # with the text would leave routing stuck on that stream (e.g. game text
  # landing in the spell window), so gagged lines keep these tags and gag
  # logging flags them. Element names; see #tags_named.
  STREAM_TAGS = %w[pushStream popStream clearStream].freeze

  # Tags kept when a gag drops a line's text: the stream tags, and style
  # tags, whose <style id=""/> closes a style (losing it would leave the
  # style coloring every later line up to a prompt). Element names; see
  # #tags_named.
  KEPT_TAGS = [*STREAM_TAGS, 'style'].freeze

  # Longest gag pattern source quoted in a gag log line. Some gags are long
  # alternations; the prefix is enough to find the gag in the settings XML.
  GAG_LOG_PATTERN_LIMIT = 80

  # @param shared_state [SharedState] read for +log_gags+ (--log-gags)
  def initialize(shared_state:)
    @state = shared_state

    # Multi-line gag state: the active { start:, end: } gag being suppressed
    # (nil when not inside a block) and how many lines it has swallowed so far.
    @active_multiline_gag = nil
    @multiline_gag_lines = 0

    # Blank lines in a row; only the first of a run is passed on.
    @emptycount = 0

    # Whether the last line filtered was gagged
    @gagged = false
  end

  # Whether a gag dropped the text of the last line filtered, passing on
  # only its kept tags ({KEPT_TAGS}).
  #
  # @return [Boolean]
  def gagged?
    @gagged
  end

  # Filter one server line.
  #
  # A gagged line keeps only its stream and style tags ({KEPT_TAGS}), and
  # is dropped when it has none. A blank line is passed on only when the
  # previous line wasn't blank (a gagged line with kept tags doesn't count
  # either way).
  #
  # @param line [String] raw server line, line ending removed
  # @return [String, nil] the line to process, or nil to drop it
  def filter(line)
    gagged = multiline_gag?(line)
    if !gagged && (gag = GagPatterns.match_general(line))
      log_gagged_line('general', gag, line)
      gagged = true
    end

    @gagged = gagged
    if gagged
      # A gag hides the line's text, never its stream or style tags:
      # dropping a <popStream/> would leave routing stuck on that stream.
      line = tags_named(line, KEPT_TAGS).join
      return if line.empty?
    elsif line.empty?
      @emptycount += 1
      return if @emptycount > 1
    else
      @emptycount = 0
    end
    line
  end

  private

  # Decide whether a raw server line should be suppressed as part of a
  # multi-line gag block, advancing the gag state machine as a side effect.
  #
  # When no block is active, the line is tested against the configured
  # multi-line gag start patterns; a match begins a block and suppresses
  # the start line. While a block is active every line is suppressed until:
  #   - the gag's end pattern matches (that end line is also suppressed), or
  #   - for prompt-terminated gags (no end pattern), a prompt line is seen
  #     (the prompt is NOT suppressed and passes through normally), or
  #   - the safety cap is exceeded (the block is released, line passes through).
  #
  # @param line [String] raw server line (post-chomp, XML tags intact)
  # @return [Boolean] true if the line's text should be suppressed (its
  #   stream tags are still processed)
  # @api private
  def multiline_gag?(line)
    if @active_multiline_gag
      gag = @active_multiline_gag
      @multiline_gag_lines += 1

      if @multiline_gag_lines > MULTILINE_GAG_MAX_LINES
        ProfanityLog.write('gag', "multiline gag exceeded #{MULTILINE_GAG_MAX_LINES} lines; releasing")
        @active_multiline_gag = nil
        false
      elsif gag[:end]
        # Explicit end pattern: the end line is part of the block (suppressed).
        @active_multiline_gag = nil if line.match?(gag[:end])
        log_gagged_line('multiline', gag[:start], line)
        true
      elsif prompt_line?(line)
        # Prompt-terminated: stop gagging and let the prompt line through.
        @active_multiline_gag = nil
        false
      else
        log_gagged_line('multiline', gag[:start], line)
        true
      end
    elsif (gag = GagPatterns.match_multiline_start(line))
      @active_multiline_gag = gag
      @multiline_gag_lines = 0
      log_gagged_line('multiline', gag[:start], line)
      true
    else
      false
    end
  end

  # Whether a raw line has a <prompt> start tag, as the tag dispatcher
  # reads the line.
  #
  # @param line [String] raw server line
  # @return [Boolean]
  # @api private
  def prompt_line?(line)
    XmlTokenizer.tags(line).map { |tag| XmlTokenizer.start_tag_name(tag) }.include?('prompt')
  end

  # The start tags of a raw line with the given element names, as written
  # and in order, as the tag dispatcher reads the line.
  #
  # @param line [String] raw server line
  # @param names [Array<String>] element names ({STREAM_TAGS}, {KEPT_TAGS})
  # @return [Array<String>] the tags
  # @api private
  def tags_named(line, names)
    XmlTokenizer.tags(line).select { |tag| names.include?(XmlTokenizer.start_tag_name(tag)) }
  end

  # Log a gagged line in full when +--log-gags+ is active.
  #
  # The line is logged raw (XML tags intact) and inspected so control
  # characters are visible. Lines carrying a stream tag are marked
  # +STREAM-TAG+; the tag itself is still processed after the text is dropped.
  #
  # @param kind [String] which gag type matched ('general' or 'multiline')
  # @param pattern [Regexp] the gag pattern responsible (start pattern for multiline)
  # @param line [String] raw server line being dropped
  # @return [void]
  # @api private
  def log_gagged_line(kind, pattern, line)
    return unless @state.log_gags

    marker = tags_named(line, STREAM_TAGS).empty? ? '' : ' STREAM-TAG'
    source = pattern.source
    source = "#{source[0, GAG_LOG_PATTERN_LIMIT]}..." if source.length > GAG_LOG_PATTERN_LIMIT
    ProfanityLog.write('gag', "#{kind}#{marker} /#{source}/ #{line.inspect}")
  end
end
