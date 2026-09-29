# frozen_string_literal: true

require_relative 'xml_tokenizer'
require_relative 'presets'

# Shared link tag parsing for <d> (DR) and <a> (GS) clickable elements.
#
# Extracts link commands from XML attributes and builds color regions
# with :cmd keys for click dispatch. Used by both TagHandlers (live
# game text streaming) and RoomWindow (room panel rendering).
#
# Three command formats are supported:
#   DR: <d cmd='go door'>the door</d>      => cmd = "go door" (cmd="..." also accepted)
#   GS: <a exist="12345" noun="sword">...</a> => cmd = "look #12345"
#   GS (no noun): <a exist="12345">...</a>    => cmd = "_drag #12345"
#   Fallback: <d>north</d>                    => cmd = "north" (link text)
module LinkExtractor
  # Default link color [fg, bg] when no 'links' preset is defined.
  DEFAULT_LINK_COLOR = ['5555ff', nil].freeze

  # Element names of link tags.
  LINK_TAGS = %w[a d].freeze

  module_function

  # Extract a link command from an opening <d> or <a> tag's attributes.
  #
  # @param xml [String] the full opening tag (e.g. "<d cmd='go door'>")
  # @return [String, nil] the command string, or nil if no cmd/exist attribute
  def extract_cmd(xml)
    # Most DR links quote cmd with single quotes; some (e.g. FLAG output) use
    # double quotes. An empty attribute counts as absent.
    attrs = XmlTokenizer.attrs(xml).reject { |_, value| value.empty? }
    if (cmd = attrs['cmd'])
      cmd
    elsif (exist = attrs['exist'])
      attrs['noun'] ? "look ##{exist}" : "_drag ##{exist}"
    end
  end

  # Extract all <d>/<a> link tags from a text string, returning clean
  # text and color regions with :cmd for click dispatch.
  #
  # The text is read with {XmlTokenizer.tokenize} (paired tags split, so
  # their text is kept). Every tag is removed; the text between tags is
  # kept. A link runs from a <d> or <a> start tag to the next end tag of the
  # same element, and each end tag closes the earliest link of its element
  # still open. Link tags left unpaired are dropped, and link text never
  # includes tag text.
  #
  # When links_enabled is true, each link becomes a color region with the
  # link preset color and its command: the tag's cmd/exist attributes (see
  # {.extract_cmd}), or else the link text. Regions are in the order their
  # links open. When links_enabled is false, there are no regions.
  #
  # @param text [String] text potentially containing <d>/<a> link tags
  # @param links_enabled [Boolean] whether to build clickable link regions
  # @param link_preset [Array(String, String), nil] [fg, bg] colors for links
  # @return [Array(String, Array<Hash>)] [clean_text, line_colors]
  def extract_links(text, links_enabled:, link_preset: nil)
    clean_text = String.new(encoding: text.encoding)
    open_links = []
    links = []

    XmlTokenizer.tokenize(text, paired: false).each do |type, segment|
      if type == :text
        clean_text << segment
        next
      end
      name = XmlTokenizer.tag_name(segment)
      next unless LINK_TAGS.include?(name)

      if segment.start_with?('</')
        index = open_links.index { |open| open[:name] == name }
        next unless index

        links << open_links.delete_at(index).merge(end: clean_text.length)
      else
        open_links << { name: name, order: open_links.length + links.length, start: clean_text.length, tag: segment }
      end
    end
    return [clean_text, []] unless links_enabled

    colors = if link_preset
               { fg: link_preset[0], bg: link_preset[1] }
             else
               Presets.colors(Presets::LINKS, DEFAULT_LINK_COLOR)
             end
    line_colors = links.sort_by { |link| link[:order] }.map do |link|
      {
        start: link[:start],
        end: link[:end],
        fg: colors[:fg],
        bg: colors[:bg],
        cmd: extract_cmd(link[:tag]) || clean_text[link[:start]...link[:end]]
      }
    end
    [clean_text, line_colors]
  end
end
