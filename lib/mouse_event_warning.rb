# frozen_string_literal: true

# mouse_event_warning.rb: keeps a warning from the curses gem off the
# screen.
#
# Requiring this file loads nothing else: {MouseEventWarning.trigger_silently}
# uses the +Curses+ and {ProfanityLog} that profanity.rb has loaded by the
# time it is called.

# The curses gem (every release from 1.4, the oldest the Gemfile allows,
# through 1.7.0) defines +Curses::MouseEvent+ without undefining its
# allocator. The first time +Curses.getmouse+ builds one, Ruby 3.2 and
# later undefine the allocator themselves and print
#
#   warning: undefining the allocator of T_DATA class Curses::MouseEvent
#
# to stderr. Curses owns the terminal by then, so the text is drawn over
# the client's screen. It happened on the first mouse event of a session
# for anyone with mouse capture on: --links, .links, .select, .scrollcfg,
# or a wheel calibration saved by .scrollcfg in an earlier session.
#
# Two facts make one call at startup enough (see {trigger_silently}):
# Ruby undefines the allocator before it warns, so the warning comes only
# once per process; and +getmouse+ builds the event before it asks ncurses
# for one, so a call with no mouse event waiting (it returns nil) still
# uses the warning up.
module MouseEventWarning
  # Call +Curses.getmouse+ once with warnings off, so Ruby's one-time
  # warning about +Curses::MouseEvent+ is used up where nobody sees it.
  # Later +getmouse+ calls, with warnings back on, print nothing.
  #
  # Call it right after +Curses.init_screen+ and before the client starts
  # any thread:
  # - not earlier: +getmouse+ starts curses itself if it isn't running, and
  #   curses must not take over the terminal before the command line has
  #   been checked;
  # - not later: +$VERBOSE+ is shared by every thread, so while it is nil
  #   here a warning from another thread would be lost too. With only the
  #   main thread running there is none to lose, and the mouse readers
  #   need no guard of their own.
  #
  # Nothing has been read from the keyboard yet, so there is no mouse event
  # waiting to be taken from the input loop. A curses library without
  # mouse support (no +Curses.getmouse+) is left alone. If +getmouse+
  # raises, the error is logged and startup goes on; +$VERBOSE+ is put
  # back either way.
  #
  # @return [void]
  def self.trigger_silently
    return unless Curses.respond_to?(:getmouse)

    verbose = $VERBOSE
    $VERBOSE = nil
    begin
      Curses.getmouse
    ensure
      $VERBOSE = verbose
    end
  rescue StandardError => e
    ProfanityLog.write('mouse', "Curses.getmouse failed at startup: #{e.class}: #{e.message}")
  end
end
