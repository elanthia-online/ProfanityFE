# frozen_string_literal: true

# settings_warnings.rb: problems found in the settings and layouts (a bad
# pattern, a layout expression that can't be worked out, an unknown
# layout), for the log and the main window.
#
# Requiring this file loads nothing else: {SettingsWarnings.add} uses the
# {ProfanityLog} that profanity.rb has loaded by the time it is called.

# Collects warnings about the settings and layouts.
#
# They used to go to stderr with +warn+, which curses draws over the
# client's screen, because the settings are loaded after curses starts.
# Now each one is written to the log when it is added, and kept until
# {Application} shows it in the main window: right after +.reload+ and
# +.layout+, and otherwise on the next pass of the input loop ({take}),
# so a warning from startup, a resize or the server thread shows up as
# soon as there is a main window to show it in.
#
# The same message is reported once until {forget_reported} for its kind:
# a layout expression that can't be worked out is evaluated again on
# every resize. Application forgets the +:settings+ warnings when the user
# reloads the settings, and the +:layout+ ones when the user switches
# layouts, the two commands that check those things again. Safe to use
# from any thread.
module SettingsWarnings
  # What a warning is about: +:settings+ for something in the settings
  # file (a pattern), +:layout+ for something in a layout (an expression,
  # an unknown layout name).
  KINDS = %i[settings layout].freeze

  @lock = Mutex.new
  @pending = []
  @reported = {}

  class << self
    # Report a warning: write it to the log and keep it for the main
    # window, unless the same message was reported since the last
    # {forget_reported} for its kind.
    #
    # @param message [String] the warning, on one line
    # @param kind [Symbol] one of {KINDS}
    # @return [void]
    # @raise [ArgumentError] for a kind not in {KINDS}
    def add(message, kind: :settings)
      raise ArgumentError, "unknown warning kind #{kind.inspect}" unless KINDS.include?(kind)

      fresh = @lock.synchronize do
        next false if @reported.key?(message) || @pending.include?(message)

        @reported[message] = kind
        @pending << message
        true
      end
      ProfanityLog.write('settings', message) if fresh
    end

    # Take the warnings not shown yet, oldest first, and forget them.
    #
    # @return [Array<String>] the warnings, possibly none
    def take
      @lock.synchronize do
        taken = @pending
        @pending = []
        taken
      end
    end

    # Let each message of +kind+ be reported again (warnings not taken
    # yet are kept). Called when the user reloads the settings
    # (+:settings+) or switches layouts (+:layout+), so a problem that is
    # still there is shown again.
    #
    # @param kind [Symbol] one of {KINDS}
    # @return [void]
    # @raise [ArgumentError] for a kind not in {KINDS}
    def forget_reported(kind)
      raise ArgumentError, "unknown warning kind #{kind.inspect}" unless KINDS.include?(kind)

      @lock.synchronize { @reported.delete_if { |_message, reported_kind| reported_kind == kind } }
    end

    # Drop everything: pending warnings and reported messages. For specs,
    # which share one process.
    #
    # @return [void]
    def reset
      @lock.synchronize do
        @pending = []
        @reported.clear
      end
    end
  end
end
