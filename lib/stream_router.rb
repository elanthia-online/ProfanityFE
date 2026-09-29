# frozen_string_literal: true

require_relative 'streams'
require_relative 'presets'
require_relative 'styled_text'
require_relative 'clock'
require_relative 'games'

# Knows which stream game text belongs to, and sends each line of text to
# its window, or to main when the stream has no window.
#
# Owns:
# - the current stream and the stack of open pushStreams (#102): only a
#   pushStream nests, a popStream returns to the stream below it (matching
#   its id when it has one), and a <prompt> closes everything left open;
# - combat routing: after a combat pushStream, text after an unrecognized
#   tag goes to combat until the next popStream;
# - routing a line: highlights, the combat gag, LNet chat to the lnet
#   window, room components (handed to the {RoomAssembler}), the death,
#   logon, timestamp and spell-window formats, and the fallback to main.
class StreamRouter
  # Most pushStreams tracked as open at once. The deepest real nesting is
  # two (the empath familiar double push); the cap only stops unmatched
  # pushes from piling up between prompts.
  MAX_STREAM_DEPTH = 8

  # The stream text is being routed to; nil for main.
  #
  # @return [String, nil]
  attr_reader :current_stream

  # @param window_mgr [WindowManager] asked which streams have a window
  # @param event_bus [EventBus] receives +:stream_text+
  # @param pending_render [PendingRender] asked for a flush when text is shown
  # @param prompts [PromptTracker] shows a pending prompt before main text,
  #   and drops the game's main copy of stream text
  # @param room [RoomAssembler] takes the text of room component streams
  # @param game_rules [Games::Rules] the death, logon and spell-name rules
  # @param clock [Clock] read for the death/logon time and speech timestamps
  # @param speech_timestamps [Boolean] timestamp the lines of the streams in
  #   {Streams::TIMESTAMPED_IN_WINDOW} and {Streams::TIMESTAMPED_IN_MAIN}
  def initialize(window_mgr:, event_bus:, pending_render:, prompts:, room:, game_rules: Games::BOTH_GAMES,
                 clock: Clock.new, speech_timestamps: false)
    @wm = window_mgr
    @event_bus = event_bus
    @pending_render = pending_render
    @prompts = prompts
    @room = room
    @game_rules = game_rules
    @clock = clock
    @speech_timestamps = speech_timestamps

    @current_stream = nil
    # Open pushStreams, innermost last; a pop returns to the one below
    # (see #close_stream). Cleared at every <prompt>.
    @stream_stack = []
    # Set by a combat stream, cleared by any popStream (see #combat_routing?)
    @combat_next_line = nil
  end

  # ---- Stream state, driven by the tag parser ----

  # Switch to a stream opened by a <pushStream>, <component> or <compDef>.
  #
  # Only a +<pushStream>+ is recorded as open, so a later pop can return
  # to it. A component or compDef (including a self-closing
  # +<component id='…'/>+) only switches the current stream: nothing a pop
  # could later restore.
  #
  # @param stream [String] the stream switched to
  # @param push [Boolean] whether the tag was a pushStream
  # @return [void]
  def open_stream(stream, push:)
    @current_stream = stream
    push_open_stream(stream) if push
    @combat_next_line = true if stream == Streams::COMBAT
  end

  # Close the current stream (a popStream, </component> or </compDef>) and
  # return to the innermost pushStream still open (main when none is).
  #
  # A +<popStream>+ first closes its pushStream on the stack (see
  # {#pop_open_stream}); a component or compDef close leaves the stack
  # alone. So after a nested push/pop the outer stream's remaining text
  # keeps going to the outer stream instead of spilling into main.
  #
  # @param pop [Boolean] whether the tag was a popStream
  # @param id [String, nil] the popStream's +id+ attribute
  # @return [void]
  def close_stream(pop:, id: nil)
    pop_open_stream(id) if pop
    @current_stream = @stream_stack.last
  end

  # Whether text after an unrecognized tag goes to the combat stream: a
  # combat stream was opened and no popStream has been seen since.
  #
  # @return [Boolean, nil]
  def combat_routing?
    @combat_next_line
  end

  # End combat routing: any popStream, bare or with an id, does. A combat
  # block closed by a bare <popStream/> must not leave later unrecognized
  # tags routed to combat.
  #
  # @return [void]
  def end_combat_routing
    @combat_next_line = false
  end

  # Route to the combat stream (an unrecognized tag while combat routing).
  #
  # @return [void]
  def switch_to_combat
    @current_stream = Streams::COMBAT
  end

  # Whether a <prompt> has anything to resynchronize: a stream, an open
  # pushStream or combat routing left over.
  #
  # @return [Boolean]
  def resync_needed?
    !(@current_stream.nil? && @stream_stack.empty? && !@combat_next_line)
  end

  # Resynchronize stream routing at a <prompt>.
  #
  # The game only sends a prompt in main-window context, so any stream
  # still open there was never closed (a dropped or missing pop). Close
  # them all: empty the stack and route to main. This is the resync point
  # that keeps one unmatched push from misrouting text for the rest of the
  # session. The tag parser first flushes the text already collected for
  # the stale stream to it.
  #
  # @return [void]
  def resync
    @stream_stack.clear
    @current_stream = nil
    @combat_next_line = false
  end

  # ---- Routing ----

  # Whether text on the current stream is shown somewhere, and so gets
  # highlights: main, a stream with a window, or one that falls back to main.
  #
  # @return [Boolean]
  def routable?
    @current_stream.nil? || !@wm.stream[@current_stream].nil? || Streams::FALLBACK_TO_MAIN.include?(@current_stream)
  end

  # Send a chunk of game text to the current stream's window, or to main.
  #
  # Applies the highlights first when the stream is shown ({#routable?}).
  # Blank text is not shown.
  #
  # @param text [String] game text, tags removed and entities unescaped
  # @param colors [Array<Hash>] the line's color regions (highlights are
  #   added to this array)
  # @param room_captured [Boolean] whether the room assembler captured the
  #   line from main text (its leading space is dropped, and it isn't indented)
  # @return [void]
  def route(text, colors, room_captured: false)
    # Apply highlight patterns to all routable streams
    HighlightProcessor.apply_highlights(text, colors) if routable?
    return if text.strip.empty?

    if @current_stream
      route_stream_text(text, colors)
    elsif @wm.stream[MAIN_STREAM]
      route_main_text(text, colors, room_captured)
    end
  end

  private

  # Record a pushStream as open, dropping the oldest entry beyond
  # {MAX_STREAM_DEPTH} so unmatched pushes can't accumulate.
  #
  # @param stream [String] the stream the push switched to
  # @return [void]
  # @api private
  def push_open_stream(stream)
    @stream_stack.push(stream)
    @stream_stack.shift while @stream_stack.length > MAX_STREAM_DEPTH
  end

  # Close a pushStream on the stack.
  #
  # With an id that is open, close the innermost stream with that id and
  # discard anything opened after it (an inner push that never got its
  # pop). With no id, or an id that isn't open, close the innermost stream.
  # An empty stack stays empty.
  #
  # @param id [String, nil] the popStream's +id+ attribute
  # @return [void]
  # @api private
  def pop_open_stream(id)
    index = id && @stream_stack.rindex(id)
    if index
      @stream_stack.slice!(index..)
    else
      @stream_stack.pop
    end
  end

  # Route text on a stream: gag combat, move LNet chat, hand room
  # components to the room assembler, then show it in the stream's window
  # or fall back to main.
  #
  # @param text [String] non-blank game text
  # @param colors [Array<Hash>] its color regions
  # @return [void]
  # @api private
  def route_stream_text(text, colors)
    return if @current_stream == Streams::COMBAT && text.match(GagPatterns.combat_regexp)

    # LNet chat arrives on the thoughts stream. Move it to the lnet window
    # only when the layout has one; otherwise it stays on thoughts, which
    # falls back to main when there is no thoughts window either.
    if @current_stream == Streams::THOUGHTS && @wm.stream[Streams::LNET] && (text =~ /^\[.+?\]-[A-Za-z]+:[A-Z][a-z]+: "|^\[server\]: /)
      @current_stream = Streams::LNET
    end

    # Handle room components for dedicated RoomWindow
    room_result = @room.process_room_stream(text, @current_stream, colors)
    if room_result == :consumed
      return
    elsif room_result == :continue
      # Room players: also update the indicator, then stop
      @room.update_room_players_indicator(text, colors)
      return
    end

    if @wm.stream[@current_stream]
      to_stream_window(text, colors)
    elsif Streams::FALLBACK_TO_MAIN.include?(@current_stream)
      to_main_as_fallback(text, colors)
    end
  end

  # Show text in the current stream's window, in the stream's format.
  #
  # @param text [String] game text
  # @param colors [Array<Hash>] its color regions
  # @return [void]
  # @api private
  def to_stream_window(text, colors)
    if @current_stream == Streams::DEATH
      # "HH:MM Name ..." (e.g. DR "Name MF", GS "Name AREA"); an
      # empty entry hides the line (GS vaporized/incinerated)
      if (entry = @game_rules.death_summary(text))
        if entry.empty?
          text = ''
        else
          text, colors = time_prefixed(entry, 'ff0000')
        end
      end
    elsif @current_stream == Streams::LOGONS
      if (logon = @game_rules.logon(text))
        name, fg = logon
        text, colors = time_prefixed(name, fg)
      end
    elsif Streams::TIMESTAMPED_IN_WINDOW.include?(@current_stream) && @speech_timestamps
      text = append_speech_timestamp(text)
    end

    text, colors = shorten_spell_line(text, colors) if @current_stream == Streams::PERC
    return if text =~ /^\[server\]: "(?:kill|connect)/

    @event_bus.emit(:stream_text, stream: @current_stream, text: text, colors: colors)
    @pending_render.request_update
    # Remembered so the game's main copy of it, if next, is dropped
    @prompts.stream_text_sent(text)
  end

  # Show text of a stream without a window in main (see
  # {Streams::FALLBACK_TO_MAIN}), in the stream's preset colors.
  #
  # @param text [String] game text
  # @param colors [Array<Hash>] its color regions
  # @return [void]
  # @api private
  def to_main_as_fallback(text, colors)
    # Timestamp thoughts/familiar when --speech-ts is active (not speech:
    # see Streams::TIMESTAMPED_IN_MAIN)
    if Streams::TIMESTAMPED_IN_MAIN.include?(@current_stream) && @speech_timestamps
      text = append_speech_timestamp(text)
    end
    if (preset = Presets.colors(@current_stream))
      colors.push(start: 0, **preset, end: text.length)
    end
    return if text.empty?

    # Detect movement in stream content too
    @prompts.movement_seen if @prompts.movement?(text)
    @prompts.emit_prompt_if_needed
    @event_bus.emit(:stream_text, stream: MAIN_STREAM, text: text, colors: colors)
    @pending_render.request_update
    # Shown in main, so it is the next main-bound line: the stored
    # stream-window text expires. Not compared: this is stream text
    # itself, never the game's main copy of a stream line.
    @prompts.forget_stream_text
  end

  # Show main-window text, unless it is the game's copy of the line just
  # sent to a stream window.
  #
  # @param text [String] non-blank game text
  # @param colors [Array<Hash>] its color regions
  # @param room_captured [Boolean] whether the room assembler captured it
  # @return [void]
  # @api private
  def route_main_text(text, colors, room_captured)
    # Drop the game's main copy of the line just sent to a stream window.
    return if @prompts.stream_text_copy?(text)

    # Detect movement messages to suppress following prompts/empty lines
    is_movement = @prompts.movement?(text)
    @prompts.emit_prompt_if_needed

    # Strip leading whitespace from room-captured text (e.g., "  You also see..."
    # left after description extraction from the same server line)
    if room_captured
      styled = StyledText.new(text, colors).lstrip
      text = styled.text
      colors = styled.runs
    end
    @event_bus.emit(:stream_text, stream: MAIN_STREAM, text: text, colors: colors, indent: room_captured ? false : nil)
    @pending_render.request_update
    @prompts.movement_seen if is_movement
  end

  # Shorten a spell-window line: the configured transforms, the game's
  # spell abbreviation and single spaces. The color runs already on it
  # (tag colors and the highlights applied to the text as sent) move with
  # the text they color, so a highlight on a full spell name colors its
  # abbreviation.
  #
  # @param text [String] the line as sent
  # @param colors [Array<Hash>] its color regions
  # @return [Array(String, Array<Hash>)] the shortened line and its runs
  # @api private
  def shorten_spell_line(text, colors)
    styled = StyledText.new(text, colors)

    # Apply configurable text transformations from XML
    # Example: <perc-transform pattern=" (roisaen|roisan)" replace=""/>
    PERC_TRANSFORMS.each do |pattern, replacement|
      styled = styled.sub(pattern, replacement)
    end

    paren_pos = styled.text.index('(')
    if paren_pos && paren_pos > 1
      spell_name = styled.text[0..paren_pos - 2]
      # Shorten spell names
      short_name = @game_rules.spell_abbreviation(spell_name)
      styled = styled.sub(/^#{Regexp.escape(spell_name)}/, short_name) if short_name
    end

    styled = styled.gsub(/  /, ' ').strip
    text = styled.text
    colors = styled.runs

    # Highlights that match the shortened text (e.g. on "POM" or on a
    # transform's "Cyclic"); skip runs already carried over.
    HighlightProcessor.apply_highlights(text, []).each do |run|
      colors.push(run) unless colors.include?(run)
    end

    if (preset = Presets.colors(@current_stream))
      colors.push(start: 0, **preset, end: text.length)
    end
    [text, colors]
  end

  # Append a speech timestamp to text (e.g., "Hello (3:45:12)").
  #
  # @param text [String] the text to append to
  # @return [String] text with appended timestamp
  # @api private
  def append_speech_timestamp(text)
    "#{text} (#{@clock.h_mm_ss})"
  end

  # A death or logon line: +rest+ after the current time (HH:MM), with the
  # line's highlights and the time drawn in +fg+.
  #
  # @param rest [String] the text after the time, e.g. the character's name
  # @param fg [String] hex foreground color of the time
  # @return [Array(String, Array<Hash>)] the line, e.g. "14:35 Mahtra", and
  #   its color regions (replacing the line's own)
  # @api private
  def time_prefixed(rest, fg)
    timestamp = @clock.hh_mm
    text = "#{timestamp} #{rest}"
    colors = HighlightProcessor.apply_highlights(text, [])
    colors.push({ start: 0, end: timestamp.length, fg: fg })
    [text, colors]
  end
end
