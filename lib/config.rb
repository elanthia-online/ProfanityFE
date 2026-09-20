# frozen_string_literal: true

# Centralized mutable configuration for ProfanityFE.
#
# Owns all runtime-mutable state that was previously spread across 6
# global constants (HIGHLIGHT, PRESET, LAYOUT, SCROLL_WINDOW,
# ROOM_OBJECTS, PERC_TRANSFORMS) and a global mutex (SETTINGS_LOCK).
#
# The existing global constants are aliased to this object's internal
# hashes/arrays in constants.rb, so all existing code continues to
# work unchanged (e.g., `PRESET['monsterbold']` reads from
# `CONFIG.preset['monsterbold']` — same Hash object).
#
# @example Reset all mutable state (e.g., between tests)
#   CONFIG.reset!
#
# @example Reset only dynamic settings (e.g., during hot-reload)
#   CONFIG.reset_dynamic!
class Config
  # Stream that notifier notes (script STATUS, almanac, empath, etc.) go to
  # unless <notification-stream> overrides it.
  DEFAULT_NOTIFICATION_STREAM = 'familiar'

  # @return [Hash<Regexp, Array>] highlight patterns mapping regex => [fg, bg, ul]
  attr_reader :highlight

  # @return [Hash<String, Array>] color presets mapping id => [fg, bg]
  attr_reader :preset

  # @return [Hash<String, REXML::Element>] window layouts mapping id => XML element
  attr_reader :layout

  # @return [Array<BaseWindow>] ordered list of scrollable windows for Ctrl+W cycling
  attr_reader :scroll_window

  # @return [Array<String>] current room creatures/objects for highlighting
  attr_reader :room_objects

  # @return [Array<Array(Regexp, String)>] percWindow text transformations [pattern, replacement]
  attr_reader :perc_transforms

  # @return [String] stream that notifier notes are routed to
  #   (set with <notification-stream> in the settings XML)
  attr_accessor :notification_stream

  # @return [Mutex] synchronization lock for HIGHLIGHT reads during settings reload
  attr_reader :lock

  def initialize
    @highlight = {}
    @preset = {}
    @layout = {}
    @scroll_window = []
    @room_objects = []
    @perc_transforms = []
    @notification_stream = DEFAULT_NOTIFICATION_STREAM
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
      @room_objects.clear
      @perc_transforms.clear
      @notification_stream = DEFAULT_NOTIFICATION_STREAM
    end
  end

  # Clear only settings that are refreshed during hot-reload
  # (highlights, perc-transforms, notification-stream). Presets and layouts are preserved.
  #
  # @return [void]
  def reset_dynamic!
    @lock.synchronize do
      @highlight.clear
      @perc_transforms.clear
      @notification_stream = DEFAULT_NOTIFICATION_STREAM
    end
  end
end
