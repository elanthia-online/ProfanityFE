# frozen_string_literal: true

require_relative 'feedback'

=begin
Tab-completion from command history for the command buffer.
=end

# Provides tab-completion from command history.
#
# When the user presses tab, searches command history for entries
# that start with the whole command line. If multiple matches exist,
# auto-progresses to the longest common prefix and displays options.
#
# The cursor position does not change what is matched: a completion
# replaces the whole command line and leaves the cursor at the end, as
# the original elanthia-online/ProfanityFE autocomplete did.
#
# Ported from elanthia-online/ProfanityFE.
#
# @example
#   Autocomplete.complete(cmd_buffer, stream_window)
module Autocomplete
  # Hex foreground color for autocomplete messages in the main window.
  HIGHLIGHT_COLOR = 'a6e22e'

  # Find all history entries that start with the current input.
  #
  # @param current [String] current command buffer text
  # @param history [Array<String>] command history entries
  # @return [Array<String>] matching history entries
  def self.find_matches(current, history)
    return [] if current.strip.empty?

    history.map(&:strip).reject(&:empty?).compact.uniq.select do |entry|
      entry.length > current.length && entry.start_with?(current)
    end
  end

  # Find the longest common prefix among an array of strings.
  #
  # @param strings [Array<String>] strings to compare
  # @return [String] the longest common prefix
  def self.common_prefix(strings)
    return '' if strings.empty?
    return strings.first if strings.length == 1

    shortest = strings.min_by(&:length)
    shortest.each_char.with_index do |char, i|
      return shortest[0...i] unless strings.all? { |s| s[i] == char }
    end
    shortest
  end

  # Perform tab-completion on the command buffer.
  #
  # @param cmd_buffer [CommandBuffer] the command buffer to modify
  # @param display_window [BaseWindow, nil] window to display suggestions in
  # @return [void]
  def self.complete(cmd_buffer, display_window)
    current = cmd_buffer.text.dup
    matches = find_matches(current, cmd_buffer.history)

    if matches.empty?
      show_message(display_window, '[autocomplete] no suggestions')
      return
    end

    if matches.length == 1
      # Single match: fill it in
      apply_completion(cmd_buffer, matches.first, current)
    else
      # Multiple matches: auto-progress to common prefix and show options
      prefix = common_prefix(matches)
      apply_completion(cmd_buffer, prefix, current) if prefix.length > current.length

      show_message(display_window, "[autocomplete:#{matches.length}]")
      matches.each_with_index do |match, i|
        show_message(display_window, "[#{i}] #{match}")
      end
    end
  rescue StandardError => e
    ProfanityLog.write('autocomplete', e.message, backtrace: e.backtrace)
  end

  # Apply a completion string to the command buffer.
  #
  # +completion+ starts with +original+ (the whole buffer), so moving the
  # cursor to the end and typing the rest turns the command line into
  # +completion+ wherever the cursor was.
  #
  # @param cmd_buffer [CommandBuffer] the buffer to modify
  # @param completion [String] the full completion string
  # @param original [String] the original text (for calculating new chars)
  # @return [void]
  # @api private
  def self.apply_completion(cmd_buffer, completion, original)
    cmd_buffer.cursor_end
    completion[original.length..].each_char { |ch| cmd_buffer.put_ch(ch) }
    cmd_buffer.refresh
    CursesRenderer.doupdate
  end

  # Display a message in the main window with autocomplete highlight color.
  #
  # @param window [BaseWindow, nil] window to display in
  # @param text [String] message text
  # @return [void]
  # @api private
  def self.show_message(window, text)
    CursesRenderer.doupdate if Feedback.write(window, text, fg: HIGHLIGHT_COLOR)
  end
end
