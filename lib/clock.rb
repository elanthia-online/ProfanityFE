# frozen_string_literal: true

# The wall clock Profanity reads for timestamps and countdowns, and the
# formats its timestamps are written in.
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
  end

  # Read the clock.
  #
  # @return [Time] the current time
  def now
    @now.call
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
