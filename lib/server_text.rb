# frozen_string_literal: true

require 'strscan'
require_relative 'xml_tokenizer'

# server_text.rb: the line read from the game connection, made ASCII
# before anything else sees it.
#
# Requiring this file loads only {XmlTokenizer}.

# Makes each line read from the game connection ASCII, before any gag,
# highlight or window sees it ({ServerReader} calls {.normalize!}).
#
# Game text is ASCII. Other characters come from Lich and its scripts:
# their own banners, punctuation and arrows (box drawing, curly quotes,
# dashes), and other players' text that a script relays. They are what the
# Regexp and String bugs Ruby fixed on 2026-11-18 need: a highlight the
# user added with +.highlight+ or +(?i)+ could read past the end of a
# buffer on a line with a character such as U+00DF (sharp s) in it, and a
# case-insensitive backreference could match past the end of a line with a
# NUL in it. A NUL also makes the curses gem raise when it draws the line
# with waddstr.
#
# The characters scripts send most become their ASCII look-alikes
# ({ASCII_IN_TEXT}, {ASCII_IN_ATTRIBUTE}, box drawing); any other character
# outside ASCII, and each byte that isn't valid UTF-8, becomes
# {REPLACEMENT}; NUL bytes are deleted.
#
# The line's tags stay as they were. An attribute value whose look-alikes
# hold its quote is quoted with the other one (effectmon.lic writes
# label='Thurfel(U+2019)s Ward' so the single-quoted label ends where it
# should). A look-alike can add a quote, < or >, which next to a tag a
# script got wrong (a stray quote) could end that tag elsewhere: a line
# whose look-alikes don't read as the same tags as the line with
# {REPLACEMENT} for every such character gets {REPLACEMENT} throughout,
# which means nothing in markup.
module ServerText
  # A character outside ASCII.
  NON_ASCII = /[^\x00-\x7F]/

  # What a character outside ASCII without a look-alike becomes.
  REPLACEMENT = '?'

  # ASCII look-alikes, by code point, as they stand in text.
  ASCII_IN_TEXT = {
    0x00A0 => ' ', # no-break space
    0x2010 => '-', 0x2011 => '-', 0x2012 => '-', 0x2013 => '-', 0x2014 => '-', 0x2015 => '-', 0x2212 => '-',
    0x2018 => "'", 0x2019 => "'", 0x201A => "'", 0x201B => "'", 0x2032 => "'",
    0x201C => '"', 0x201D => '"', 0x201E => '"', 0x201F => '"', 0x2033 => '"',
    0x2026 => '...',
    0x2190 => '<-', 0x2192 => '->'
  }.freeze

  # The same as they stand in an attribute value, which can't hold a <.
  ASCII_IN_ATTRIBUTE = ASCII_IN_TEXT.merge(0x2190 => REPLACEMENT).freeze

  # The box-drawing block: lines become - | = and every corner, tee or
  # cross becomes +.
  BOX_DRAWING = (0x2500..0x257F)

  # Box-drawing characters drawn as a horizontal line.
  BOX_HORIZONTAL = [0x2500, 0x2501, 0x2504, 0x2505, 0x2508, 0x2509, 0x254C, 0x254D,
                    0x2574, 0x2576, 0x2578, 0x257A, 0x257C, 0x257E].freeze

  # Box-drawing characters drawn as a vertical line.
  BOX_VERTICAL = [0x2502, 0x2503, 0x2506, 0x2507, 0x250A, 0x250B, 0x254E, 0x254F, 0x2551,
                  0x2575, 0x2577, 0x2579, 0x257B, 0x257D, 0x257F].freeze

  # The double horizontal line, as in a script's banner.
  BOX_DOUBLE_HORIZONTAL = 0x2550

  # Make a line read from the game connection ASCII, in place (see
  # {ServerText}): tag it UTF-8 (socket reads are BINARY), put
  # {REPLACEMENT} in place of each invalid byte, delete NUL bytes, and put
  # a look-alike or {REPLACEMENT} in place of each character outside ASCII.
  #
  # @param line [String] raw bytes read from the server
  # @return [String] +line+, now ASCII-only and tagged UTF-8
  def self.normalize!(line)
    line.force_encoding(Encoding::UTF_8)
    # Before delete!, which raises on invalid UTF-8.
    line.scrub!(REPLACEMENT) unless line.valid_encoding?
    line.delete!("\0") if line.include?("\0")
    return line if line.ascii_only?

    plain = line.gsub(NON_ASCII, REPLACEMENT)
    segments = XmlTokenizer.tokenize(line, paired: false).map { |type, segment| [type, ascii(type, segment)] }
    alike = segments.map(&:last).join
    line.replace(same_markup?(alike, segments, plain) ? alike : plain)
  end

  # Whether the line with its look-alikes reads as the same tags as the
  # line with {REPLACEMENT} for every character outside ASCII: tag for tag
  # and text for text where they were ({LineFilter}), and with the same
  # whole paired elements ({TagHandlers}).
  #
  # @param alike [String] the line with its look-alikes
  # @param segments [Array<Array(Symbol, String)>] the segments +alike+ was
  #   joined from
  # @param plain [String] the line with {REPLACEMENT}
  # @return [Boolean]
  def self.same_markup?(alike, segments, plain)
    return false unless XmlTokenizer.tokenize(alike, paired: false) == segments

    paired = lambda do |line|
      XmlTokenizer.tokenize(line).map { |type, segment| type == :text ? :text : [segment[%r{\A</?\w*}], XmlTokenizer.attrs(segment).keys] }
    end
    paired.call(alike) == paired.call(plain)
  end
  private_class_method :same_markup?

  # A segment of the line ({XmlTokenizer.tokenize}), in ASCII.
  #
  # @param type [Symbol] +:text+ or +:tag+
  # @param segment [String] the segment
  # @return [String] the segment, ASCII-only
  def self.ascii(type, segment)
    return segment if segment.ascii_only?
    return segment.gsub(NON_ASCII) { |char| look_alike(char, ASCII_IN_TEXT) } if type == :text

    ascii_tag(segment)
  end
  private_class_method :ascii

  # A tag in ASCII: each attribute value, read as {XmlTokenizer.attrs}
  # reads them, gets its look-alikes and the quote that still holds it;
  # any other character outside ASCII in the tag becomes {REPLACEMENT}.
  #
  # @param tag [String] the tag
  # @return [String] the tag, ASCII-only
  def self.ascii_tag(tag)
    scanner = StringScanner.new(tag)
    ascii = +''
    if scanner.scan(/<\w+/)
      ascii << scanner.matched
      ascii << ascii_attribute(scanner) while scanner.scan(XmlTokenizer::ATTRIBUTE)
    end
    ascii << scanner.rest
    ascii.gsub(NON_ASCII, REPLACEMENT)
  end
  private_class_method :ascii_tag

  # The attribute +scanner+ just matched ({XmlTokenizer::ATTRIBUTE}), in
  # ASCII, quoted so the value still ends where it did.
  #
  # @param scanner [StringScanner] positioned just after the attribute
  # @return [String] the attribute: its leading space, name, = and value
  def self.ascii_attribute(scanner)
    matched = scanner.matched
    name = matched[0..matched.index('=')]
    quote, value = scanner[2] ? ['"', scanner[2]] : ["'", scanner[3]]
    value = value.gsub(NON_ASCII) { |char| look_alike(char, ASCII_IN_ATTRIBUTE) }
    other = quote == '"' ? "'" : '"'
    if value.include?(quote)
      quote, other = other, quote unless value.include?(other)
      value = value.tr(quote, other)
    end
    "#{name}#{quote}#{value}#{quote}"
  end
  private_class_method :ascii_attribute

  # The ASCII look-alike of one character outside ASCII, or {REPLACEMENT}.
  #
  # @param char [String] the character
  # @param table [Hash{Integer => String}] {ASCII_IN_TEXT} or
  #   {ASCII_IN_ATTRIBUTE}
  # @return [String] ASCII
  def self.look_alike(char, table)
    code = char.ord
    table.fetch(code) do
      next REPLACEMENT unless BOX_DRAWING.cover?(code)
      next '=' if code == BOX_DOUBLE_HORIZONTAL
      next '-' if BOX_HORIZONTAL.include?(code)
      next '|' if BOX_VERTICAL.include?(code)

      '+'
    end
  end
  private_class_method :look_alike
end
