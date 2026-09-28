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

# ========== CLI CONFIGURATION ==========
# Parsed and resolved before curses starts: curses owns the terminal from
# then on, so an error or --help printed later would not be seen.

require_relative 'lib/version'
require_relative 'lib/cli_options'
require_relative 'lib/profanity_settings'

# ~/.profanity holds the settings cache, settings.json, selection.txt and,
# with --char, the log. Created first thing, even for --help or a bad option.
ProfanitySettings.ensure_app_dir

cli_options = CliOptions.parse_or_exit(ARGV)

# Path of the settings XML chosen by {ProfanitySettings.resolve_template}.
SETTINGS_FILENAME = ProfanitySettings.resolve_template(
  char: cli_options[:config] || cli_options[:char],
  template: cli_options[:template],
  settings_file: cli_options[:settings_file],
  app_dir: File.dirname(__FILE__)
)

# Log file path chosen by {ProfanitySettings.resolve_log}.
LOG_FILE = ProfanitySettings.resolve_log(
  char: cli_options[:char],
  log_file: cli_options[:log_file],
  log_dir: cli_options[:log_dir]
)

# True when started with --profile (or an abbreviation such as --prof):
# boot timings are recorded and logged.
BOOT_PROFILE = cli_options[:profile]

if BOOT_PROFILE
  # Monotonic clock reading at startup; {#boot_mark} measures from here.
  BOOT_T0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  # Recorded boot milestones as [label, elapsed milliseconds] pairs.
  BOOT_TIMINGS = []

  # Record a boot milestone in {BOOT_TIMINGS}. Only defined with --profile.
  #
  # @param label [String] name of the milestone
  # @return [Array<Array(String, Float)>] {BOOT_TIMINGS}
  def boot_mark(label)
    elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - BOOT_T0) * 1000).round(1)
    BOOT_TIMINGS << [label, elapsed]
  end

  boot_mark('stdlib loaded')
end

# Initialize curses
require_relative 'lib/curses_setup'
CursesSetup.start
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

# ========== GLOBAL CONSTANTS ==========

# Game server (Lich) port, from --port (default 8000).
PORT = cli_options[:port]
# Game server (Lich) host, from --host (default 127.0.0.1).
HOST = cli_options[:host]

# Default foreground curses color id, from --default-color-id (default 7).
DEFAULT_COLOR_ID = cli_options[:default_color_id]
# Default background curses color id, from --default-background-color-id (default 0).
DEFAULT_BACKGROUND_COLOR_ID = cli_options[:default_background_color_id]
Curses.use_default_colors if cli_options[:use_default_colors]
# Whether to redefine terminal colors: --custom-colors, else Curses.can_change_color?.
CUSTOM_COLORS = cli_options[:custom_colors].nil? ? Curses.can_change_color? : cli_options[:custom_colors]

# True when started with --speech-ts (timestamp speech, familiar and thoughts lines).
SPEECH_TS = cli_options[:speech_ts]

ColorManager.configure(
  default_color_id: DEFAULT_COLOR_ID,
  default_background_color_id: DEFAULT_BACKGROUND_COLOR_ID,
  custom_colors: CUSTOM_COLORS
)

# ========== RUN ==========
boot_mark('constants + color config') if BOOT_PROFILE

Application.new(cli_options).run
