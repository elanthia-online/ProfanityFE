# frozen_string_literal: true

require_relative 'xml_tokenizer'

# Decides which server lines reach the parser: gags (general and
# multi-line), gag logging (--log-gags), and collapsing runs of blank lines.
#
# A gag pattern is tested against the raw line (tags included), then
# against the line's text (see #line_text): a gag written against what
# the game shows still matches a line whose text the game interleaves
# with tags (the <a exist> links of the stream DragonRealms sends when
# Lich identifies as the Saga client, or a creature's <crtrStatus/> tags
# in front of a line).
#
# A gag that matches the raw line drops the line but keeps its stream and
# style tags, so a gagged <popStream/> still closes its stream and a
# gagged <style id=""/> still closes its style. A gag that matches only
# the line's text drops only that text and the tags that color or link
# it: every other tag of the line is kept, and a component whole, since
# none of them was part of the match (a GemStone search line carries the
# experience bars in front of its text; a DragonRealms creature line can
# carry the room's objects after it).
class LineFilter
  # Safety cap: a multi-line gag whose end pattern (or prompt) never arrives
  # is released after this many suppressed lines so it cannot swallow the
  # stream. Real blocks (e.g. sanowret crystal knowledge) are 2-3 lines.
  MULTILINE_GAG_MAX_LINES = 100

  # Stream tags kept when a gag drops a line. Losing a <popStream/> with
  # the text would leave routing stuck on that stream (e.g. game text
  # landing in the spell window), so gagged lines keep these tags and gag
  # logging flags them. Element names; see #tags_named.
  STREAM_TAGS = %w[pushStream popStream clearStream].freeze

  # Tags kept when a gag on the raw line drops it: the stream tags, and style
  # tags, whose <style id=""/> closes a style (losing it would leave the
  # style coloring every later line up to a prompt). Element names; see
  # #tags_named.
  KEPT_TAGS = [*STREAM_TAGS, 'style'].freeze

  # Elements whose text is not the line's but a window's (a room
  # component's text goes to the room window), left out of a line's text
  # (see #line_text). A gag on main's room lines must not match the
  # component beside them: a line gagged as sent keeps only {KEPT_TAGS},
  # so the component would be lost with its text.
  COMPONENT_ELEMENTS = %w[component compDef].freeze

  # A part of DragonRealms' one-line room (the <room> block it sends when
  # Lich identifies as the Saga client; see TagHandlers#handle_room_open),
  # captured with its element name. Each part is gagged on its own, as
  # each of the old stream's room lines is (see #gag_room_parts).
  ROOM_PART = %r{<(name|description|exists|players|exits|extra)>.*?</\1>}

  # Tags that only color or link the text they wrap (bold, presets, colors,
  # links). A gag that matched a line's text drops them with it (see
  # #without_text): nothing of them is left to show, and a roomDesc
  # preset would start capturing the room's description.
  MARKUP_TAGS = %w[pushBold popBold b preset color a d].freeze

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
  # only its tags (see #filter).
  #
  # @return [Boolean]
  def gagged?
    @gagged
  end

  # Filter one server line.
  #
  # A line gagged as sent keeps only its stream and style tags
  # ({KEPT_TAGS}); a line gagged by its text only keeps all its tags but
  # those of the text ({MARKUP_TAGS}; see #without_text). Either is dropped when nothing is left. A blank line
  # is passed on only when the previous line wasn't blank (a gagged line
  # with kept tags doesn't count either way).
  #
  # @param line [String] raw server line, line ending removed
  # @return [String, nil] the line to process, or nil to drop it
  def filter(line)
    @text_of = nil
    matched = multiline_gag(line)
    if matched
      # The multi-line gag dropped the line
    elsif room_line?(line)
      line = gag_room_parts(line)
    elsif (gag, kind, matched = general_gag(line))
      log_gagged_line(kind, gag, line)
    end

    @gagged = !matched.nil?
    if matched
      # A gag hides the line's text, never its stream or style tags:
      # dropping a <popStream/> would leave routing stuck on that stream.
      line = matched == :text ? without_text(line) : tags_named(line, KEPT_TAGS).join
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
  # multi-line gag block, and on what it matched, advancing the gag state
  # machine as a side effect.
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
  # @return [Symbol, nil] nil if the line isn't suppressed; +:text+ for a
  #   start or end line matched by its text only, +:line+ for any other
  #   suppressed line (see #filter for the tags each keeps)
  # @api private
  def multiline_gag(line)
    if @active_multiline_gag
      gag = @active_multiline_gag
      @multiline_gag_lines += 1

      if @multiline_gag_lines > MULTILINE_GAG_MAX_LINES
        ProfanityLog.write('gag', "multiline gag exceeded #{MULTILINE_GAG_MAX_LINES} lines; releasing")
        @active_multiline_gag = nil
        nil
      elsif gag[:end]
        # Explicit end pattern: the end line is part of the block (suppressed).
        matched = match_on(line, gag[:end])
        @active_multiline_gag = nil if matched
        log_gagged_line('multiline', gag[:start], line)
        matched || :line
      elsif prompt_line?(line)
        # Prompt-terminated: stop gagging and let the prompt line through.
        @active_multiline_gag = nil
        nil
      else
        log_gagged_line('multiline', gag[:start], line)
        :line
      end
    elsif (gag = GagPatterns.match_multiline_start(line))
      start_multiline_gag(gag, line, :line)
    elsif (text = gag_text(line)) && (gag = GagPatterns.match_multiline_start(text))
      start_multiline_gag(gag, line, :text)
    end
  end

  # Begin suppressing a multi-line gag's block at its start line.
  #
  # @param gag [Hash] the multi-line gag, { start:, end: }
  # @param line [String] raw server line it starts on
  # @param matched [Symbol] what the start pattern matched (+:line+ or +:text+)
  # @return [Symbol] +matched+
  # @api private
  def start_multiline_gag(gag, line, matched)
    @active_multiline_gag = gag
    @multiline_gag_lines = 0
    log_gagged_line('multiline', gag[:start], line)
    matched
  end

  # What a pattern matches of a line: the raw line, or else its text.
  #
  # @param line [String] raw server line
  # @param pattern [Regexp] the pattern
  # @return [Symbol, nil] +:line+, +:text+ (see #gag_text), or nil
  # @api private
  def match_on(line, pattern)
    if line.match?(pattern)
      :line
    elsif gag_text(line)&.match?(pattern)
      :text
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
  # apply. A part that is empty already is left alone: a gag written
  # against its tags (+<players>+) has nothing to drop, and logs nothing.
  # (A gag on blank lines doesn't match an empty part: it has no text; see
  # #gag_text.) Unlike a gagged line (see #filter), a gagged part keeps
  # none of the tags inside it, whether the gag matched the part as sent or
  # its text only (a part's tags are the links and directions of its text).
  #
  # @param line [String] raw server line holding a <room> block
  # @return [String] the line, each gagged part emptied
  # @api private
  def gag_room_parts(line)
    line.gsub(ROOM_PART) do |part|
      element = Regexp.last_match(1)
      emptied = "<#{element}></#{element}>"
      next part if part == emptied

      gag, kind = general_gag(part)
      next part unless gag

      log_gagged_line("#{kind} room #{element}", gag, part)
      emptied
    end
  end

  # The general gag that matches a line, tested against the raw line and
  # then against its text (see #line_text), the kind of match for the gag
  # log, and what it matched.
  #
  # @param line [String] raw server line
  # @return [Array(Regexp, String, Symbol), nil] the gag, then +'general'+
  #   and +:line+, or +'general (text)'+ and +:text+; nil when no general
  #   gag matches
  # @api private
  def general_gag(line)
    if (gag = GagPatterns.match_general(line))
      [gag, 'general', :line]
    elsif (text = gag_text(line)) && (gag = GagPatterns.match_general(text))
      [gag, 'general (text)', :text]
    end
  end

  # The text a gag is tried against after the raw line (see #line_text),
  # or nil when there is nothing more to try: the text is the raw line
  # itself, or it is empty. A line with no text (a prompt, a room
  # component, a status tag) shows nothing a gag could hide, so a gag that
  # matches an empty line (+^$+, +^\s*$+) still matches blank lines only,
  # not every line of tags.
  #
  # @param line [String] raw server line
  # @return [String, nil]
  # @api private
  def gag_text(line)
    text = line_text(line)
    text unless text.empty? || text == line
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
    text = +''
    each_segment(line) { |segment, own_text| text << segment if own_text }
    @xml_escapes.each { |entity, char| text.gsub!(entity, char) }
    text
  end

  # A line with its text (see #line_text) taken out, and the tags that
  # color or link it ({MARKUP_TAGS}): every other tag, and a
  # {COMPONENT_ELEMENTS} element whole, as sent and in order. What a gag
  # that matched the text only leaves of the line.
  #
  # @param line [String] raw server line
  # @return [String]
  # @api private
  def without_text(line)
    kept = +''
    each_segment(line) do |segment, own_text, in_component|
      next if own_text
      next if !in_component && MARKUP_TAGS.include?(XmlTokenizer.tag_name(segment))

      kept << segment
    end
    kept
  end

  # Each segment of a line, as the tag dispatcher reads it (see
  # XmlTokenizer.tokenize), and whether it is the line's own text: a text
  # segment outside any {COMPONENT_ELEMENTS} element.
  #
  # @param line [String] raw server line
  # @yieldparam segment [String] a tag (a paired tag with its content) or a text segment
  # @yieldparam own_text [Boolean] whether the segment is the line's text
  # @yieldparam in_component [Boolean] whether the segment is part of a
  #   {COMPONENT_ELEMENTS} element, its own tags included
  # @return [void]
  # @api private
  def each_segment(line)
    depth = 0
    XmlTokenizer.tokenize(line).each do |type, segment|
      if type == :text
        yield segment, depth.zero?, depth.positive?
      elsif COMPONENT_ELEMENTS.include?(XmlTokenizer.tag_name(segment))
        depth += 1 if XmlTokenizer.start_tag_name(segment) && !segment.end_with?('/>')
        yield segment, false, true
        depth -= 1 if segment.start_with?('</') && depth.positive?
      else
        yield segment, false, depth.positive?
      end
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
  # @param kind [String] which gag type matched ('general', 'general (text)'
  #   for a match on the line's text only, or 'multiline'); for a part of a
  #   <room> block, the general kind followed by +room+ and the part's
  #   element name ('general (text) room exists'; see #gag_room_parts)
  # @param pattern [Regexp] the gag pattern responsible (start pattern for multiline)
  # @param line [String] raw server line being dropped, or the raw room part
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
