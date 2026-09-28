# frozen_string_literal: true

require_relative 'config'
require_relative 'streams'

# constants.rb: Global constants for ProfanityFE.
#
# Immutable constants (MAIN_STREAM, DEFAULT_BUFFER_SIZE, etc.) are
# defined directly. Mutable runtime state (HIGHLIGHT, PRESET, LAYOUT,
# etc.) is owned by the CONFIG object and aliased here for backward
# compatibility — all existing code continues to use HIGHLIGHT[key],
# PRESET[key], etc. unchanged.

# ---- Immutable constants ----

# @return [String] default stream name for the primary game output window.
#   Alias of {Streams::MAIN}, kept for its many existing callers.
MAIN_STREAM = Streams::MAIN

# @return [Integer] default maximum number of lines retained per text window buffer
DEFAULT_BUFFER_SIZE = 250

# @return [String] default log file name, used when neither --log-file nor --char is given.
#   profanity.rb hands the resolved path to {ProfanityLog.configure} after CLI parsing.
DEFAULT_LOG_FILE = 'profanity.log'

# @return [Integer] number of backtrace frames written to the log on errors
BACKTRACE_LIMIT = 4

# @return [Integer] seconds to wait before allowing server time offset recalculation
TIME_SYNC_DELAY = 15

# @return [Float] seconds subtracted from countdown timers to compensate for network latency
COUNTDOWN_OFFSET = 0.2

# @return [Integer] fallback terminal width when no Curses window is attached
DEFAULT_TERMINAL_WIDTH = 80

# @return [String] hex color for all ProfanityFE feedback messages (dot-commands, status, etc.)
FEEDBACK_COLOR = 'ffff00'

# ---- Mutable runtime state (owned by CONFIG, aliased for compatibility) ----

# @return [Config] centralized mutable configuration object
CONFIG = Config.new

# Aliases to CONFIG internals. These are the SAME Hash/Array objects,
# so mutating HIGHLIGHT is identical to mutating CONFIG.highlight.
# This preserves backward compatibility across all 12+ consumer files.
#
# Alias of {Config#lock}.
SETTINGS_LOCK  = CONFIG.lock
# Alias of {Config#highlight} (the same object).
HIGHLIGHT      = CONFIG.highlight
# Alias of {Config#preset} (the same object).
PRESET         = CONFIG.preset
# Alias of {Config#layout} (the same object).
LAYOUT         = CONFIG.layout
# Alias of {Config#scroll_window} (the same object).
SCROLL_WINDOW  = CONFIG.scroll_window
# Alias of {Config#perc_transforms} (the same object).
PERC_TRANSFORMS = CONFIG.perc_transforms
