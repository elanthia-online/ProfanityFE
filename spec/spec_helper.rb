# frozen_string_literal: true

# ProfanityFE spec helper.
#
# Stubs Curses and terminal dependencies so specs run headless.
# Each spec requires only the files it needs — this helper does NOT
# load the full application.
#
# TESTING PHILOSOPHY:
# Specs exist to find bugs, not to confirm happy paths. Every spec
# file must include adversarial edge-case tests that probe boundary
# conditions, nil/missing inputs, unmatched pairs, malformed input,
# concurrent access, and off-by-one errors.
#
# KNOWN BUGS: a spec for a known, unfixed bug asserts the CORRECT
# behaviour and is marked pending with a short reason (and a link or
# issue/audit reference):
#
#   it 'keeps the outer stream after an inner one closes' do
#     pending 'nested pushStream spills into main (issue #NN)'
#     ...
#   end
#
# RSpec still runs a pending example. While it fails it is reported as
# pending and the suite stays green; once the bug is fixed the example
# passes and RSpec reports it as a FAILURE ("Expected pending ... to
# fail"), which is the prompt to delete the `pending` line. Never assert
# the buggy behaviour to make a spec pass: that pins the bug as
# "expected" and makes the fix look like a regression.
#
# CHARACTERIZATION specs (asserting current behaviour as-is) are only
# for intentional quirks, and must say so in their description or a
# comment ("Characterization: ... intentional because ...").

require 'rspec'
require 'stringio'
require 'tmpdir'
require 'fileutils'

# Keep the suite out of the real home directory: specs create ~/.profanity
# (ProfanitySettings.ensure_app_dir) and write settings, the settings cache
# and the selection file there.
SPEC_HOME = Dir.mktmpdir('profanity-spec-home')
ENV['HOME'] = SPEC_HOME
at_exit { FileUtils.remove_entry(SPEC_HOME) }

# ---------------------------------------------------------------------------
# Keep the suite off the desktop: clipboard, browser and terminal
#
# A spec that finishes a selection runs SelectionManager.copy_to_clipboard
# for real. It pipes the text to pbcopy (macOS), wl-copy (Wayland) or xclip
# (X11), then writes an OSC 52 escape to /dev/tty, and either one replaces
# the developer's clipboard. A LaunchURL runs open / xdg-open. Two stand-ins
# apply to every example, so no spec has to remember them:
#
# * SPEC_BIN comes first on PATH (set once here, so specs that save and
#   restore ENV keep it, and child processes inherit it). It holds stand-ins
#   for the clipboard commands (plus xsel, which lib doesn't run today) and
#   the browser commands. A clipboard stand-in saves its
#   arguments to SPEC_BIN/<tool>.args and its input to SPEC_BIN/<tool>.input;
#   a browser stand-in saves only its arguments (it never reads stdin, which
#   is the developer's terminal when a detached spawn inherits it).
# * File.open('/dev/tty', 'w') yields spec_terminal, a StringIO holding what
#   the example sent to the terminal (set in the before hook below).
#
# Specs that test these paths keep working without opting out: their own
# setup replaces the stand-in for that example. Setting ENV['PATH'] to a
# directory with a fake tool (clipboard_missing_tool_spec) hides SPEC_BIN,
# and a spec's own File.open('/dev/tty', 'w') stub (clipboard_*_spec) wins
# because RSpec uses the most recent matching stub. A spec that wants the
# real desktop tools has to put them on PATH itself.
# spec/support/desktop_sandbox_spec.rb fails if either stand-in is removed.
# ---------------------------------------------------------------------------

SPEC_BIN = Dir.mktmpdir('profanity-spec-bin')
at_exit { FileUtils.remove_entry(SPEC_BIN) }

clipboard_stand_in = <<~SH
  #!/bin/sh
  # Clipboard stand-in (spec/spec_helper.rb): keeps the text, copies nothing.
  printf '%s' "$*" > "$0.args"
  cat > "$0.input"
