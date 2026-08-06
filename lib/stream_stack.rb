# frozen_string_literal: true

# Tracks streams suspended by stream nesting in the game protocol.
#
# GemStone and DragonRealms wrap side-channel output in
# +<pushStream id="..."/>+ ... +<popStream/>+ pairs, and those pairs nest:
# a room component can open while a speech stream is active, and an
# asynchronous script (for example moonwatch repainting the +moonWindow+
# side stream) can inject its own push/pop between a game stream's open and
# close. The frontend routes output to a single *active* stream, but on
# +popStream+ it must restore the *enclosing* stream rather than always
# falling back to the main window. A scalar "current stream" cannot express
# that nesting, so a +popStream+ closing an inner stream resets routing to
# the main window and the enclosing stream's remaining text leaks there (or,
# symmetrically, a stray inner pop leaves the outer window "stuck" with
# content that was meant for another window).
#
# StreamStack is the stack of enclosing streams that have been *suspended*
# while a nested stream is active. The caller owns the active stream itself:
# on open it {#push}es the stream being suspended, and on close it {#pop}s to
# recover the stream to resume. A +nil+ entry represents the main window (no
# active stream), so a stream opened directly from the main window restores
# correctly to the main window when it closes.
#
# @example Restore the enclosing stream on close
#   stack   = StreamStack.new
#   current = 'thoughts'   # the active stream
#   stack.push(current)    # a nested stream opens, suspending 'thoughts'...
#   current = 'moonWindow' # ...and 'moonWindow' becomes active
#   current = stack.pop    # the nested stream closes -> resume 'thoughts'
#   #=> 'thoughts' (not nil)
#
# @example An unmatched pop is safe
#   StreamStack.new.pop #=> nil (the main window)
class StreamStack
  # Create an empty stack with no suspended streams.
  #
  # @return [StreamStack]
  def initialize
    @suspended = []
  end

  # Suspend a stream because a nested stream is opening.
  #
  # @param stream [String, nil] the stream being suspended; +nil+ denotes the
  #   main window (i.e. a stream opened while no other stream was active)
  # @return [String, nil] the stream just suspended (the argument), for chaining
  def push(stream)
    @suspended.push(stream)
    stream
  end

  # Resume the most recently suspended stream.
  #
  # Popping an empty stack yields +nil+ (the main window) rather than raising,
  # so an unmatched +popStream+ can never crash the parser.
  #
  # @return [String, nil] the stream to resume, or +nil+ for the main window
  def pop
    @suspended.pop
  end

  # Peek at the stream that would be resumed next, without removing it.
  #
  # @return [String, nil] the top suspended stream, or +nil+ if none are suspended
  def peek
    @suspended.last
  end

  # @return [Integer] the number of currently suspended streams (nesting depth)
  def depth
    @suspended.length
  end

  # @return [Boolean] whether any streams are suspended
  def empty?
    @suspended.empty?
  end

  # Discard every suspended stream, e.g. on a hard routing reset.
  #
  # @return [void]
  def reset
    @suspended.clear
  end
end
