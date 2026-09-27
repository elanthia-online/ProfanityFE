# frozen_string_literal: true

# curses_setup.rb: Curses terminal initialization for ProfanityFE.

require 'curses'
# NOTE: `include Curses` was removed to avoid polluting the global Object namespace.
# All Curses module methods are called with explicit `Curses.` prefix.
# Window subclasses inherit instance methods (addstr, setpos, etc.) via BaseWindow < Curses::Window.

Curses.init_screen
Curses.start_color
# Mouse tracking disabled - breaks terminal's native copy/paste
# Uncomment to enable custom mouse selection (Phase 3 - currently dormant)
# Curses.mousemask(Curses::ALL_MOUSE_EVENTS | Curses::REPORT_MOUSE_POSITION)
Curses.cbreak
Curses.noecho
# Keypad mode makes ncurses number the terminal's extended keys (ctrl/alt
# arrows and the like), which key_codes reads when it is loaded.
Curses.stdscr.keypad(true)
