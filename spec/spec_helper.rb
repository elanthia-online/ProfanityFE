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

  def self.color_pair(_id) = 0
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
  def self.mouseinterval(*) = 166
  def self.getmouse = nil
  def self.close_screen = nil
  def self.init_screen = nil
  def self.start_color = nil
  def self.cbreak = nil
  def self.noecho = nil
  def self.nonl = nil
  def self.stdscr = Window.new

  # Spy-friendly stub window. Records all method calls for assertions.
  #
  # @example
  #   win = Curses::Window.new(1, 80, 0, 0)
  #   win.addstr("hello")
  #   expect(win.call_log).to include([:addstr, ["hello"]])
  class Window
    attr_accessor :maxx, :maxy, :begy, :begx
    attr_reader :call_log

    def initialize(h = 1, w = 80, t = 0, l = 0)
      @maxy = h
      @maxx = w
      @begy = t
      @begx = l
      @call_log = []
    end

    # Record all method calls for spy-style assertions
    %i[
      setpos addstr addch insch delch deleteln clrtoeol
      noutrefresh refresh resize move erase close
      scrollok keypad clear
    ].each do |meth|
      define_method(meth) do |*args|
        @call_log << [meth, args]
        nil
      end
    end

    def nodelay=(val)
      @call_log << [:nodelay=, [val]]
    end

    def getch
      @call_log << [:getch, []]
      nil
    end

    def attron(attrs)
      @call_log << [:attron, [attrs]]
      yield if block_given?
    end
  end
end

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
# Top-level helpers defined in profanity.rb
# ---------------------------------------------------------------------------

def safe_eval_arithmetic(expr)
  normalized = expr.gsub(/\s+/, '')
  return 0 unless normalized.match?(%r{\A[\d+\-*/()]+\z})
  return 0 if normalized.include?('**')

  eval(expr).to_i
rescue SyntaxError, ZeroDivisionError
  0
end

def get_color_pair_id(_fg, _bg) = 0

def add_prompt(window, prompt_text, cmd = '')
  return if cmd.empty? && window.respond_to?(:duplicate_prompt?) && window.duplicate_prompt?(prompt_text)

  prompt_colors = [{ start: 0, end: (prompt_text.length + cmd.length), fg: '555555' }]
  window.route_string("#{prompt_text}#{cmd}", prompt_colors, MAIN_STREAM)
end

def parse_player_names(text)
  text.sub(/^Also here:\s*/, '')
      .sub(/ and (?<rest>.*)$/) { ", #{Regexp.last_match[:rest]}" }
      .split(', ')
      .map { |obj| obj.sub(/ (who|whose body)? ?(has|is|appears|glows) .+/, '').sub(/ \(.+\)/, '') }
      .map { |obj| obj.strip.scan(/\w+$/).first }
      .compact
end

# ---------------------------------------------------------------------------
# Stub modules that lib files reference at require time
# ---------------------------------------------------------------------------

module ProfanityLog
  def self.write(*_args, **_kwargs) = nil
end

module HighlightProcessor
  module_function

  def apply_highlights(text, line_colors = [])
    SETTINGS_LOCK.synchronize do
      HIGHLIGHT.each_pair do |regex, colors|
        pos = 0
        while (match_data = text.match(regex, pos))
          h = {
            start: match_data.begin(0),
            end: match_data.end(0),
            fg: colors[0],
            bg: colors[1],
            ul: colors[2]
          }
          line_colors.push(h)
          pos = match_data.end(0)
        end
      end
    end
    line_colors
  end

  def render_colored_text(*) = nil
end

# Stub window class hierarchies
class BaseWindow < Curses::Window
  def self.list = @list ||= []
  def self.register_type(*) = nil
  def self.type_registry = {}
  def self.find_window_at(*) = nil

  attr_accessor :layout

  def route_string(text, colors, stream, **opts)
    # No-op in base stub; specs that need recording override this
  end
end

class TextWindow < BaseWindow
  def self.list = @list ||= []

  def add_string(_text, _colors = []) = nil
end

class TabbedTextWindow < BaseWindow
  def self.list = @list ||= []

  def tabs = {}
  def active_tab = nil
end

class IndicatorWindow < BaseWindow
  def self.list = @list ||= []
end

class ProgressWindow < BaseWindow
  def self.list = @list ||= []
end

class CountdownWindow < BaseWindow
  def self.list = @list ||= []
end

class ExpWindow < BaseWindow
  def self.list = @list ||= []
end

class PercWindow < BaseWindow
  def self.list = @list ||= []
end

class RoomWindow < BaseWindow
  def self.list = @list ||= []
end

class SinkWindow; end

# Stub GagPatterns (real version loaded by specs that test it)
module GagPatterns
  def self.general_regexp = /\A\z/
  def self.combat_regexp = /\A\z/
  def self.load_defaults = nil
  def self.clear_custom = nil
  def self.add_general_pattern(*) = nil
  def self.add_combat_pattern(*) = nil
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
  end
end
