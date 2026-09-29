# frozen_string_literal: true

# The command lines that were sent, newest first.
#
# This is what the resend keys (+send_last_command+,
# +send_second_last_command+) and autocomplete read. Only lines that were
# sent are recorded: an edit left in a recalled entry and a line saved by
# the down arrow belong to the command line's browsing state
# ({CommandBuffer}), never to this list.
#
# A line shorter than +min_length+ is not recorded unless it is all
# digits, a line identical to the newest one is not recorded again, and
# only the newest +CONFIG.history_size+ lines are kept. The size is read
# on every {#add}, so a settings reload applies with the next line sent.
#
# @example
#   sent = CommandHistory.new
#   sent.add('look')
#   sent.add('north')
#   sent.recent(1) #=> "north"
#   sent.to_a      #=> ["north", "look"]
class CommandHistory
  # @return [Integer] minimum length of a line that is recorded (all-digit
  #   lines are always recorded)
  attr_accessor :min_length

  # Create an empty history.
  #
  # @param min_length [Integer] lines shorter than this are not recorded,
  #   unless they are all digits
  # @return [CommandHistory]
  def initialize(min_length: 4)
    @lines = []
    @min_length = min_length
  end

  # Whether a line is long enough to be recorded: at least +min_length+
  # characters, or all digits.
  #
  # @param line [String] a command line
  # @return [Boolean]
  def keeps?(line)
    line.length >= @min_length || line.match?(/^\d+$/)
  end

  # Record a line that was sent. Skips a line {#keeps?} rejects and a line
  # identical to the newest one (an older identical line is kept), then
  # drops the oldest lines beyond +CONFIG.history_size+.
  #
  # @param line [String] the line sent
  # @return [void]
  def add(line)
    return unless keeps?(line)

    @lines.unshift(line.dup.freeze) unless line == @lines.first
    excess = @lines.length - CONFIG.history_size
    @lines.pop(excess) if excess.positive?
  end

  # The +n+th most recent line sent.
  #
  # @param n [Integer] 1 = the last line sent, 2 = the one before it
  # @return [String, nil] the frozen line, or nil when fewer than +n+ lines
  #   were recorded or +n+ is below 1
  def recent(n)
    @lines[n - 1] if n.positive?
  end

  # The lines sent, newest first.
  #
  # @return [Array<String>] a frozen copy (the lines are frozen too)
  def to_a
    @lines.dup.freeze
  end
end
