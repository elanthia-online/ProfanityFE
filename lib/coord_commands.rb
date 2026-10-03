# frozen_string_literal: true

# The game's own command for each GemStone coord link, from the command
# table the server can send.
#
# A GemStone link may carry a +coord+ (<a exist="-1" coord="2524,1864"
# noun="north">north</a>): the command it stands for is the one the
# server's command table gives that coord. The table arrives as
#
#   <cmdlist><cli coord="2524,1864" menu="go @" command="go @" menu_cat="4"/>...</cmdlist>
#
# possibly over several lines. In a command, +@+ stands for the link's
# noun, +#+ for +#+ and the link's exist, and +%+ for the bare exist; a
# command with both +#+ and +%+ is unusable. The table's form and these
# rules come from a third-party front-end's parser (Saga 6c2079e, which
# asks the server for the table with "_menu update <timestamp>" when the
# server sends <updateverbs/>); no GemStone log has a table, so the
# server never sent one on those Lich connections. ProfanityFE sends no
# request and ships no table of its own: a coord with no entry has no
# command.
#
# A table is kept only once its </cmdlist> arrives; a prompt before that
# discards it. A later table adds to the first, its command winning for
# the same coord.
#
# @example
#   commands = CoordCommands.new
#   commands.start
#   commands.add(coord: '2524,1864', command: 'go @')
#   commands.finish
#   commands.command_for('2524,1864', exist: '-11223064', noun: 'north') #=> "go north"
#   commands.command_for('2524,1753', exist: '-11165808', noun: '')      #=> nil
class CoordCommands
  # Start with an empty table and no table being read.
  def initialize
    @table = {}
    @pending = nil
  end

  # Start reading a table (a <cmdlist> start tag).
  #
  # @return [void]
  def start
    @pending = {}
  end

  # Whether a table is being read: its <cmdlist> arrived, its </cmdlist>
  # hasn't.
  #
  # @return [Boolean]
  def reading?
    !@pending.nil?
  end

  # Add one entry (a <cli>) to the table being read. Ignored when no table
  # is being read, or when the coord or the command is missing or empty.
  #
  # @param coord [String, nil] the entry's +coord+ attribute
  # @param command [String, nil] the entry's +command+ attribute, as sent
  # @return [void]
  def add(coord:, command:)
    return unless @pending && present?(coord) && present?(command)

    @pending[coord] = command
  end

  # Keep the table being read (its </cmdlist> arrived), adding it to the
  # table already kept.
  #
  # @return [void]
  def finish
    @table.merge!(@pending) if @pending
    @pending = nil
  end

  # Discard the table being read (a prompt arrived before its </cmdlist>).
  #
  # @return [void]
  def discard
    @pending = nil
  end

  # The command for a coord link: its coord's command with the link's
  # noun and exist put in.
  #
  # Runs of whitespace become one space and the ends are trimmed, so an
  # empty noun leaves no space behind.
  #
  # @param coord [String] the link's +coord+ attribute
  # @param exist [String, nil] the link's +exist+ attribute
  # @param noun [String, nil] the link's +noun+ attribute
  # @return [String, nil] the command, or nil when the table has none for
  #   the coord, the command has both +#+ and +%+, or it comes out empty
  def command_for(coord, exist:, noun:)
    template = @table[coord]
    return unless template && !(template.include?('#') && template.include?('%'))

    command = template.gsub('#', "##{exist}").gsub('%', exist.to_s).gsub('@', noun.to_s)
    command = command.gsub(/\s+/, ' ').strip
    command unless command.empty?
  end

  private

  # @param value [String, nil]
  # @return [Boolean] whether +value+ is a non-empty string
  def present?(value)
    !value.nil? && !value.empty?
  end
end
