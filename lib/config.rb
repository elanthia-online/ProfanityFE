# frozen_string_literal: true

require_relative 'streams'

# Centralized mutable configuration for ProfanityFE.
#
# Owns all runtime-mutable state that was previously spread across 5
# global constants (HIGHLIGHT, PRESET, LAYOUT, SCROLL_WINDOW,
# PERC_TRANSFORMS) and a global mutex (SETTINGS_LOCK).
#
# The existing global constants are aliased to this object's internal
# hashes/arrays in constants.rb, so all existing code continues to
# work unchanged (e.g., `PRESET['monsterbold']` reads from
# `CONFIG.preset['monsterbold']` — same Hash object).
#
# @example Reset all mutable state (e.g., between tests)
#   CONFIG.reset!
class Config
  # Stream that notifier notes (script STATUS, almanac, empath, etc.) go to
  # unless <notification-stream> overrides it.
  DEFAULT_NOTIFICATION_STREAM = Streams::FAMILIAR

  # Number of commands kept in the command history unless <history-size>
  # overrides it.
  DEFAULT_HISTORY_SIZE = 1000

  # @return [Hash<Regexp, Array>] highlight patterns mapping regex => [fg, bg, ul]
  attr_reader :highlight

  # @return [Hash<String, Array>] color presets mapping id => [fg, bg]
  attr_reader :preset

  # @return [Hash<String, CachedElement>] window layouts mapping id => +<layout>+ element
  attr_reader :layout

  # @return [Array<BaseWindow>] ordered list of scrollable windows for Ctrl+W cycling
  attr_reader :scroll_window

  # @return [Array<Array(Regexp, String)>] percWindow text transformations [pattern, replacement]
  attr_reader :perc_transforms

  # @return [String] stream that notifier notes are routed to
  #   (set with <notification-stream> in the settings XML)
  attr_accessor :notification_stream

  # @return [Integer] maximum number of commands kept in the command history
  #   (set with <history-size> in the settings XML)
  attr_accessor :history_size

  # @return [Mutex] synchronization lock for HIGHLIGHT reads during settings reload
  attr_reader :lock

  # Empty highlights, presets, layouts, scroll windows and perc-transforms,
  # with the default notification stream and history size.
  def initialize
    @highlight = {}
    @preset = {}
    @layout = {}
    @scroll_window = []
    @perc_transforms = []
    @notification_stream = DEFAULT_NOTIFICATION_STREAM
    @history_size = DEFAULT_HISTORY_SIZE
    @lock = Mutex.new
  end

  # Clear ALL mutable state. Used between tests and on full reset.
  #
  # @return [void]
  def reset!
    @lock.synchronize do
      @highlight.clear
      @preset.clear
      @layout.clear
      @scroll_window.clear
      @perc_transforms.clear
      @notification_stream = DEFAULT_NOTIFICATION_STREAM
      @history_size = DEFAULT_HISTORY_SIZE
    end
  end
end