SH
browser_stand_in = <<~SH
  #!/bin/sh
  # Browser stand-in (spec/spec_helper.rb): keeps the arguments, opens nothing.
  printf '%s' "$*" > "$0.args"
SH
%w[pbcopy wl-copy xclip xsel].each { |tool| File.write(File.join(SPEC_BIN, tool), clipboard_stand_in, perm: 0o755) }
%w[open xdg-open].each { |tool| File.write(File.join(SPEC_BIN, tool), browser_stand_in, perm: 0o755) }
ENV['PATH'] = [SPEC_BIN, ENV.fetch('PATH', '')].join(File::PATH_SEPARATOR)

# What the current example sent to the terminal: File.open('/dev/tty', 'w')
# yields this StringIO instead of the real terminal (see above).
module SpecTerminal
  # @return [StringIO] the example's stand-in for /dev/tty
  def spec_terminal
    @spec_terminal ||= StringIO.new
  end
end

# ---------------------------------------------------------------------------
# Curses stub
#
# Records every method call so specs can assert rendering behavior.
# This is the foundation for testing curses interactions without a terminal.
# ---------------------------------------------------------------------------

module Curses
  A_UNDERLINE = 0x20000
  A_BOLD = 0x200000
  A_NORMAL = 0
  A_STANDOUT = 0x10000
  A_REVERSE = 0x40000
  A_COLOR = 0xff00
  KEY_MOUSE = 0x199
  KEY_UP = 0x103
  KEY_DOWN = 0x102
  KEY_LEFT = 0x104
  KEY_RIGHT = 0x105
  KEY_RESIZE = 0x19a
  BUTTON1_PRESSED = 0x2
  BUTTON1_RELEASED = 0x4
  BUTTON1_CLICKED = 0x8
  # Middle and right buttons, as ncurses 6 (mouse version 2) numbers them
  BUTTON2_RELEASED = 0x20
  BUTTON2_PRESSED = 0x40
  BUTTON2_CLICKED = 0x80
  BUTTON2_DOUBLE_CLICKED = 0x100
  BUTTON2_TRIPLE_CLICKED = 0x200
  BUTTON3_RELEASED = 0x400
  BUTTON3_PRESSED = 0x800
  BUTTON3_CLICKED = 0x1000
  BUTTON3_DOUBLE_CLICKED = 0x2000
  BUTTON3_TRIPLE_CLICKED = 0x4000
  REPORT_MOUSE_POSITION = 0x8000000

  def self.color_pair(id) = (id << 8) & A_COLOR
  def self.lines = 24
  def self.cols = 80
  def self.can_change_color? = false
  def self.colors = 256
  def self.color_pairs = 256
  def self.init_pair(*) = nil
  def self.init_color(*) = nil
  def self.color_content(*) = [0, 0, 0]
  def self.doupdate = TerminalCursor.flush
  def self.use_default_colors = nil
  def self.mousemask(*) = nil

  # Models the real curses 1.6.0 binding: NUM2INT raises on non-Integer
  # args, and the return is a boolean — never the previous interval.
  def self.mouseinterval(interval)
    raise TypeError, "no implicit conversion of #{interval.class} into Integer" unless interval.is_a?(Integer)

    true
  end

  def self.getmouse = nil
  def self.close_screen = nil
  def self.init_screen = nil
  def self.start_color = nil
  def self.cbreak = nil
  def self.noecho = nil
  def self.nonl = nil
  def self.stdscr = Window.new
end

# Curses::Window: a virtual screen that records calls and models what the
# window shows, so specs can assert on the visible result.
require_relative 'support/virtual_screen'

# ---------------------------------------------------------------------------
# CursesRenderer stub
# ---------------------------------------------------------------------------

module CursesRenderer
  def self.synchronize = yield
  def self.render = (yield; Curses::TerminalCursor.flush)
  def self.doupdate = Curses::TerminalCursor.flush
  def self.outside_lock = yield
end

