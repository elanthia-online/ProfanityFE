# frozen_string_literal: true

RoomTitle = Data.define(:name, :suffix)

# A room's title, parsed from any of the ways the game sends it: the
# subtitle of the room streamWindow, pushStream or component, the text of a
# roomName style, and the text of the +room title+ component or +room+
# stream. The room window's title row shows {#to_s} and the terminal title
# {#plain}, both from the same parse, so they always name the same room.
#
# The title is parsed into the room's name and what follows it. The name
# is the text inside the first pair of brackets when the title starts with
# one (+"[Town Square] (1234)"+); what follows the closing bracket is kept
# as the game sends it (+" (1234)"+, DragonRealms' +" (**)"+ for a room
# with no number, Lich's +" (u230008)"+). A title without brackets is all
# name, except a trailing room number: +"Town Square (1234)"+.
#
# @example
#   RoomTitle.parse(' - [The Heavens] (**)').to_s #=> "[The Heavens] (**)"
#   RoomTitle.parse('Town Square (1234)').to_s    #=> "[Town Square] (1234)"
#   RoomTitle.parse('[] (1234)')                  #=> nil
#
# @!attribute [r] name
#   @return [String] the room's name, without the brackets around it or
#     the whitespace just inside them (+"[ Town Square ]"+ names
#     +"Town Square"+)
# @!attribute [r] suffix
#   @return [String] what follows the name's closing bracket, as sent,
#     with the whitespace right after the bracket shortened to one space
#     (+" (1234)"+, +"]"+ or +""+)
class RoomTitle
  # A title that starts with a bracketed name: the name, and the rest.
  BRACKETED = /\A\[(?<name>[^\]]*)\](?<rest>.*)\z/m

  # A title without a bracketed name that ends in a room number.
  NUMBERED = /\A(?<name>.+?)(?<rest>\s+\(\d+\))\z/m

  # Parse a room title as the game sends it, XML entities already decoded.
  # Whitespace around the title and a leading +"-"+ (a subtitle's
  # +" - [Town Square]"+) are dropped first.
  #
  # @param text [String] the title
  # @return [RoomTitle, nil] nil when the name is empty or blank, which is
  #   no title (+"[]"+, +"[] (1234)"+, +""+)
  def self.parse(text)
    title = text.strip.sub(/\A-\s*/, '')
    match = BRACKETED.match(title) || NUMBERED.match(title)
    name = (match ? match[:name] : title).strip
    rest = match ? match[:rest] : ''
    suffix = rest.lstrip
    suffix = " #{suffix}" unless suffix.empty? || suffix.length == rest.length
    new(name: name, suffix: suffix) unless name.empty?
  end

  # The title row's text for a title as the game sends it (see {.parse}),
  # or an empty string when it is no title.
  #
  # @param text [String] the title, XML entities already decoded
  # @return [String] +"[name]suffix"+, or +""+
  def self.text(text)
    parse(text).to_s
  end

  # The title as the room window's title row shows it: the name in
  # brackets, then the suffix.
  #
  # @return [String]
  def to_s
    "[#{name}]#{suffix}"
  end

  # The title as the terminal title and the room indicator name the room:
  # the title row's text without the brackets around the name
  # (+"Town Square (1234)"+), since the terminal title already puts the
  # room inside brackets (+"Mahtra [Town Square (1234)]"+).
  #
  # @return [String]
  def plain
    "#{name}#{suffix}"
  end
end
