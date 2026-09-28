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

  # Matches either a paired tag (with content) for one of {PAIRED_TAGS},
  # or any single XML tag.
  #
  # A single tag ends at the first > outside a quoted attribute value, so
  # <d cmd="look >here"> is one tag. A quoted value can't hold a raw <
  # (XML forbids it), which keeps a stray quote from running into the next
  # tag. A tag with an unbalanced quote falls back to ending at the first >.
  #
  # Paired: <prompt time='123'>H&gt;</prompt>, <spell>Fire Ball</spell>
  # Single: <pushBold/>, <preset id='x'>, </color>, <progressBar .../>
  TAG_REGEX = %r{(?:<(#{PAIRED_TAGS.join('|')})\b.*?</\1>|<(?:[^<>"']|"[^"<]*"|'[^'<]*')*>|<[^>]*>)}

  # One attribute of a start tag: whitespace, a name, +=+, then a value in
  # double or single quotes. The value runs to the next matching quote, so
  # it may hold the other quote and +>+. No whitespace around +=+, and no
  # unquoted values.
  ATTRIBUTE = /\s+([\w.:-]+)=(?:"([^"]*)"|'([^']*)')/

  # Tokenize a line into ordered [:text, str] and [:tag, str] segments.
  #
  # @param line [String] raw game server line (tags + text)
  # @return [Array<Array(Symbol, String)>] ordered segments
  def self.tokenize(line)
    segments = []
    pos = 0

    while pos < line.length
      m = TAG_REGEX.match(line, pos)
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
