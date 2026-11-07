# frozen_string_literal: true

require_relative 'presets'

=begin
Familiar window notification extraction.
Detects notable game events and sends summary notifications to the configured notification stream (familiar by default).
=end

# Extracts notable events from game text for display in the familiar window.
#
# Pattern-matches text for events like auction announcements, empathic
# assessments, almanac discoveries, lockbox loot summaries, and script
# status messages, then formats them as short notifications.
#
# Expects the including class to provide:
# - @event_bus   [EventBus]
# - @pending_render [PendingRender]
#
# @api private
module FamiliarNotifier
  # Script status line, e.g. "[combat-trainer: ***STATUS*** Killing a rat]".
  # Script names may contain hyphens and a "custom/" style path prefix.
  # Lines whose status starts with a digit are ignored (countdown chatter).
  STATUS_PATTERN = %r{^\[[\w\-/]+: \*\*\*STATUS\*\*\*\s(?!\d+).*}

  # Check text for notable events and push to the familiar window if found.
  #
  # @param text [String] game text to check
  # @return [void]
  # @api private
  def check_familiar_notification(text)
    note = extract_notification(text)
    return unless note

    colors = if (monsterbold = Presets.colors(Presets::MONSTERBOLD))
               [{ start: 0, end: note.length, **monsterbold }]
             else
               []
             end
    # The notification gets its own color array; @line_colors belongs to
    # the triggering game line and is left alone so that line keeps its
    # tag colors (bold, presets, links) and highlights in main.
    @event_bus.emit(:stream_text, stream: CONFIG.notification_stream, text: note, colors: colors)
    @pending_render.request_update
  end

  private

  # Extract a notification string from game text, or nil if no match.
  #
  # This runs on every displayed line and almost none of them match, so
  # each pattern is tried only when the text contains a word the pattern
  # can't match without. A word is a few bytes of a literal part of its
  # pattern, case and all; Ruby's String#include? checks a word of up to
  # 8 bytes about twice as fast as a longer one, and both much faster than
  # a regexp match. Removing a word only makes its branch slower; a word
  # not in every text its pattern matches would hide that notification.
  #
  # @param text [String] game text
  # @return [String, nil] notification text or nil
  def extract_notification(text)
    if text.include?('STATUS') && text.match?(STATUS_PATTERN)
      text.gsub(%r{(\[|\]|\*\*\*STATUS\*\*\* |EXECUTE |custom/)}, '')
    elsif text.include?('Endlar') && text.match?(/Auctioneer Endlar bangs his gavel and yells, "Bidding is now open/)
      text
    elsif text.include?('waiting') && text.match?(/\w+ just opened the waiting list\./)
      text
    elsif text.include?('nothing') && (match = text.match(/You sense nothing wrong with (?<name>\w+)/))
      "#{match[:name]} is all healthy."
    elsif (text.include?('reaches') || text.include?('politely') || text.include?('next on')) &&
          text.match?(/reaches over and holds|just tried to take your hand, but you politely pulled away|\w+ is next on .* list/)
      text
    elsif text.include?('learned') &&
          (match = text.match(/You believe you've learned something significant about (?<topic>\w+\s?\w*)!$/))
      "Almanac: #{match[:topic]}"
    elsif text.include?('/34 of') &&
          (match = text.match(%r{Tarantula successfully sacrificed (?<count>\d+)/34 of (?<name>\w+\s?\w*) at}))
      "Tarantula: #{match[:name]} #{match[:count]}/34"
    elsif text.include?('complete') && (match = text.match(/contains a complete description of the (?<spell>.*) spell/))
      "Scroll spell: #{match[:spell]}"
    elsif text.include?('the bead') && text.match?(/^You raise the bead up, and a black glow surrounds it/)
      'Focus effect started.'
    elsif text.include?('fades') && text.match?(/^The glow slowly fades away from around you/)
      'Focus effect ended.'
    elsif text.include?('looting') && (match = text.match(/(?<info>Spent .* looting \d+ boxes.)/))
      match[:info]
    elsif text.include?('/34)') &&
          (match = text.match(%r{(?<info>\w+\s?\w*:\s+\d+\s\d+\.\d+%\s\w+\s?\w*\s+\(\d+/34\))}))
      match[:info]
    elsif text.include?('from is') && text.match?(/(?:Character|Longitem)\s+accepting from is/)
      text
    end
  end
end
