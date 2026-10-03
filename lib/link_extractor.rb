# frozen_string_literal: true

require_relative 'xml_tokenizer'
require_relative 'coord_commands'

# Shared link tag parsing for <d> (DR) and <a> (GS) clickable elements.
#
# Extracts a link's command from its tag's attributes, for the tag
# parser's link spans and room marks (TagHandlers#handle_open_link), and
# holds the link color the windows fall back to.
#
# The command, in order of precedence:
#   DR: <d cmd='go door'>the door</d>      => cmd = "go door" (cmd="..." also accepted)
#   GS: <a exist="-1" coord="2524,1864" noun="north">north</a>
#                                          => the game's command for the coord
#                                             (see CoordCommands), or false: no command
#   GS: <a exist="12345" noun="sword">...</a> => cmd = "look #12345"
#   GS (no noun): <a exist="12345">...</a>    => cmd = "_drag #12345"
# A link with none of them (<d>north</d>) sends its text, which the tag
# parser fills in when the link closes. A coord link without a command
# is not a link: false keeps the tag parser from giving it its text.
module LinkExtractor
  # Default link color [fg, bg] when no 'links' preset is defined.
  DEFAULT_LINK_COLOR = ['5555ff', nil].freeze

  # An empty command table: every coord link has no command.
  NO_COORD_COMMANDS = CoordCommands.new.freeze

  module_function

  # Extract a link command from an opening <d> or <a> tag's attributes.
  #
  # @param xml [String] the full opening tag (e.g. "<d cmd='go door'>")
  # @param coord_commands [CoordCommands] the game's commands for coord
  #   links (the server's command table; empty when none arrived)
  # @return [String, false, nil] the command string; false for a coord
  #   link the table has no command for; nil if no cmd, coord or exist
  #   attribute
  def extract_cmd(xml, coord_commands: NO_COORD_COMMANDS)
    # Most DR links quote cmd with single quotes; some (e.g. FLAG output) use
    # double quotes. An empty attribute counts as absent.
    attrs = XmlTokenizer.attrs(xml).reject { |_, value| value.empty? }
    if (cmd = attrs['cmd'])
      cmd
    elsif (coord = attrs['coord'])
      coord_commands.command_for(coord, exist: attrs['exist'], noun: attrs['noun']) || false
    elsif (exist = attrs['exist'])
      attrs['noun'] ? "look ##{exist}" : "_drag ##{exist}"
    end
  end
end
