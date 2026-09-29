# frozen_string_literal: true

# Startup timings recorded with --profile.
#
# Times are milliseconds on the monotonic clock since the profiler was
# created, rounded to 0.1 ms. {#mark} records a milestone for the summary
# that {#log_timings} writes; {#log_elapsed} writes one line straight away.
# A disabled profiler records and writes nothing. Lines go to
# {ProfanityLog} under +boot-profile+.
#
# profanity.rb creates the profiler and passes it to {Application}, which
# passes it to {GameTextProcessor}.
#
# @example
#   profiler = BootProfiler.new(enabled: true)
#   profiler.mark('curses init')
#   profiler.log_elapsed('first prompt (sent look)')
#   profiler.log_timings
class BootProfiler
  # Recorded milestones as [label, elapsed milliseconds] pairs, oldest first.
  #
  # @return [Array<Array(String, Float)>]
  attr_reader :timings

  # Start timing now.
  #
  # @param enabled [Boolean] record and log timings (true with --profile)
  # @param clock [#call] returns the current time in seconds; the default
  #   reads the monotonic clock
  def initialize(enabled:, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
    @enabled = enabled ? true : false
    @clock = clock
    @t0 = clock.call if @enabled
    @timings = []
  end

  # @return [Boolean] whether timings are recorded and logged
  def enabled?
    @enabled
  end

  # Milliseconds since the profiler was created, rounded to 0.1 ms.
  #
  # @return [Float, nil] nil when disabled
  def elapsed_ms
    return unless @enabled

    ((@clock.call - @t0) * 1000).round(1)
  end

  # Record a milestone for {#log_timings}.
  #
  # @param label [String] name of the milestone
  # @return [void]
  def mark(label)
    return unless @enabled

    @timings << [label, elapsed_ms]
    nil
  end

  # Log one line, "<event>: <elapsed>ms", under +boot-profile+.
  #
  # @param event [String] what just happened
  # @return [void]
  def log_elapsed(event)
    return unless @enabled

    ProfanityLog.write('boot-profile', "#{event}: #{elapsed_ms}ms")
    nil
  end

  # Log the recorded milestones under +boot-profile+, one row each with
  # the time since start and since the previous milestone.
  #
  # @return [void]
  def log_timings
    return unless @enabled

    prev = 0.0
    lines = @timings.map do |label, ms|
      delta = (ms - prev).round(1)
      prev = ms
      format('  %7.1fms (+%6.1fms)  %s', ms, delta, label)
    end
    ProfanityLog.write('boot-profile', "Startup timing:\n#{lines.join("\n")}")
    nil
  end
end
