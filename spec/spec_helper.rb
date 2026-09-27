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
# concurrent access, and off-by-one errors. When a test finds a real
# bug, document it with a "# BUG FOUND:" comment and assert the
# actual (buggy) behavior so the test passes — making the bug
# visible for future fixing.

require 'rspec'
require 'tmpdir'
require 'fileutils'

# Keep the suite out of the real home directory: ProfanitySettings creates
# ~/.profanity when it is required, and SettingsLoader caches settings there.
SPEC_HOME = Dir.mktmpdir('profanity-spec-home')
ENV['HOME'] = SPEC_HOME
at_exit { FileUtils.remove_entry(SPEC_HOME) }

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
  def self.doupdate = nil
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
  def self.render = (yield; nil)
  def self.doupdate = nil
end

# ---------------------------------------------------------------------------
# Global constants expected by lib/ files
# ---------------------------------------------------------------------------

require_relative '../lib/config'

MAIN_STREAM = 'main'
DEFAULT_BUFFER_SIZE = 250
DEFAULT_TERMINAL_WIDTH = 80
COUNTDOWN_OFFSET = 0.2
TIME_SYNC_DELAY = 15
FEEDBACK_COLOR = 'ffff00'
BACKTRACE_LIMIT = 4
SPEECH_TS = false

# Mutable runtime state owned by CONFIG, aliased for compatibility.
# Same pattern as lib/constants.rb — specs use the same Config object.
CONFIG = Config.new
SETTINGS_LOCK   = CONFIG.lock
HIGHLIGHT       = CONFIG.highlight
PRESET          = CONFIG.preset
LAYOUT          = CONFIG.layout
SCROLL_WINDOW   = CONFIG.scroll_window
ROOM_OBJECTS    = CONFIG.room_objects
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

  # Reset all mutable runtime state between tests
  config.before(:each) do
    CONFIG.reset!
    # Some spec files load the real GagPatterns over the stub above; start
    # each example with no gags so patterns never leak between examples.
    GagPatterns.load_defaults
    # Windows register themselves in per-class instance lists; start empty.
    BaseWindow.window_classes.each { |klass| klass.list.clear }
  end
end