# ---------------------------------------------------------------------------
# Global constants expected by lib/ files
# ---------------------------------------------------------------------------

require_relative '../lib/config'

MAIN_STREAM = Streams::MAIN
DEFAULT_BUFFER_SIZE = 250
DEFAULT_TERMINAL_WIDTH = 80
COUNTDOWN_OFFSET = 0.2
TIME_SYNC_DELAY = 15
FEEDBACK_COLOR = 'ffff00'
BACKTRACE_LIMIT = 4

# Mutable runtime state owned by CONFIG, aliased for compatibility.
# Same pattern as lib/constants.rb — specs use the same Config object.
CONFIG = Config.new
SETTINGS_LOCK   = CONFIG.lock
HIGHLIGHT       = CONFIG.highlight
PRESET          = CONFIG.preset
LAYOUT          = CONFIG.layout
SCROLL_WINDOW   = CONFIG.scroll_window
PERC_TRANSFORMS = CONFIG.perc_transforms

# ---------------------------------------------------------------------------
# Top-level helper stubs (the real get_color_pair_id is in lib/color_manager.rb)
# ---------------------------------------------------------------------------

def get_color_pair_id(_fg, _bg) = 0

# ---------------------------------------------------------------------------
# Stub modules that lib files reference at require time
# ---------------------------------------------------------------------------

module ProfanityLog
  def self.write(*_args, **_kwargs) = nil
end

# The real HighlightProcessor (needs only SETTINGS_LOCK, HIGHLIGHT and
# get_color_pair_id, defined above) so specs exercise production matching.
require_relative '../lib/highlight_processor'

# The real window classes, drawing onto the virtual screen above.
%w[base_window text_window tabbed_text_window indicator_window progress_window
   countdown_window skill exp_window perc_window room_window sink_window].each do |window|
  require_relative "../lib/windows/#{window}"
end

# Stub GagPatterns (real version loaded by specs that test it)
module GagPatterns
  def self.general_regexp = /\A\z/
  def self.combat_regexp = /\A\z/
  def self.load_defaults = nil
  def self.clear_custom = nil
  def self.replace_custom(**) = nil
  def self.add_general_pattern(*) = nil
  def self.add_combat_pattern(*) = nil
  def self.add_multiline_gag(*) = nil
  def self.match_multiline_start(*) = nil
  def self.match_general(*) = nil
end

# ---------------------------------------------------------------------------
# RSpec configuration
# ---------------------------------------------------------------------------

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = true
  config.order = :random
  Kernel.srand config.seed
  config.include SpecTerminal

  # Reset all mutable runtime state between tests
  config.before(:each) do
    CONFIG.reset!
    # Some spec files load the real GagPatterns over the stub above; start
    # each example with no gags so patterns never leak between examples.
    GagPatterns.load_defaults
    # Windows register themselves in per-class instance lists; start empty.
    BaseWindow.window_classes.each { |klass| klass.list.clear }
    Curses::TerminalCursor.reset
    # The real terminal is off limits (see "Keep the suite off the desktop").
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with('/dev/tty', 'w').and_yield(spec_terminal)
    # A spec that finishes a selection copies it, and without a clipboard
    # tool (as on CI) the copy lands in ~/.profanity/selection.txt in the
    # shared SPEC_HOME. Left there, it breaks a later example that plants
    # a symlink at that path (clipboard_file_spec).
    FileUtils.rm_f(File.join(SPEC_HOME, '.profanity', 'selection.txt'))
  end

  # RSpec never rescues SystemExit: an example that lets `exit` escape (a
  # dot-command regression making a command match .quit, say) ends the
  # whole run there, and rspec exits 0 with only the examples run so far
  # counted, all passing. Turn the escape into a failure of that example,
  # so the rest of the suite still runs and the run fails. Examples that
  # expect an exit catch it themselves (raise_error(SystemExit)).
  config.around do |example|
    example.run
  rescue SystemExit => e
    raise "the example let exit(#{e.status}) escape; it would have ended the test run"
  end
end
