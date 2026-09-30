# frozen_string_literal: true

require_relative 'xml_tokenizer'

# Shared link tag parsing for <d> (DR) and <a> (GS) clickable elements.
#
# Extracts a link's command from its tag's attributes, for the tag
# parser's link spans and room marks (TagHandlers#handle_open_link), and
# holds the link color the windows fall back to.
#
# Three command formats are supported:
#   DR: <d cmd='go door'>the door</d>      => cmd = "go door" (cmd="..." also accepted)
#   GS: <a exist="12345" noun="sword">...</a> => cmd = "look #12345"
#   GS (no noun): <a exist="12345">...</a>    => cmd = "_drag #12345"
# A link with none of them (<d>north</d>) sends its text, which the tag
# parser fills in when the link closes.
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
end
