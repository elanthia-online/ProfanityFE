# frozen_string_literal: true

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
  # Matches either a paired tag (with content) for specific self-contained
  # elements, or any single XML tag.
  #
  # Paired: <prompt time='123'>H&gt;</prompt>, <spell>Fire Ball</spell>
  # Single: <pushBold/>, <preset id='x'>, </color>, <progressBar .../>
  TAG_REGEX = /(?:<(prompt|spell|right|left|inv|compass)\b.*?<\/\1>|<[^>]*>)/

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
