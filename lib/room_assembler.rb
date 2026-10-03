# frozen_string_literal: true

require_relative 'streams'
require_relative 'room_title'
require_relative 'room_part'
require_relative 'games'

# Assembles the room window's data (title, description, objects, players,
# exits) from the two ways the game sends it, and updates the room players
# indicator.
#
# - The component path: text inside a room component stream (+room objs+,
#   +room exits+, ...), with the links and creatures the tag parser's room
#   marks show (see RoomPart), is emitted as it arrives.
# - The inline path: roomName/roomDesc styled text (captured between
#   {#start_capture} and {#end_capture}, which the tag parser calls) and
#   "You also see" / "Also here:" / "Obvious exits:" lines on main, with
#   the links and creatures their room marks show, are staged, and
#   committed as one batch when the exits arrive.
#
# Component data owns the room it described. A burst runs from a room
# subtitle ({#subtitle}) or a prompt ({#prompt_seen}) to the next prompt,
# whose burst ends when its line does ({#end_line}); the inline commit
# doesn't send again a field a component (or the subtitle, for the title)
# delivered in the burst, and fills the rest, except that a view without a
# roomDesc clears the description (see #commit_view).
#
# UI updates are emitted on the event bus. Every room part this class sends
# to the room window also asks for the window to be rendered at the next
# flush (see {PendingRender#request_room_render}), so a burst of room parts
# is drawn once; for the subtitle the tag parser asks (a room streamWindow)
# or doesn't (a room stream's opening tag, which shows with the next
# render; see TagHandlers#handle_stream_open). The inline commit's clearing
# of Lich's lines asks only when some are shown, so a commit that sends
# nothing new doesn't draw the window again. The window manager is only
# asked whether the layout has a RoomWindow (see #room_window?).
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
  # @param game_rules [Games::Rules] asked whether a room objs component was
  #   cut short (see Games::Rules#room_list_cut_short?); both games' when
  #   the game isn't known
  def initialize(window_mgr:, event_bus:, pending_render:, shared_state:, game_rules: Games::BOTH_GAMES)
    @wm = window_mgr
    @event_bus = event_bus
    @pending_render = pending_render
    @state = shared_state
    @game_rules = game_rules

    @capture_mode = nil
    # Where the description being captured starts in the text handed off
    # (see #start_capture)
    @capture_at = 0
    # The inline view being read, committed when its exits arrive (see
    # #commit_view): field => the title row's text (+:title+) or a
    # RoomPart (+:desc+, +:objects+, +:players+, +:exits+). Only the inline
    # lines write it; the first description and players line stay, the
    # last of the other lines wins.
    @view = {}
    # The fields the components (and the subtitle, for the title) delivered
    # in this burst, which the inline commit doesn't send again (see
    # #commit_view): field => the title row's text or the part
    @delivered = {}
    # After a prompt on the line being parsed: the fields delivered since
    # that prompt, which are all the next burst keeps when the line ends
    # (see #prompt_seen); nil otherwise
    @next_burst = nil
    # Whether Lich's lines (Room Exits, Room Number, StringProcs) are in the
    # room window, for the inline commit, which clears them
    @lich_lines_shown = false
    # Whether the room window shows a room objs list the game cut short,
    # which the inline commit leaves shown when its view has no "You also
    # see" line; until a whole list, the room exits component or the commit
    @cut_objects_shown = false
    # The title row's text last sent to the room window (see #emit), for
    # the inline commit's title rule (see #commit_title) and for
    # #subtitle's new-room test; nil before any
    @title_row = nil
    # The text of the last room subtitle (see #subtitle); nil before any
    @subtitle_row = nil
  end

  # A prompt arrived: it ends the burst when its line ends (see
  # #end_line), so the fields the components delivered are no longer
  # owned from then on (see #commit_view). The prompt tag comes before the
  # line's last text is handed off, so the text on the prompt's line (an
  # exits line's among it) is still read in the burst the prompt ends.
  # What the components deliver after the prompt starts the next burst.
  # What the inline lines staged stays.
  #
  # @return [void]
  def prompt_seen
    @next_burst = {}
  end

  # A server line has been parsed and its text handed off: if a prompt was
  # on it, its burst ends, and only the fields delivered after the prompt
  # stay owned (see #prompt_seen).
  #
  # @return [void]
  def end_line
    @delivered = @next_burst if @next_burst
    @next_burst = nil
  end

  # A room subtitle (a room streamWindow, or a room stream's opening tag,
  # with a subtitle) starts a burst, and delivers the title: show +text+ as
  # the room window's title row. The inline commit then sends the title row
  # again only when its roomName text differs (Lich's room ids).
  #
  # A subtitle that names a new room also clears the exits and objects, so
  # a burst that delivers neither (no room exits or objs component, no
  # inline view) doesn't show the last room's under the new title; the
  # burst's components and inline view fill them as usual. The room is new
  # when +text+ differs both from the last subtitle and from the title row
  # shown: a subtitle re-sent for the room shown clears nothing, when the
  # row shows Lich's form of the roomName (its room id in the name) or a
  # LOOK's roomName before any subtitle too (in either game: GemStone's
  # subtitle and roomName give one text for a room, its room id included;
  # see RoomTitle). An empty name is no title
  # (see TagHandlers#handle_stream_window), so it names no new room.
  # Adjacent rooms of the same name look alike without room ids (DR's
  # showroomid off), and so does a return to the last subtitle's room
  # after a move that sent no subtitle.
  #
  # @param text [String] the title row's text (see {RoomWindow#update_title});
  #   empty for an empty name, which hides the row
  # @return [void]
  def subtitle(text)
    new_room = !text.empty? && text != @subtitle_row && text != @title_row
    @subtitle_row = text
    @delivered = { title: text }
    @next_burst = { title: text } if @next_burst
    emit(:title, text, render: false)
    return unless new_room

    # Drawn with the title, asking for no render of their own
    emit(:objects, EMPTY_PART, render: false)
    emit(:exits, EMPTY_PART, render: false)
  end

  # Start capturing styled text for the room: +:title+ when a roomName
  # style opens, +:desc+ when a roomDesc style or preset opens. The next
  # text {#process_room_data} sees is taken as the room title or
  # description if it is on main; on another stream it only ends the
  # capture.
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
    disarm_capture
  end

  # Process room-related text from inline game text and update RoomWindow
  # data if applicable.
  #
  # Handles title and description via capture mode, "You also see" objects,
  # "Also here:" players, "Obvious paths/exits:" exits, room number, and
  # StringProcs.  The lines are staged as the inline view, which the exits
  # line commits to the RoomWindow (see #commit_view).
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

    # The inline lines are room data only on main: only room text on main
    # names the player's room. Component stream data (room objs, room
    # players, room exits) is handled by process_room_stream instead:
    # reading it here too would consume the text and prevent
    # process_room_stream from running, or, without a RoomWindow, update
    # the room players indicator a second time. Text on any other stream (a
    # familiar's view, a script's window) is that stream's own: a roomName
    # or roomDesc there ends the capture, but sets no terminal title, isn't
    # staged for the room window, and stays in its window.
    unless stream.nil? || stream == Streams::MAIN
      disarm_capture
      return false
    end

    room_data_captured = take_captured_text(text, marks)

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
      @view[:objects] = RoomPart.from_chunk(text, marks)
      room_data_captured = true
    end

    # Detect "Also here:" for players; the view keeps the first one
    if text =~ /^Also here:\s*(.+)$/
      @view[:players] ||= RoomPart.from_chunk(text, marks)
      room_data_captured = true
    end

    # Detect "Obvious paths:" or "Obvious exits:" for exits (game-native)
    if text =~ /^Obvious (?:paths|exits):/
      @view[:exits] = RoomPart.from_chunk(text, marks)
      room_data_captured = true
      # The exits line ends an inline room: commit it (drawn at the next
      # flush)
      commit_view
    end

    # Detect Lich-injected supplemental lines (come after game exits)
    if text =~ /^Room Exits:/
      exits = RoomPart.from_chunk(text, marks)
      show_lich_line(:room_lich_exits, text: exits.text, links: exits.links)
      room_data_captured = true
    elsif text =~ /^Room Number:\s*\S/
      # Any id: "1234", "1234 - (u230008)", or Lich's uid alone, "(u230008)"
      # or "(**)" in a room without one
      show_lich_line(:room_number, text: text.strip)
      room_data_captured = true
    elsif text =~ /^StringProcs:/
      show_lich_line(:room_stringprocs, text: text.strip)
      room_data_captured = true
    end

    room_data_captured
  end

  # Process room-related data arriving via XML component streams.
  #
  # Shows the text of a room component stream (room title, room desc, room
  # objs, room players, room exits) in the RoomWindow at once, and records
  # its field as delivered in this burst (see #commit_view), except a room
  # objs list the game cut short (see Games::Rules#room_list_cut_short?),
  # which leaves the objects to the inline line (and stays shown if the
  # view has none, see #commit_view). An empty component delivers an empty
  # field: it clears it. The room exits component also drops the inline
  # view read so far, and a cut-short list with it.
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

    # Another room stream (DR's room extra) changes nothing in the room
    # window, so it asks for no room render.
    case stream
    when Streams::ROOM, Streams::ROOM_TITLE
      deliver(:title, title)
    when Streams::ROOM_DESC, Streams::ROOM_DESC_ALT
      deliver(:desc, part)
    when Streams::ROOM_OBJS
      if @game_rules.room_list_cut_short?(part.text)
        # A list the game cut short doesn't hold the whole room: it is shown,
        # but the room's inline line (with every object) fills in.
        @delivered.delete(:objects)
        @next_burst&.delete(:objects)
        emit(:objects, part)
        @cut_objects_shown = true
      else
        deliver(:objects, part)
        @cut_objects_shown = false
      end
    when Streams::ROOM_PLAYERS
      deliver(:players, part)
    when Streams::ROOM_EXITS
      deliver(:exits, part)
      @view.clear
      @cut_objects_shown = false
    end

    @pending_render.request_update
    # Don't skip for room players - let the indicator handler also process it
    stream == Streams::ROOM_PLAYERS ? :continue : :consumed
  end

  # Update the 'room players' indicator window with parsed player names.
  #
  # Merges SAX link colors (GemStone <a> tags) with highlights applied to
  # the full "Also here: ..." text, then remaps color regions covering
  # each name to the indicator label. Only highlights that fully cover a
  # name are included -- partial matches create visual noise on a compact
  # indicator display. Asks for a flush, since a player arriving or
  # leaving can be the only change in a burst.
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
    @pending_render.request_update
  end

  private

  # The room window event of each room field.
  FIELD_EVENTS = { title: :room_title, desc: :room_desc, objects: :room_objects, players: :room_players,
                   exits: :room_exits }.freeze
  private_constant :FIELD_EVENTS

  # Send a room field to the room window: the one place the room field
  # events are made, for both carriers.
  #
  # @param field [Symbol] +:title+, +:desc+, +:objects+, +:players+ or +:exits+
  # @param part [String, RoomPart] the title row's text for +:title+, else the part
  # @param render [Boolean] whether to ask for a room render at the next
  #   flush (#subtitle never does; for a room streamWindow the tag parser
  #   asks itself)
  # @return [void]
  def emit(field, part, render: true)
    @title_row = part if field == :title
    data = case field
           when :title then { text: part }
           when :objects then { text: part.text, links: part.links, creatures: part.creatures }
           else { text: part.text, links: part.links }
           end
    @event_bus.emit(FIELD_EVENTS.fetch(field), **data)
    @pending_render.request_room_render if render
  end

  # Show a field a room component delivered, and record it as delivered in
  # this burst (and in the next one, after a prompt on this line; see
  # #prompt_seen), so the inline commit doesn't send it again.
  #
  # @param field [Symbol] the field (see #emit)
  # @param part [String, RoomPart] the title row's text or the part
  # @return [void]
  def deliver(field, part)
    @delivered[field] = part
    @next_burst[field] = part if @next_burst
    emit(field, part)
  end

  # Show one of the lines Lich adds after a room in the room window, asking
  # for the window to be rendered at the next flush (the window only stores
  # the line, so the parts of a burst are drawn once), and note that the
  # window holds Lich lines for the inline commit to clear.
  #
  # @param event [Symbol] +:room_lich_exits+, +:room_number+ or +:room_stringprocs+
  # @param data [Hash] the event's data
  # @return [void]
  def show_lich_line(event, **data)
    @event_bus.emit(event, **data)
    @pending_render.request_room_render
    @lich_lines_shown = true
    @pending_render.request_update
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
  # Called only for text on main (see #process_room_data). The roomName
  # text always updates the terminal title, since it includes the room
  # number in DR (e.g., "[Room] (230008)"). Without a RoomWindow the text
  # is not consumed: it must still flow to the main text window.
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
        @view[:title] = room_title.to_s
        captured = true
      end
    when :desc
      if room_window?
        # The view keeps the first description it read (a later roomDesc
        # before the exits line doesn't replace it)
        @view[:desc] ||= captured_desc(text, marks)
        captured = true
      end
    end
    disarm_capture
    captured
  end

  # End a capture (see {#start_capture}) without taking any text.
  #
  # @return [void]
  def disarm_capture
    @capture_mode = nil
    @capture_at = 0
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

  # Commit the inline view to the RoomWindow, and start a new one.
  #
  # Called by the inline "Obvious paths/exits:" line, which ends an inline
  # room. The other fields are sent only when the view read a title,
  # description, objects or players line, so a lone exits line doesn't
  # clear them.
  #
  # Component data owns the room it described: a field a component (or the
  # subtitle, for the title) delivered in this burst is not sent again (a
  # prompt on the exits line ends the burst after this commit, see
  # #prompt_seen), and the view fills only the fields the burst didn't
  # deliver (a LOOK, brief mode, a room without components). Two fields
  # are exceptions. The title row takes the roomName's text when that
  # differs from the row shown (Lich's room ids, or an earlier view of the
  # burst), so the row and the terminal title name the room alike. A view
  # without a roomDesc clears the description, so the room window follows
  # DR's room description setting (see #commit_desc).
  #
  # A room objs list the game cut short owns nothing, so the view's "You
  # also see" line replaces it; without one the list stays shown, as a
  # staged list was, until this commit.
  #
  # @return [void]
  def commit_view
    view = @view
    @view = {}
    cut_objects_shown = @cut_objects_shown
    @cut_objects_shown = false
    return unless room_window?

    if view.key?(:title) || view.key?(:desc) || view.key?(:objects) || view.key?(:players)
      commit_title(view[:title])

      commit_desc(view[:desc])

      unless @delivered.key?(:objects) || (cut_objects_shown && !view.key?(:objects))
        emit(:objects, view[:objects] || EMPTY_PART)
      end

      unless @delivered.key?(:players)
        emit(:players, view[:players] || EMPTY_PART)
      end

      # Lich's lines go with the room they followed. Clearing them changes
      # the window only when some are shown, so only then is it drawn again.
      @event_bus.emit(:room_supplemental_clear)
      @pending_render.request_room_render if @lich_lines_shown
      @lich_lines_shown = false

      # Also update the room players indicator (fallback for games that
      # don't use streams); players a component delivered updated it already
      update_room_players_indicator(view[:players]&.text) unless @delivered.key?(:players)
    end

    # Update exits on every exits line, unless a component delivered them.
    emit(:exits, view[:exits] || EMPTY_PART) unless @delivered.key?(:exits)
    @pending_render.request_update
  end

  # Send the view's description at the inline commit. The description is
  # the one field the inline view always decides: the room window follows
  # DR's room description setting. A view without a roomDesc (DR leaves it
  # out while room descriptions are off: on a move in brief mode, on the
  # view it sends in place after FLAG DESCRIPTION OFF, on a LOOK) clears
  # the description, even one the room desc component delivered in this
  # burst, which DR sends with every room change whatever the setting.
  # A view with one shows it, unless the burst delivered the description
  # (component data owns the room). A cleared description is no longer
  # the component's, so a later view in the burst (two views with no
  # prompt between) shows its own.
  #
  # @param desc [RoomPart, nil] the view's description; nil without a
  #   roomDesc
  # @return [void]
  def commit_desc(desc)
    if desc.nil?
      emit(:desc, EMPTY_PART)
      @delivered.delete(:desc)
      @next_burst&.delete(:desc)
    elsif !@delivered.key?(:desc)
      emit(:desc, desc)
    end
  end

  # Send the view's title row at the inline commit: the roomName's text,
  # unless the row already shows it; with no roomName, an empty row
  # (hidden) unless this burst delivered a title.
  #
  # When the burst delivered a title, the roomName is compared with the
  # row, not with the delivered title: an earlier view in the burst (two
  # views with no prompt between) may have sent its own roomName, and the
  # roomName sets the terminal title, so the row must follow it.
  #
  # @param title [String, nil] the view's title row text; nil without a
  #   roomName
  # @return [void]
  def commit_title(title)
    if @delivered.key?(:title)
      emit(:title, title) if title && title != @title_row
    else
      emit(:title, title || '')
    end
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
