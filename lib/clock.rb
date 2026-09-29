# frozen_string_literal: true

# The wall clock Profanity reads for timestamps and countdowns, the
# formats its timestamps are written in, and how far the game server's
# clock is behind it.
#
# One clock is made by {Application} and passed to the {WindowManager}
# (which hands it to the windows it builds) and the {GameTextProcessor}.
# Specs pass a clock whose time they choose.
#
# Each format helper reads the clock once, so a timestamp can't mix the
# hour of one reading with the minute of the next.
#
# @example A clock stopped at a chosen time
#   clock = Clock.new(now: -> { Time.new(2026, 9, 29, 9, 5, 7) })
#   clock.hh_mm   #=> "09:05"
#   clock.h_mm_ss #=> "9:05:07"
class Clock
  # @param now [#call] returns the current time as a +Time+; defaults to
  #   +Time.now+, called at every reading
  def initialize(now: -> { Time.now })
    @now = now
    @mutex = Mutex.new
    @server_time_offset = 0.0
  end

  # How many seconds this clock runs ahead of the game server's clock,
  # measured at a +<prompt time=...>+ (see TagHandlers#handle_prompt_tag).
  # Countdown end times are server times; subtracting this offset from
  # {#now} gives the server's time now ({#server_now}).
  #
  # @return [Float]
  def server_time_offset
    @mutex.synchronize { @server_time_offset }
  end

  # Set by the server thread and read by the countdown windows on the
  # input thread, so it is held under a mutex.
  #
  # @param val [Float] the new offset in seconds
  # @return [void]
  def server_time_offset=(val)
    @mutex.synchronize { @server_time_offset = val }
  end

  # Read the clock.
  #
  # @return [Time] the current time
  def now
    @now.call
  end

  # The game server's time now: one reading of {#now} less
  # {#server_time_offset}. Countdown end times are server times.
  #
  # @return [Float] seconds since the epoch
  def server_now
    now.to_f - server_time_offset.to_f
  end

  # The current time as hours and minutes, both two digits.
  #
  # @return [String] e.g. "09:05"
  def hh_mm
    now.strftime('%H:%M')
  end

  # The current time as hours, minutes and seconds, without a leading
  # zero on the hour.
  #
  # @return [String] e.g. "9:05:07"
  def h_mm_ss
    now.strftime('%H:%M:%S').sub(/^0/, '')
  end
end
