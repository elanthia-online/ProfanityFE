# frozen_string_literal: true

# kill_ring.rb: Readline-style kill ring (cut/paste buffer) for ProfanityFE.

# Readline-style kill ring for cut/paste operations.
#
# Consecutive kill commands accumulate text into one kill buffer; any
# other editing command ends the kill sequence, so the next kill starts
# a fresh buffer. Call {#before} at the start of a kill, mutate
# {#buffer}, then call {#after}. Non-kill commands call {#end_sequence}.
#
# Whether a kill continues the sequence depends only on what the
# previous command was, not on the buffer contents: moving the cursor
# away and back, or typing and deleting a character, still ends it.
#
# @example
#   ring = KillRing.new
#   ring.before("hello world")
#   ring.buffer += " world"  # kill forward
#   ring.after
#   ring.buffer  # => " world"
class KillRing
  # @return [String] accumulated killed text for yanking
  attr_accessor :buffer

  # The full original text captured at the start of the current kill sequence.
  # Used by kill_line to restore the entire line on yank.
  #
  # @return [String] original text before any kills in this sequence
  attr_reader :original

  # Create a new kill ring with empty buffers.
  #
  # @return [KillRing]
  def initialize
    @buffer = ''
    @original = ''
    @killing = false
  end

  # Call before a kill operation. Starts a new kill buffer, capturing
  # the current text as {#original}, unless the previous command was
  # also a kill.
  #
  # @param current_text [String] current command buffer text
  # @return [void]
  def before(current_text)
    return if @killing

    @buffer = ''
    @original = current_text.dup
  end

  # Call after a kill operation. Marks the kill sequence as ongoing so
  # the next {#before} appends to the same buffer.
  #
  # @return [void]
  def after
    @killing = true
  end

  # End the current kill sequence. Call for every non-kill command
  # (insert, delete, movement, yank, history, send). The buffer is kept
  # for yanking; only the next kill starts a new one.
  #
  # @return [void]
  def end_sequence
    @killing = false
  end
end
