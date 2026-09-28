# frozen_string_literal: true

require_relative 'xml_tokenizer'

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
  # When links_enabled is true, each link tag is replaced with its text
  # content and a color region is created with the link preset color and
  # the extracted command.
  #
  # When links_enabled is false, link tags are stripped keeping only
  # the text content (no color regions).
  #
  # Any remaining XML tags are stripped as a catch-all.
  #
  # @param text [String] text potentially containing <d>/<a> link tags
  # @param links_enabled [Boolean] whether to build clickable link regions
  # @param link_preset [Array(String, String), nil] [fg, bg] colors for links
  # @return [Array(String, Array<Hash>)] [clean_text, line_colors]
  def extract_links(text, links_enabled:, link_preset: nil)
    clean_text = text.dup
    line_colors = []

    # Pre-strip non-link XML tags (e.g. <b>, <style>, <compass>) so they
    # don't occupy character positions during link extraction. Without this,
    # link color regions are computed against a string that still contains
    # these tags, and the final catch-all strip shifts text without adjusting
    # positions — causing color regions to land on wrong characters.
    clean_text.gsub!(%r{<(?!/?[ad][\s>])[^>]+>}, '')

    if links_enabled
      preset = link_preset || PRESET['links'] || DEFAULT_LINK_COLOR
      while (m = clean_text.match(%r{<([ad])\s?([^>]*)>(.*?)</\1>}))
        tag_start = m.begin(0)
        attrs = m[2]
        link_text = m[3]

        cmd = extract_cmd("<#{m[1]} #{attrs}>") || link_text

        clean_text = clean_text[0...tag_start] + link_text + clean_text[m.end(0)..]

        line_colors.push({
          start: tag_start,
          end: tag_start + link_text.length,
          fg: preset[0],
          bg: preset[1],
          cmd: cmd
        })
      end
    else
      clean_text.gsub!(%r{<[ad]\s?[^>]*>(.*?)</[ad]>}, '\1')
    end

    # Strip any orphaned/unclosed link tags left after extraction
    clean_text.gsub!(%r{</?[ad][^>]*>}, '')

    [clean_text, line_colors]
  end
end
