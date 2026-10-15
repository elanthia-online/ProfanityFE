# frozen_string_literal: true

require_relative 'xml_tokenizer'

# Decides which server lines reach the parser: gags (general and
# multi-line), gag logging (--log-gags), and collapsing runs of blank lines.
#
# A gag drops a line's text but keeps its stream and style tags, so a
# gagged <popStream/> still closes its stream and a gagged <style id=""/>
# still closes its style.
#
# A gag pattern is tested against the raw line (tags included), then
# against the line's text (see #line_text): a gag written against what
# the game shows still matches a line whose text the game interleaves
# with tags (the <a exist> links of the stream DragonRealms sends when
# Lich identifies as the Saga client, or a creature's <crtrStatus/> tags
# in front of a line).
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

  # Elements whose text is not the line's but a window's (a room
  # component's text goes to the room window), left out of a line's text
  # (see #line_text). A gag on main's room lines must not match the
  # component beside them: a gagged line keeps only {KEPT_TAGS}, so the
  # component would be lost with its text.
  COMPONENT_ELEMENTS = %w[component compDef].freeze

  # A part of DragonRealms' one-line room (the <room> block it sends when
  # Lich identifies as the Saga client; see TagHandlers#handle_room_open),
  # captured with its element name. Each part is gagged on its own, as
  # each of the old stream's room lines is (see #gag_room_parts).
  ROOM_PART = %r{<(name|description|exists|players|exits|extra)>.*?</\1>}

  # Longest gag pattern source quoted in a gag log line. Some gags are long
  # alternations; the prefix is enough to find the gag in the settings XML.
  GAG_LOG_PATTERN_LIMIT = 80

  # @param shared_state [SharedState] read for +log_gags+ (--log-gags)
  # @param xml_escapes [Hash<String, String>] XML entity to character
  #   mappings, decoded in a line's text (see #line_text)
  def initialize(shared_state:, xml_escapes: {})
    @state = shared_state
    @xml_escapes = xml_escapes

    # Multi-line gag state: the active { start:, end: } gag being suppressed
    # (nil when not inside a block) and how many lines it has swallowed so far.
    @active_multiline_gag = nil
    @multiline_gag_lines = 0

    # Blank lines in a row; only the first of a run is passed on.
    @emptycount = 0

    # Whether the last line filtered was gagged
    @gagged = false

    # The line being filtered and its text, once worked out (see #line_text)
    @text_of = nil
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
    @text_of = nil
    gagged = multiline_gag?(line)
    if gagged
      # The multi-line gag dropped the line
    elsif room_line?(line)
      line = gag_room_parts(line)
    elsif (gag, kind = general_gag(line))
      log_gagged_line(kind, gag, line)
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
        @active_multiline_gag = nil if line.match?(gag[:end]) || line_text(line).match?(gag[:end])
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
    elsif (gag = GagPatterns.match_multiline_start(line) || GagPatterns.match_multiline_start(line_text(line)))
      @active_multiline_gag = gag
      @multiline_gag_lines = 0
      log_gagged_line('multiline', gag[:start], line)
      true
    else
      false
    end
  end

  # Whether a line holds a whole <room> block (see {ROOM_PART}).
  #
  # @param line [String] raw server line
  # @return [Boolean]
  # @api private
  def room_line?(line)
    line.include?('<room>') && line.include?('</room>')
  end

  # Gag each part of a <room> block on its own (see {ROOM_PART}), so a gag
  # on one part ("Also here:", "You also see ...") drops that part only,
  # as it dropped the old stream's line for it, and not the whole room. A
  # gagged part keeps its tags, empty: the room is read as if the game had
  # sent the part with nothing in it. A gag on the line as a whole doesn't
  # apply.
  #
  # @param line [String] raw server line holding a <room> block
  # @return [String] the line, each gagged part emptied
  # @api private
  def gag_room_parts(line)
    line.gsub(ROOM_PART) do |part|
      element = Regexp.last_match(1)
      gag, kind = general_gag(part)
      next part unless gag

      log_gagged_line("#{kind} room #{element}", gag, part)
      "<#{element}></#{element}>"
    end
  end

  # The general gag that matches a line, tested against the raw line and
  # then against its text (see #line_text), and the kind of match for the
  # gag log.
  #
  # @param line [String] raw server line
  # @return [Array(Regexp, String), nil] the gag and +'general'+ or
  #   +'general (text)'+; nil when no general gag matches
  # @api private
  def general_gag(line)
    if (gag = GagPatterns.match_general(line))
      [gag, 'general']
    elsif (text = line_text(line)) != line && (gag = GagPatterns.match_general(text))
      [gag, 'general (text)']
    end
  end

  # A line's text as the game shows it: its text segments, as the tag
  # dispatcher reads the line, with XML entities decoded. The content of
  # a paired tag (prompt, spell, left, right, inv, compass; see
  # XmlTokenizer::PAIRED_TAGS) isn't text, and neither is the text of a
  # {COMPONENT_ELEMENTS} element.
  #
  # Worked out once per line filtered. A line with no tag and no entity is
  # its own text.
  #
  # @param line [String] raw server line
  # @return [String]
  # @api private
  def line_text(line)
    return line unless line.include?('<') || line.include?('&')
    return @text_of[1] if @text_of&.first.equal?(line)

    @text_of = [line, read_text(line)]
    @text_of[1]
  end

  # A line's text (see #line_text), read from its segments.
  #
  # @param line [String] raw server line
  # @return [String]
  # @api private
  def read_text(line)
    depth = 0
    text = XmlTokenizer.tokenize(line).each_with_object(+'') do |(type, segment), out|
      if type == :text
        out << segment if depth.zero?
      elsif COMPONENT_ELEMENTS.include?(XmlTokenizer.tag_name(segment))
        depth += 1 if XmlTokenizer.start_tag_name(segment) && !segment.end_with?('/>')
        depth -= 1 if segment.start_with?('</') && depth.positive?
      end
    end
    @xml_escapes.each { |entity, char| text.gsub!(entity, char) }
    text
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
  # @param kind [String] which gag type matched ('general', 'general (text)'
  #   for a match on the line's text only, or 'multiline')
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
