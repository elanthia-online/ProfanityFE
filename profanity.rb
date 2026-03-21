#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: US-ASCII # rubocop:disable Lint/OrderedMagicComments

# vim: set sts=2 noet ts=2:
#
#   ProfanityFE v0.4
#   Copyright (C) 2013  Matthew Lowe
#
#   This program is free software; you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation; either version 2 of the License, or
#   (at your option) any later version.
#
#   This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License along
#   with this program; if not, write to the Free Software Foundation, Inc.,
#   51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
#   matt@lichproject.org
#

require 'socket'
require 'rexml/document'

BOOT_PROFILE = ARGV.include?('--profile')

if BOOT_PROFILE
  BOOT_T0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  BOOT_TIMINGS = []

  def boot_mark(label)
    elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - BOOT_T0) * 1000).round(1)
    BOOT_TIMINGS << [label, elapsed]
  end

  boot_mark('stdlib loaded')
end

# Load version and initialize curses
require_relative 'lib/version'
require_relative 'lib/curses_setup'
boot_mark('curses init') if BOOT_PROFILE

# Load global constants (HIGHLIGHT, PRESET, LAYOUT, etc.)
require_relative 'lib/constants'

# Thread-safe curses rendering (must be loaded before any doupdate calls)
require_relative 'lib/curses_renderer'

# Centralized highlight processing (must be loaded before windows)
require_relative 'lib/highlight_processor'

# Window classes loaded from lib/windows/
require_relative 'lib/windows/base_window'
require_relative 'lib/windows/skill'
require_relative 'lib/windows/exp_window'
require_relative 'lib/windows/perc_window'
require_relative 'lib/windows/text_window'
require_relative 'lib/windows/tabbed_text_window'
require_relative 'lib/windows/progress_window'
require_relative 'lib/windows/countdown_window'
require_relative 'lib/windows/indicator_window'
require_relative 'lib/windows/sink_window'
require_relative 'lib/windows/room_window'
require_relative 'lib/key_codes'
require_relative 'lib/color_manager'
require_relative 'lib/selection_manager'
require_relative 'lib/gag_patterns'

# Extracted modules (SRP decomposition)
require_relative 'lib/shared_state'
require_relative 'lib/kill_ring'
require_relative 'lib/string_classification'
require_relative 'lib/profanity_log'
require_relative 'lib/command_buffer'
require_relative 'lib/window_manager'
require_relative 'lib/settings_loader'
require_relative 'lib/games/dragonrealms'
require_relative 'lib/games/gemstone'
require_relative 'lib/room_data_processor'
require_relative 'lib/familiar_notifier'
require_relative 'lib/game_text_processor'
require_relative 'lib/profanity_settings'
require_relative 'lib/autocomplete'
require_relative 'lib/mouse_scroll'
require_relative 'lib/application'

# Initialize gag patterns with defaults (can be extended via XML config)
GagPatterns.load_defaults
boot_mark('requires + gag defaults') if BOOT_PROFILE

# Ensure terminal is restored on any exit path (graceful shutdown)
at_exit do
  Curses.close_screen
rescue StandardError
  nil
end

# @deprecated Use {BaseWindow.parse_color_attrs} instead.
def parse_color_attrs(element, attr_name)
  return unless element.attributes[attr_name]

  element.attributes[attr_name].split(',').collect do |val|
    val == 'nil' ? nil : val
  end
end

# @deprecated Use RoomDataProcessor#parse_player_names instead.
def parse_player_names(text)
  text.sub(/^Also here:\s*/, '')
      .sub(/ and (?<rest>.*)$/) { ", #{Regexp.last_match[:rest]}" }
      .split(', ')
      .map { |obj| obj.sub(/ (who|whose body)? ?(has|is|appears|glows) .+/, '').sub(/ \(.+\)/, '') }
      .map { |obj| obj.strip.scan(/\w+$/).first }
      .compact
end

# @deprecated Use {WindowManager#add_prompt} instead.
#   Kept for backward compatibility with spec_helper and external callers.
def add_prompt(window, prompt_text, cmd = '')
  return if cmd.empty? && window.respond_to?(:duplicate_prompt?) && window.duplicate_prompt?(prompt_text)

  prompt_colors = [{ start: 0, end: (prompt_text.length + cmd.length), fg: '555555' }]
  window.route_string("#{prompt_text}#{cmd}", prompt_colors, MAIN_STREAM)
end

