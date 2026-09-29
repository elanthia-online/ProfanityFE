# frozen_string_literal: true

require 'strscan'

# Tokenizes game server lines into text and XML tag segments.
#
# The game protocol interleaves plain text with XML-like markup tags.
# This tokenizer splits a line into an ordered list of [:text, str]
# and [:tag, str] segments for dispatch-based processing, replacing
# the mutating regex-and-slice loop in the original GameTextProcessor.
#
# @example
#   XmlTokenizer.tokenize("Hello <pushBold/>world<popBold/>!")
#   # => [[:text, "Hello "], [:tag, "<pushBold/>"], [:text, "world"],
#   #     [:tag, "<popBold/>"], [:text, "!"]]
module XmlTokenizer
  # Elements the tokenizer keeps whole with their content, up to the matching
  # close tag: <prompt time='1'>H&gt;</prompt> is one segment, so its handler
  # sees the text. Every other tag is its own segment.
  #
  # The paired handlers in {TagHandlers::TAG_DISPATCH} (prompt, spell, right,
  # left, compass) rely on this list. +inv+ is paired only so its content
  # never reaches a window; it has no handler.
  PAIRED_TAGS = %w[prompt spell right left inv compass].freeze

  # Matches any single XML tag, without content.
  #
  # A single tag ends at the first > outside a quoted attribute value, so
  # <d cmd="look >here"> is one tag. A quoted value can't hold a raw <
  # (XML forbids it), which keeps a stray quote from running into the next
  # tag. A tag with an unbalanced quote falls back to ending at the first >.
  #
  # Single: <pushBold/>, <preset id='x'>, </color>, <progressBar .../>
  SINGLE_TAG_REGEX = %r{<(?:[^<>"']|"[^"<]*"|'[^'<]*')*>|<[^>]*>}

  # Matches either a paired tag (with content) for one of {PAIRED_TAGS},
  # or any single XML tag (see {SINGLE_TAG_REGEX}).
  #
  # Paired: <prompt time='123'>H&gt;</prompt>, <spell>Fire Ball</spell>
  TAG_REGEX = %r{(?:<(#{PAIRED_TAGS.join('|')})\b.*?</\1>|#{SINGLE_TAG_REGEX.source})}

  # One attribute of a start tag: whitespace, a name, +=+, then a value in
  # double or single quotes. The value runs to the next matching quote, so
  # it may hold the other quote and +>+. No whitespace around +=+, and no
  # unquoted values.
  ATTRIBUTE = /\s+([\w.:-]+)=(?:"([^"]*)"|'([^']*)')/

  # A tag at the start of a string, read as {SINGLE_TAG_REGEX} reads one.
  LEADING_TAG = /\A(?:#{SINGLE_TAG_REGEX.source})/

  # Tokenize a line into ordered [:text, str] and [:tag, str] segments.
  #
  # The segments joined give back the line.
  #
  # @example Paired tags split into their tags and content
  #   XmlTokenizer.tokenize('<spell>Fire</spell>', paired: false)
  #   # => [[:tag, "<spell>"], [:text, "Fire"], [:tag, "</spell>"]]
  #
  # @param line [String] raw game server line (tags + text)
  # @param paired [Boolean] keep each of {PAIRED_TAGS} whole with its
  #   content, as the tag dispatcher reads a line; false splits them like
  #   any other tag
  # @return [Array<Array(Symbol, String)>] ordered segments
  def self.tokenize(line, paired: true)
    regex = paired ? TAG_REGEX : SINGLE_TAG_REGEX
    segments = []
    pos = 0

    while pos < line.length
      m = regex.match(line, pos)
      break unless m

      # Text before the tag
      segments << [:text, line[pos...m.begin(0)]] if m.begin(0) > pos
      segments << [:tag, m[0]]
      pos = m.end(0)
    end

    # Remaining text after last tag
    segments << [:text, line[pos..]] if pos < line.length
    segments
  end

  # Read the attributes of a tag's start tag.
  #
  # Attributes are read in order from just after the element name, and
  # reading stops at the first thing that isn't an attribute (the closing
  # +>+ or +/>+, or anything malformed). So only the start tag of a paired
  # segment is read, never its content, and an attribute name must match
  # exactly: +pid='x'+ is not +id+. The first of two same-named attributes
  # wins. Values are returned as sent: entities are not decoded.
  #
  # @example
  #   XmlTokenizer.attrs(%q{<d cmd='look >here' noun="x">})
  #   # => {"cmd"=>"look >here", "noun"=>"x"}
  #   XmlTokenizer.attrs("<prompt time='1'>H&gt;</prompt>") # => {"time"=>"1"}
  #   XmlTokenizer.attrs('</preset>')                       # => {}
  #
  # @param tag [String] a tag, as a segment from {.tokenize}
  # @return [Hash{String => String}] attribute values by name, in tag order
  def self.attrs(tag)
    scanner = StringScanner.new(tag)
    return {} unless scanner.skip(/<\w+/)

    attributes = {}
    while scanner.scan(ATTRIBUTE)
      attributes[scanner[1]] = scanner[2] || scanner[3] unless attributes.key?(scanner[1])
    end
    attributes
  end

  # The content of a paired segment: the text between its start tag and
  # its end tag.
  #
  # The start tag ends where {SINGLE_TAG_REGEX} ends it, at the first >
  # outside a quoted value, so a > inside an attribute value is not
  # content. The content runs to the first end tag of the same name, as
  # {TAG_REGEX} pairs them: elements don't nest. It is returned as sent,
  # tags and entities included.
  #
  # @example
  #   XmlTokenizer.content(%q{<right noun="a>b">sword</right>}) # => "sword"
  #   XmlTokenizer.content('<spell></spell>')                    # => ""
  #   XmlTokenizer.content('<left>sword')                        # => nil
  #
  # @param xml [String] a paired segment from {.tokenize}
  # @return [String, nil] the content, or nil when +xml+ doesn't start with
  #   a start tag (an end tag, a self-closing tag, or no tag), or has no end
  #   tag for it
  def self.content(xml)
    return unless (name = xml[/\A<(\w+)(?=[\s>])/, 1])
    return unless (start = LEADING_TAG.match(xml)) && !start[0].end_with?('/>')
    return unless (finish = xml.index("</#{name}>", start.end(0)))

    xml[start.end(0)...finish]
  end

  # The tags of a line, in order: the tag segments of {.tokenize}.
  #
  # @example
  #   XmlTokenizer.tags("a <pushBold/>b<popBold/>") # => ["<pushBold/>", "<popBold/>"]
  #
  # @param line [String] raw game server line (tags + text)
  # @param paired [Boolean] as for {.tokenize}
  # @return [Array<String>] the tags
  def self.tags(line, paired: true)
    tokenize(line, paired: paired).filter_map { |type, segment| segment if type == :tag }
  end

  # The element name of a start tag or an empty-element tag.
  #
  # @example
  #   XmlTokenizer.start_tag_name('<popStream id="combat"/>') # => "popStream"
  #   XmlTokenizer.start_tag_name('</preset>')                # => nil
  #
  # @param tag [String] a tag, as a segment from {.tokenize}
  # @return [String, nil] the name as {.tag_name} reads it, or nil for an
  #   end tag
  def self.start_tag_name(tag)
    tag_name(tag) unless tag.start_with?('</')
  end

  # Extract the element name from an XML tag string.
  #
  # @param xml [String] full XML tag (e.g. "<pushBold/>", "</preset>")
  # @return [String] tag name (e.g. "pushBold", "preset")
  def self.tag_name(xml)
    if xml.start_with?('</')
      xml.match(/^<\/(\w+)/)&.send(:[], 1)
    else
      xml.match(/^<(\w+)/)&.send(:[], 1)
    end
  end
end
