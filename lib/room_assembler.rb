# frozen_string_literal: true

require_relative 'streams'
require_relative 'room_title'
require_relative 'room_part'

# Assembles the room window's data (title, description, objects, players,
# exits) from the two ways the game sends it, and updates the room players
# indicator.
#
# - The component path: text inside a room component stream (+room objs+,
#   +room exits+, ...), with the links and creatures the tag parser's room
#   marks show (see RoomPart), is emitted as it arrives.
# - The inline path: roomName/roomDesc styled text (captured between
#   {#start_capture} and {#end_capture}, which the tag parser calls) and
#   "You also see" / "Also here:" / "Obvious exits:" lines, with the links
#   and creatures their room marks show, are staged, and committed as one
#   batch when the exits arrive.
#
# UI updates are emitted on the event bus. Every room part this class sends
# to the room window also asks for the window to be rendered at the next
# flush (see {#show_title} and {PendingRender#request_room_render}), so a
# burst of room parts is drawn once. The one room part sent elsewhere is
# the subtitle on a room stream's opening tag
# (TagHandlers#handle_stream_open): it asks for no render and shows with
# the next one. The window manager is only asked whether the layout has a
# RoomWindow (see #room_window?).
class RoomAssembler
  # The part a room field shows when nothing was staged for it: no text.
  EMPTY_PART = RoomPart.new(text: '', links: [], creatures: []).freeze

  # What styled text is being captured for the room: +:title+ (roomName),
  # +:desc+ (roomDesc) or nil. See {#start_capture}: the next text
  # {#process_room_data} sees is captured and ends the capture.
  #
  # @return [Symbol, nil]
  attr_reader :capture_mode

  # @param window_mgr [WindowManager] asked whether the layout has a RoomWindow
  # @param event_bus [EventBus] receives the room and indicator events
  # @param pending_render [PendingRender] asked for flushes and room renders
  # @param shared_state [SharedState] its +room_title+ is set from roomName
  #   text and room title component text
  def initialize(window_mgr:, event_bus:, pending_render:, shared_state:)
    @wm = window_mgr
    @event_bus = event_bus
    @pending_render = pending_render
    @state = shared_state

    @capture_mode = nil
    # Where the description being captured starts in the text handed off
    # (see #start_capture)
    @capture_at = 0
    # Staging for the inline commit when the exits arrive (the components
    # stage here too): the title row's text, and a RoomPart for each other
    # field
    @room_pending_title = nil
    @room_pending_desc = nil
    @room_pending_objects = nil
    @room_pending_players = nil
    @room_pending_exits = nil
    # The room (its SharedState#room_title) the room desc component last
    # described
    @component_desc_room = nil
  end

  # Start capturing styled text for the room: +:title+ when a roomName
  # style opens, +:desc+ when a roomDesc style or preset opens. The next
  # text {#process_room_data} sees is taken as the room title or
  # description.
  #
  # The title also names the room in the terminal title, so it is captured
  # without a room window; the description only with one. Yields before the
  # capture starts, and only if it starts, so the caller can first flush
  # the text before the tag (a roomDesc preset does; a style doesn't, so
  # the main window shows that text with the description, and it says where
  # the description starts instead).
  #
  # @param kind [Symbol] +:title+ or +:desc+
  # @param at [Integer] where the description starts in the text the tag
  #   parser will hand off (the length of the text before a roomDesc style
  #   on its line); the title always takes all of it
  # @yield before the capture starts
  # @return [void]
  def start_capture(kind, at: 0)
    return if kind == :desc && !room_window?

    yield if block_given?
    @capture_mode = kind
    @capture_at = at
  end

  # End a capture of one of +kinds+ (a style or preset closed): yields so
  # the caller can flush the captured text, which {#process_room_data}
  # takes, then disarms the capture even if there was no text (an empty
  # room name or description), or the next line would be taken as the room
  # text. Does nothing when no capture of those kinds is open.
  #
  # @param kinds [Array<Symbol>] the kinds of capture the closing tag ends
  # @yield before the capture ends, to flush its text
  # @return [void]
  def end_capture(*kinds)
    return unless kinds.include?(@capture_mode)

    yield if block_given?
    @capture_mode = nil
    @capture_at = 0
  end

  # Process room-related text from inline game text and update RoomWindow
  # data if applicable.
  #
  # Handles title and description via capture mode, "You also see" objects,
  # "Also here:" players, "Obvious paths/exits:" exits, room number, and
  # StringProcs.  When exits arrive (typically the last component), all
  # pending room data is committed to the RoomWindow atomically.
  #
  # @param text [String] the current line of game text (XML-unescaped)
  # @param stream [String, nil] the stream the text is routed to
  # @param marks [Array<Hash>] the room marks for +text+ (see
  #   SpanTracker::ROOM_MARKS): its links and creatures
  # @return [Boolean] true if this line was consumed by the RoomWindow
  #   (caller should not route it to the main window).  Returns false
  #   when title/desc text is captured for the terminal title but the
  #   template has no RoomWindow — the text must still flow to the
  #   main text window for display.
  def process_room_data(text, stream, marks)
    return false if text.empty?

    room_data_captured = take_captured_text(text, marks)

    # The inline lines are room data only on main. Component stream data
    # (room objs, room players, room exits) is handled by
    # process_room_stream instead: reading it here too would consume the
    # text and prevent process_room_stream from running, or, without a
    # RoomWindow, update the room players indicator a second time. Text on
    # any other stream (a familiar's view, a script's window) is that
    # stream's own, and must not commit a room or leave its window.
    return room_data_captured unless stream.nil? || stream == Streams::MAIN

    # Without a RoomWindow, only update the room players indicator from
    # inline text patterns (objects, exits, etc. are not applicable).
    unless room_window?
      if text =~ /^Also here:\s*(.+)$/
        update_room_players_indicator(text.strip)
      end
      return room_data_captured
    end

    # Detect "You also see" for objects (may have leading whitespace)
    if text =~ /^\s*You also see\b/
      @room_pending_objects = RoomPart.from_chunk(text, marks)
      room_data_captured = true
    end

    # Detect "Also here:" for players
    if text =~ /^Also here:\s*(.+)$/
      # Don't overwrite players the room players component staged
      @room_pending_players ||= RoomPart.from_chunk(text, marks)
      room_data_captured = true
    end

    # Detect "Obvious paths:" or "Obvious exits:" for exits (game-native)
    if text =~ /^Obvious (?:paths|exits):/
      @room_pending_exits = RoomPart.from_chunk(text, marks)
      room_data_captured = true
      # The exits line ends an inline room: commit it (drawn at the next
      # flush)
      commit_room_data_batch
    end

    # Detect Lich-injected supplemental lines (come after game exits)
    if text =~ /^Room Exits:/
      exits = RoomPart.from_chunk(text, marks)
      show(:room_lich_exits, text: exits.text, links: exits.links)
      room_data_captured = true
      @pending_render.request_update
    elsif text =~ /^Room Number:\s*\d+/
      show(:room_number, text: text.strip)
      room_data_captured = true
      @pending_render.request_update
    elsif text =~ /^StringProcs:/
      show(:room_stringprocs, text: text.strip)
      room_data_captured = true
      @pending_render.request_update
    end

    room_data_captured
  end

  # Process room-related data arriving via XML component streams.
  #
  # Dispatches text from room component streams (room title, room desc,
  # room objs, room players, room exits) to the appropriate pending slot
  # and shows it in the RoomWindow. The room exits component clears the
  # pending data; the inline "Obvious paths/exits:" line commits it (see
  # {#process_room_data}).
  #
  # @param text [String] component text content
  # @param stream [String, nil] the current stream
  # @param marks [Array<Hash>] the room marks for +text+ (see
  #   SpanTracker::ROOM_MARKS): its links and creatures
  # @return [Symbol, nil] :consumed if text was fully handled (caller should
  #   return), :continue if caller should keep processing (room players
  #   also needs indicator handling), or nil if not a room stream
  def process_room_stream(text, stream, marks)
    return nil unless stream&.start_with?(Streams::ROOM)

    # The room title names the room in the terminal title, with or without
    # a RoomWindow (as roomName text does).
    if [Streams::ROOM, Streams::ROOM_TITLE].include?(stream)
      parsed = RoomTitle.parse(text)
      title = parsed.to_s
      @state.room_title = parsed.plain if parsed
    end

    # Without a RoomWindow, only handle room players for the indicator
    unless room_window?
      return stream == Streams::ROOM_PLAYERS ? :continue : nil
    end

    part = RoomPart.from_chunk(text, marks)
    links = part.links
    clean = part.text

    # Another room stream (DR's room extra) changes nothing in the room
    # window, so it asks for no room render.
    case stream
    when Streams::ROOM, Streams::ROOM_TITLE
      @room_pending_title = title
      show_title(title)
    when Streams::ROOM_DESC, Streams::ROOM_DESC_ALT
      @room_pending_desc = part
      @component_desc_room = @state.room_title
      show(:room_desc, text: clean, links: links)
    when Streams::ROOM_OBJS
      @room_pending_objects = part
      show(:room_objects, text: clean, links: links, creatures: part.creatures)
    when Streams::ROOM_PLAYERS
      @room_pending_players = part
      show(:room_players, text: clean, links: links)
    when Streams::ROOM_EXITS
      @room_pending_exits = part
      show(:room_exits, text: clean, links: links)
      clear_pending_room_data
    end

    @pending_render.request_update
    # Don't skip for room players - let the indicator handler also process it
    stream == Streams::ROOM_PLAYERS ? :continue : :consumed
  end

  # Show +text+ as the room window's title row, drawn at the next flush.
  #
  # @param text [String] the title row's text (see {RoomWindow#update_title})
  # @return [void]
  def show_title(text)
    show(:room_title, text: text)
  end

  # Update the 'room players' indicator window with parsed player names.
  #
  # Merges SAX link colors (GemStone <a> tags) with highlights applied to
  # the full "Also here: ..." text, then remaps color regions covering
  # each name to the indicator label. Only highlights that fully cover a
  # name are included -- partial matches create visual noise on a compact
  # indicator display.
  #
  # @param players_text [String, nil] raw "Also here:" text or nil
  # @param sax_colors [Array<Hash>] SAX-parsed color regions (link colors)
  # @return [void]
  def update_room_players_indicator(players_text, sax_colors = [])
    names = players_text ? parse_player_names(players_text) : []
    if names.any?
      names_text = names.join(', ')
      full_text = players_text.strip
      full_colors = sax_colors.dup
      HighlightProcessor.apply_highlights(full_text, full_colors)
      label_colors = remap_name_colors(full_text, names, full_colors)
      @event_bus.emit(:indicator_update, id: 'room players', label: names_text, label_colors: label_colors, value: true)
    else
      @event_bus.emit(:indicator_update, id: 'room players', label: ' ', label_colors: nil, value: false)
    end
  end

  private

  # Send a room part to the room window and ask for the window to be
  # rendered at the next flush. The window only stores the part (see
  # {RoomWindow#update_exits}), so the parts of a burst are drawn once.
  #
  # @param event [Symbol] the room event (+:room_desc+, +:room_exits+, ...)
  # @param data [Hash] the event's data
  # @return [void]
  def show(event, **data)
    @event_bus.emit(event, **data)
    @pending_render.request_room_render
  end

  # Whether the layout has a RoomWindow.
  #
  # @return [Boolean]
  def room_window?
    !@wm.room[Streams::ROOM].nil?
  end

  # Take text as the room title or description if a capture is open (see
  # {#start_capture}), and end the capture.
  #
  # The roomName text always updates the terminal title, since it includes
  # the room number in DR (e.g., "[Room] (230008)"). Without a RoomWindow
  # the text is not consumed: it must still flow to the main text window.
  #
  # @param text [String] non-empty game text
  # @param marks [Array<Hash>] the room marks for +text+
  # @return [Boolean] whether the text was captured for the RoomWindow
  def take_captured_text(text, marks)
    captured = false
    case @capture_mode
    when :title
      room_title = RoomTitle.parse(text)
      @state.room_title = room_title.plain if room_title
      if room_window?
        @room_pending_title = room_title.to_s
        captured = true
      end
    when :desc
      if room_window?
        # Don't overwrite a description the room desc component staged
        @room_pending_desc ||= captured_desc(text, marks)
        captured = true
      end
    end
    @capture_mode = nil
    @capture_at = 0
    captured
  end

  # The description a roomDesc capture takes from +text+: the text from
  # where the capture started (see #start_capture), with its links. When
  # nothing follows that (a roomDesc style with no text after it), the
  # whole of +text+, without links, as the description has always been
  # then; text of only spaces is an empty description.
  #
  # @param text [String] non-empty game text
  # @param marks [Array<Hash>] the room marks for +text+
  # @return [RoomPart]
  def captured_desc(text, marks)
    return RoomPart.new(text: text.strip, links: [], creatures: []) if text.length <= @capture_at

    RoomPart.from_chunk(text, marks, from: @capture_at)
  end

  # Reset all pending room data slots to nil.
  #
  # @return [void]
  def clear_pending_room_data
    @room_pending_title = nil
    @room_pending_desc = nil
    @room_pending_objects = nil
    @room_pending_players = nil
    @room_pending_exits = nil
  end

  # Extract player names from "Also here: ..." room text.
  # Strips status descriptions, titles, and grouping to return bare names.
  #
  # @param text [String] raw "Also here: ..." line from the game
  # @return [Array<String>] list of player names
  # @api private
  def parse_player_names(text)
    text.sub(/^Also here:\s*/, '')
        .sub(/\.\s*$/, '')
        .sub(/ and (?<rest>.*)$/) { ", #{Regexp.last_match[:rest]}" }
        .split(', ')
        .map { |obj| obj.sub(/ (who|whose body)? ?(has|is|appears|glows) .+/, '').sub(/ \(.+\)/, '') }
        .map { |obj| obj.strip.scan(/\w+$/).first }
        .compact
  end

  # Commit all pending room data to the RoomWindow and clear the staging area.
  #
  # Called by the inline "Obvious paths/exits:" line, which ends an inline
  # room. Only commits if there is actual pending data to avoid
  # double-updates that would clear previously committed data.
  #
  # @return [void]
  def commit_room_data_batch
    return unless room_window?

    # Save exits before clearing — clear_pending_room_data wipes all
    # pending fields, but exits are emitted separately after the batch.
    exits = @room_pending_exits || EMPTY_PART

    # Only update if we have pending data (avoid double-updates clearing data)
    if @room_pending_title || @room_pending_desc || @room_pending_objects || @room_pending_players
      show_title(@room_pending_title || '')

      # Without a roomDesc (DR leaves it out when room descriptions are off,
      # and so does a brief LOOK) the lines keep the description the room
      # desc component, sent with every room change, gave this room. A room
      # the component didn't describe gets none, not the last room's.
      if @room_pending_desc || @component_desc_room != @state.room_title
        desc = @room_pending_desc || EMPTY_PART
        show(:room_desc, text: desc.text, links: desc.links)
      end

      objects = @room_pending_objects || EMPTY_PART
      show(:room_objects, text: objects.text, links: objects.links, creatures: objects.creatures)

      players = @room_pending_players || EMPTY_PART
      show(:room_players, text: players.text, links: players.links)

      show(:room_supplemental_clear)

      # Also update the room players indicator (fallback for games that don't use streams)
      update_room_players_indicator(@room_pending_players&.text)

      clear_pending_room_data
    end

    # Always update exits (even on subsequent exit lines).
    show(:room_exits, text: exits.text, links: exits.links)
    @pending_render.request_update
  end

  # Map highlight color regions from full players text to indicator label positions.
  #
  # @param full_text [String] the full "Also here: ..." text
  # @param names [Array<String>] parsed player names
  # @param full_colors [Array<Hash>] highlight regions for the full text
  # @return [Array<Hash>] color regions remapped to the names-only label
  def remap_name_colors(full_text, names, full_colors)
    return [] if full_colors.empty?

    label_colors = []
    label_pos = 0
    search_pos = 0

    names.each_with_index do |name, i|
      name_start = full_text.index(name, search_pos)
      next unless name_start
      name_end = name_start + name.length
      search_pos = name_end

      full_colors.each do |c|
        # Only include highlights that fully cover the name -- partial
        # matches create visual noise on a compact indicator display.
        next unless c[:start] <= name_start && c[:end] >= name_end

        label_colors << {
          start: label_pos,
          end: label_pos + name.length,
          fg: c[:fg],
          bg: c[:bg],
          ul: c[:ul]
        }
      end

      label_pos += name.length
      label_pos += 2 if i < names.length - 1 # ", " separator
    end

    label_colors
  end
end
