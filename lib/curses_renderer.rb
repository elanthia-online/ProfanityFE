# frozen_string_literal: true

require 'monitor'

# Thread-safe rendering coordinator for curses screen updates.
#
# ncurses is not thread-safe — concurrent calls to +noutrefresh+ and
# +doupdate+ from different threads can corrupt internal data structures
# and cause visible flickering (especially on terminals with higher
# rendering latency such as MobaXterm or SSH sessions).
#
# This module serializes all screen-flush operations through a reentrant
# +Monitor+ so that timer threads, the server read thread, and the input
# loop never call +doupdate+ concurrently.  Using +Monitor+ (rather than
# +Mutex+) allows safe nesting when a synchronized block calls another
# method that also synchronizes.
#
# @example Flush the virtual screen to the terminal
#   CursesRenderer.doupdate
#
# @example Atomically update a window and flush
#   CursesRenderer.render do
#     window.update
#     cmd_buffer.window&.noutrefresh
#   end
#
# @example Serialize non-curses terminal output (e.g. OSC title sequences)
#   CursesRenderer.synchronize do
#     $stdout.print "\033]0;#{title}\007"
#     $stdout.flush
#   end
module CursesRenderer
  @monitor = Monitor.new

  # Fiber-local key for the blocks {.outside_lock} deferred on this thread.
  DEFERRED_KEY = :curses_renderer_deferred

  module_function

  # Serialize a block of curses (or terminal I/O) operations.
  #
  # Use when performing multiple curses calls that must not be
  # interleaved with calls from other threads — for example, writing
  # escape sequences directly to +$stdout+.
  #
  # @yield block of operations to serialize
  # @return [Object] the block's return value
  def synchronize(&block)
    hold(&block)
  end

  # Flush the virtual screen to the physical terminal, synchronized.
  #
  # Drop-in replacement for +Curses.doupdate+ that prevents concurrent
  # flushes from different threads.
  #
  # @return [void]
  def doupdate
    hold { Curses.doupdate }
  end

  # Execute rendering operations and flush to screen atomically.
  #
  # Wraps the block and a +Curses.doupdate+ call in a single +Monitor+
  # acquisition so that no other thread can flush a partial update.
  #
  # @yield block that performs +noutrefresh+ calls on one or more windows
  # @return [void]
  def render
    hold do
      yield
      Curses.doupdate
    end
  end

  # Run a block that may block (such as a write to the game server socket)
  # without holding the lock.
  #
  # Runs it now if this thread does not hold the lock. Otherwise it runs
  # just after this thread's outermost {.synchronize}, {.render} or
  # {.doupdate} releases the lock, in the order deferred. A write that
  # blocks then stalls only its own thread, not every thread that draws.
  #
  # @yield the operation to run outside the lock
  # @return [Object, nil] the block's return value if run now, else nil
  def outside_lock(&block)
    return yield unless @monitor.mon_owned?

    (Thread.current[DEFERRED_KEY] ||= []) << block
    nil
  end

  # Hold the lock for the block, then run the blocks {.outside_lock}
  # deferred once this thread no longer holds it.
  #
  # @yield the operations to run while holding the lock
  # @return [Object] the block's return value
  def hold(&block)
    @monitor.synchronize(&block)
  ensure
    run_deferred unless @monitor.mon_owned?
  end

  # Run, in the order they were deferred, the blocks {.outside_lock}
  # deferred on this thread, and forget them. Called by {.hold} once the
  # thread no longer holds the lock. A block that raises stops the rest,
  # which are dropped.
  #
  # @return [void]
  def run_deferred
    return unless (deferred = Thread.current[DEFERRED_KEY])

    Thread.current[DEFERRED_KEY] = nil
    deferred.each(&:call)
  end
  private_class_method :hold, :run_deferred
end
