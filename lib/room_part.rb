# frozen_string_literal: true

RoomPart = Data.define(:text, :links, :creatures)

# One part of a room as the room window shows it (its description,
# objects, players or exits): the text, the links in it and the creatures
# it names.
#
# A part is built from a chunk of parsed game text and the room marks the
# tag parser recorded for it (see SpanTracker::ROOM_MARKS), whichever way
# the room arrived: a room component's text, an inline room line, or a
# line Lich adds. The marks are where the game's links and bold text are,
# so a creature is the text of a bold span, whatever color bold is drawn
# in, and nested links are paired as they nest.
#
# @example
#   marks = [{ start: 13, mark: :bold, end: 18 }, { start: 23, mark: :link, cmd: 'look box', end: 28 }]
#   part = RoomPart.from_chunk('You also see a rat and a box.', marks)
#   part.creatures #=> ["a rat"]
#   part.links     #=> [{ start: 23, end: 28, cmd: "look box" }]
#
# @!attribute [r] text
#   @return [String] the part's text, surrounding whitespace removed
# @!attribute [r] links
#   @return [Array<Hash>] `{start:, end:, cmd:}` for each link with a
#     command, positions in {#text}, in the order the links closed
# @!attribute [r] creatures
#   @return [Array<String>] the text of each bold span, stripped: each
#     once, in the order the spans closed, empty ones left out
class RoomPart
  # Build a part from the text after +from+ in a chunk of parsed text.
  #
  # The part's text is that text with surrounding whitespace removed; the
  # marks that start at or after +from+ are moved to match it.
  #
  # @param text [String] the chunk: game text, tags removed and entities
  #   decoded
  # @param marks [Array<Hash>] the room marks for +text+
  # @param from [Integer] where the part starts in +text+ (a description
  #   that starts in the middle of the chunk)
  # @return [RoomPart]
  def self.from_chunk(text, marks, from: 0)
    tail = text[from..] || ''
    body = tail.strip
    shift = from + tail.length - tail.lstrip.length
    marks = marks.select { |mark| mark[:start] >= from }
    links = marks.select { |mark| mark[:mark] == :link && mark[:cmd] }
                 .map { |mark| { start: mark[:start] - shift, end: mark[:end] - shift, cmd: mark[:cmd] } }
    creatures = marks.select { |mark| mark[:mark] == :bold }
                     .filter_map { |mark| body[(mark[:start] - shift)...(mark[:end] - shift)]&.strip }
                     .reject(&:empty?)
                     .uniq
    new(text: body, links: links, creatures: creatures)
  end
end
