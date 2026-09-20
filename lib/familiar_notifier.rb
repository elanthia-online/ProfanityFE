# frozen_string_literal: true

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
# - @line_colors [Array<Hash>]
# - @need_update [Boolean]
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

    colors = if PRESET['monsterbold']
               [{
                 start: 0,
                 end: note.length,
                 fg: PRESET['monsterbold'][0],
                 bg: PRESET['monsterbold'][1]
               }]
             else
               []
             end
    @event_bus.emit(:stream_text, stream: CONFIG.notification_stream, text: note, colors: colors)
    # Preserve existing behavior: clear line colors so the main text
    # display doesn't inherit the notification styling
    @line_colors = []
    @need_update = true
  end

  private

  # Extract a notification string from game text, or nil if no match.
  #
  # @param text [String] game text
  # @return [String, nil] notification text or nil
  def extract_notification(text)
    if text =~ STATUS_PATTERN
      text.gsub(%r{(\[|\]|\*\*\*STATUS\*\*\* |EXECUTE |custom/)}, '')
    elsif text =~ /Auctioneer Endlar bangs his gavel and yells, "Bidding is now open/
      text
    elsif text =~ /\w+ just opened the waiting list\./
      text
    elsif (match = text.match(/You sense nothing wrong with (?<name>\w+)/))
      "#{match[:name]} is all healthy."
    elsif text =~ /reaches over and holds|just tried to take your hand, but you politely pulled away|\w+ is next on .* list/
      text
    elsif (match = text.match(/You believe you've learned something significant about (?<topic>\w+\s?\w*)!$/))
      "Almanac: #{match[:topic]}"
    elsif (match = text.match(%r{Tarantula successfully sacrificed (?<count>\d+)/34 of (?<name>\w+\s?\w*) at}))
      "Tarantula: #{match[:name]} #{match[:count]}/34"
    elsif (match = text.match(/contains a complete description of the (?<spell>.*) spell/))
      "Scroll spell: #{match[:spell]}"
    elsif text =~ /^You raise the bead up, and a black glow surrounds it/
      'Focus effect started.'
    elsif text =~ /^The glow slowly fades away from around you/
      'Focus effect ended.'
    elsif (match = text.match(/(?<info>Spent .* looting \d+ boxes.)/))
      match[:info]
    elsif (match = text.match(%r{(?<info>\w+\s?\w*:\s+\d+\s\d+\.\d+%\s\w+\s?\w*\s+\(\d+/34\))}))
      match[:info]
    elsif text =~ /(?:Character|Longitem)\s+accepting from is/
      text
    end
  end
end
