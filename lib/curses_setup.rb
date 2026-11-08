# frozen_string_literal: true

# curses_setup.rb: Curses terminal initialization for ProfanityFE.
#
# Requiring this file loads the curses library (and {MouseEventWarning})
# but leaves the terminal alone; {CursesSetup.start} takes it over.

require 'curses'
require_relative 'mouse_event_warning'
# NOTE: `include Curses` was removed to avoid polluting the global Object namespace.
# All Curses module methods are called with explicit `Curses.` prefix.
# Window subclasses inherit instance methods (addstr, setpos, etc.) via BaseWindow < Curses::Window.

# Starts curses for ProfanityFE.
module CursesSetup
  # Take over the terminal: start curses and colors, turn off line
  # buffering and echo, and turn on keypad mode. Also uses up the curses
  # gem's one-time mouse warning, so it is never drawn over the screen
  # (see {MouseEventWarning}).
  #
  # From here on curses owns the terminal, so anything printed to it is
  # lost; call this only after the command line and settings paths have
  # been checked, and before the client starts any thread. lib/key_codes.rb
  # reads key names when it is loaded, so load it after this call.
  #
  # @return [void]
  def self.start
    Curses.init_screen
    MouseEventWarning.trigger_silently
    Curses.start_color
    # Mouse tracking disabled - breaks terminal's native copy/paste
    # Uncomment to enable custom mouse selection (Phase 3 - currently dormant)
    # Curses.mousemask(Curses::ALL_MOUSE_EVENTS | Curses::REPORT_MOUSE_POSITION)
    Curses.cbreak
    Curses.noecho
    # Keypad mode makes ncurses number the terminal's extended keys (ctrl/alt
    # arrows and the like), which key_codes reads when it is loaded.
    Curses.stdscr.keypad(true)
  end
end