# Safe arithmetic expression evaluator for layout dimensions.
# Parses integers, +, -, *, /, and parentheses without using eval.
# Uses a simple recursive descent parser (expression → term → factor).
#
# @param expr [String] arithmetic expression (e.g., "lines-2", "cols/3+1")
# @return [Integer] computed result, or 0 on error
def safe_eval_arithmetic(expr)
  tokens = expr.gsub(/\s+/, '').scan(%r{(\d+|[+\-*/()]|.)})
               .flatten.reject(&:empty?)

  # Reject tokens that aren't valid arithmetic
  unless tokens.all? { |t| t.match?(%r{\A(\d+|[+\-*/()])\z}) }
    warn "Invalid layout expression (unsafe characters): #{expr}"
    return 0
  end

  pos = [0] # mutable position index

  # Recursive descent: expr → term ((+|-) term)*
  parse_expr = nil
  parse_term = nil
  parse_factor = nil

  parse_factor = lambda {
    if tokens[pos[0]] == '('
      pos[0] += 1
      result = parse_expr.call
      pos[0] += 1 if tokens[pos[0]] == ')' # consume ')'
      result
    elsif tokens[pos[0]] == '-'
      pos[0] += 1
      -parse_factor.call
    elsif tokens[pos[0]]&.match?(/\A\d+\z/)
      val = tokens[pos[0]].to_i
      pos[0] += 1
      val
    else
      0
    end
  }

  parse_term = lambda {
    result = parse_factor.call
    while pos[0] < tokens.length && %w[* /].include?(tokens[pos[0]])
      op = tokens[pos[0]]
      pos[0] += 1
      right = parse_factor.call
      if op == '*'
        result *= right
      elsif right != 0
        result /= right
      else
        result = 0 # division by zero → 0
      end
    end
    result
  }

  parse_expr = lambda {
    result = parse_term.call
    while pos[0] < tokens.length && %w[+ -].include?(tokens[pos[0]])
      op = tokens[pos[0]]
      pos[0] += 1
      right = parse_term.call
      result = op == '+' ? result + right : result - right
    end
    result
  }

  parse_expr.call.to_i
rescue StandardError => e
  warn "Layout expression error: #{e.message} in '#{expr}'"
  0
end

# ========== CLI CONFIGURATION ==========

require 'optparse'

cli_options = {
  port: 8000,
  default_color_id: 7,
  default_background_color_id: 0,
  use_default_colors: false,
  custom_colors: nil,
  settings_file: nil,
  log_dir: nil,
  log_file: nil,
  char: nil,
  config: nil,
  template: nil,
  no_status: false,
  links: false,
  speech_ts: false,
  room_window_only: false,
  remote_url: false,
}

OptionParser.new do |opts|
  opts.banner = "\nProfanity FrontEnd v#{VERSION}\n\n"

  opts.on('--char=NAME', 'Character name (for log file & process title)') { |v| cli_options[:char] = v }
  opts.on('--config=NAME', 'Config name to load (default: same as --char)') { |v| cli_options[:config] = v }
  opts.on('--template=FILE', 'Template file name (from templates/)') { |v| cli_options[:template] = v }
  opts.on('--port=PORT', Integer, 'Game server port (default: 8000)') { |v| cli_options[:port] = v }
  opts.on('--default-color-id=ID', Integer, 'Default foreground color (default: 7)') { |v| cli_options[:default_color_id] = v }
  opts.on('--default-background-color-id=ID', Integer, 'Default background color (default: 0)') { |v| cli_options[:default_background_color_id] = v }
  opts.on('--custom-colors=MODE', %w[on off yes no], 'Force custom color mode (on/off/yes/no)') do |v|
    cli_options[:custom_colors] = %w[on yes].include?(v)
  end
  opts.on('--use-default-colors', 'Use terminal default colors') { cli_options[:use_default_colors] = true }
  opts.on('--no-status', 'Disable process title updates') { cli_options[:no_status] = true }
  opts.on('--links', 'Enable in-game link highlighting') { cli_options[:links] = true }
  opts.on('--speech-ts', 'Add timestamps to speech, familiar, and thought windows') { cli_options[:speech_ts] = true }
  opts.on('--room-window-only', 'Do not echo room data to the story window') { cli_options[:room_window_only] = true }
  opts.on('--remote-url', 'Display LaunchURLs on screen instead of opening browser') { cli_options[:remote_url] = true }
  opts.on('--log-file=PATH', 'Log file path (default: profanity.log)') { |v| cli_options[:log_file] = v }
  opts.on('--log-dir=DIR', 'Log directory (default: current directory)') { |v| cli_options[:log_dir] = v }
  opts.on('--settings-file=FILE', 'Settings XML file path (overrides --char/--config lookup)') { |v| cli_options[:settings_file] = v }
  opts.on('--profile', 'Log boot timing to log file') {} # handled early via BOOT_PROFILE
end.parse!

# ========== GLOBAL CONSTANTS ==========

PORT = cli_options[:port]
CHAR_NAME = cli_options[:char]

SETTINGS_FILENAME = ProfanitySettings.resolve_template(
  char: cli_options[:config] || cli_options[:char],
  template: cli_options[:template],
  settings_file: cli_options[:settings_file],
  app_dir: File.dirname(__FILE__)
)

LOG_FILE = ProfanitySettings.resolve_log(
  char: cli_options[:char],
  log_file: cli_options[:log_file],
  log_dir: cli_options[:log_dir]
)

DEFAULT_COLOR_ID = cli_options[:default_color_id]
DEFAULT_BACKGROUND_COLOR_ID = cli_options[:default_background_color_id]
Curses.use_default_colors if cli_options[:use_default_colors]
CUSTOM_COLORS = cli_options[:custom_colors].nil? ? Curses.can_change_color? : cli_options[:custom_colors]

NO_STATUS = cli_options[:no_status]
SPEECH_TS = cli_options[:speech_ts]

ColorManager.configure(
  default_color_id: DEFAULT_COLOR_ID,
  default_background_color_id: DEFAULT_BACKGROUND_COLOR_ID,
  custom_colors: CUSTOM_COLORS
)

# ========== RUN ==========
boot_mark('constants + color config') if BOOT_PROFILE

Application.new(cli_options).run
