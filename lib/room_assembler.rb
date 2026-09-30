# frozen_string_literal: true

require_relative 'xml_tokenizer'
require_relative 'streams'
require_relative 'presets'
require_relative 'link_extractor'
require_relative 'room_title'

# Assembles the room window's data (title, description, objects, players,
# exits) from the two ways the game sends it, and updates the room players
# indicator.
#
# - The component path: text inside a room component stream (+room objs+,
#   +room exits+, ...), with the link and bold regions the tag parser
#   computed, is emitted as it arrives.
# - The inline path: roomName/roomDesc styled text (captured between
#   {#start_capture} and {#end_capture}, which the tag parser calls) and
#   "You also see" / "Also here:" / "Obvious exits:" lines are staged, from
#   the raw line so their markup is kept, and committed as one batch when
#   the exits arrive.
#
# UI updates are emitted on the event bus. The window manager is only asked
# whether the layout has a RoomWindow (see #room_window?).
class RoomAssembler
  # Element names of the tags stripped from inline "You also see" text.
  COMPONENT_TAGS = %w[component compDef].freeze

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
    # Inline-path staging, committed as one batch when the exits arrive
    @room_pending_title = nil
    @room_pending_desc = nil
    @room_pending_objects = nil
    @room_pending_players = nil
    @room_pending_exits = nil
    # The room (its SharedState#room_title) the room desc component last
    # described
    @component_desc_room = nil
    # Raw line with XML tags preserved for room object extraction
    @current_raw_line = nil
  end

  # Start capturing styled text for the room: +:title+ when a roomName
  # style opens, +:desc+ when a roomDesc style or preset opens. The next
  # text {#process_room_data} sees is taken as the room title or
  # description.
  #
  # The title also names the room in the terminal title, so it is captured
  # without a room window; the description only with one. Yields before the
  # capture starts, and only if it starts, so the caller can first flush
  # the text before the tag (a roomDesc preset does; a style doesn't).
  #
  # @param kind [Symbol] +:title+ or +:desc+
  # @yield before the capture starts
  # @return [void]
  def start_capture(kind)
    return if kind == :desc && !room_window?

    yield if block_given?
    @capture_mode = kind
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
  end

  # Start a new server line: the inline path reads room markup from it.
  #
  # @param raw_line [String] the server line, tags intact
  # @return [void]
  def line_started(raw_line)
    @current_raw_line = raw_line
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
  # @return [Boolean] true if this line was consumed by the RoomWindow
  #   (caller should not route it to the main window).  Returns false
  #   when title/desc text is captured for the terminal title but the
  #   template has no RoomWindow — the text must still flow to the
  #   main text window for display.
  def process_room_data(text, stream)
    return false if text.empty?

    room_data_captured = take_captured_text(text)

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
      # Extract from raw line to preserve <pushBold/> tags for RoomWindow creature highlighting.
      # Use regex here (not REXML) since inline text isn't inside a component element.
      @room_pending_objects = if @current_raw_line && (match = @current_raw_line.match(/You also see\b.*/))
                                strip_component_tags(match[0]).strip
                              else
                                text.strip
                              end
      room_data_captured = true
    end

    # Detect "Also here:" for players
    if text =~ /^Also here:\s*(.+)$/
      # Don't overwrite if already set by component stream (preserves raw XML for links)
      @room_pending_players = text.strip unless @room_pending_players
      room_data_captured = true
    end

    # Detect "Obvious paths:" or "Obvious exits:" for exits (game-native)
    if text =~ /^Obvious (?:paths|exits):/
      # Use raw line to preserve <d>/<a> tags for link processing in room window
      @room_pending_exits = if @current_raw_line && (match = @current_raw_line.match(/Obvious (?:paths|exits):.*/))
                              match[0].strip
                            else
                              text.strip
                            end
      room_data_captured = true
      # Trigger room render since exits are typically last
      commit_room_data_batch
    end

    # Detect Lich-injected supplemental lines (come after game exits)
    if text =~ /^Room Exits:/
      raw = if @current_raw_line && (match = @current_raw_line.match(/Room Exits:.*/))
              match[0].strip
            else
              text.strip
            end
      @event_bus.emit(:room_lich_exits, text: raw)
      room_data_captured = true
      @pending_render.request_update
    elsif text =~ /^Room Number:\s*\d+/
      @event_bus.emit(:room_number, text: text.strip)
      room_data_captured = true
      @pending_render.request_update
    elsif text =~ /^StringProcs:/
      @event_bus.emit(:room_stringprocs, text: text.strip)
      room_data_captured = true
      @pending_render.request_update
    end

    room_data_captured
  end

  # Process room-related data arriving via XML component streams.
  #
  # Dispatches text from room component streams (room title, room desc,
  # room objs, room players, room exits) to the appropriate pending slot.
  # When exits arrive, commits all pending data to the RoomWindow.
  #
  # @param text [String] component text content
  # @param stream [String, nil] the current stream
  # @param line_colors [Array<Hash>] the color regions the tag parser
  #   computed for +text+ (links carry +:cmd+)
  # @return [Symbol, nil] :consumed if text was fully handled (caller should
  #   return), :continue if caller should keep processing (room players
  #   also needs indicator handling), or nil if not a room stream
  def process_room_stream(text, stream, line_colors)
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

    # Extract pre-computed link regions from SAX-parsed line_colors.
    # These have correct positions relative to `text` (the clean text
    # buffer) and include :cmd for click dispatch. Creature bold regions
    # are also extracted from line_colors for the objects section.
    #
    # Adjust positions for leading whitespace that .strip removes,
    # since SAX positions are relative to the original text buffer.
    left_offset = text.length - text.lstrip.length
    links = extract_sax_links(line_colors, left_offset)
    clean = text.strip

    case stream
    when Streams::ROOM, Streams::ROOM_TITLE
      @room_pending_title = title
      @event_bus.emit(:room_title, text: title)
    when Streams::ROOM_DESC, Streams::ROOM_DESC_ALT
      @room_pending_desc = clean
      @component_desc_room = @state.room_title
      @event_bus.emit(:room_desc, text: clean, links: links)
    when Streams::ROOM_OBJS
      creatures = extract_sax_creatures(line_colors, text, left_offset)
      @room_pending_objects = clean
      @event_bus.emit(:room_objects, text: clean, links: links, creatures: creatures)
    when Streams::ROOM_PLAYERS
      @room_pending_players = clean
      @event_bus.emit(:room_players, text: clean, links: links)
    when Streams::ROOM_EXITS
      @room_pending_exits = clean
      @event_bus.emit(:room_exits, text: clean, links: links)
      clear_pending_room_data
    end

    # Defer room window render to the IO.select flush point to reduce
    # curses operation frequency (update_exits already renders internally)
    @pending_render.request_room_render unless stream == Streams::ROOM_EXITS

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
  # @return [Boolean] whether the text was captured for the RoomWindow
  def take_captured_text(text)
    captured = false
    case @capture_mode
    when :title
      room_title = RoomTitle.parse(text)
      @state.room_title = room_title.plain if room_title
      if room_window?
        @room_pending_title = room_title.to_s
        captured = true
      end
      @capture_mode = nil
    when :desc
      if room_window?
        # Don't overwrite if already set by component stream (preserves raw XML for links)
        unless @room_pending_desc
          # Extract from raw line to preserve <d>/<a> link tags for room window.
          raw_desc = extract_styled_desc(@current_raw_line) if @current_raw_line
          @room_pending_desc = (raw_desc || text).strip
        end
        captured = true
      end
      @capture_mode = nil
    end
    captured
  end

  # Extract link regions from SAX-computed line colors.
  # Returns only color regions that have a :cmd key (clickable links),
  # stripping color info (the room window applies its own link preset).
  # Adjusts positions by the given offset (for leading whitespace removed by .strip).
  #
  # @param line_colors [Array<Hash>] the tag parser's color regions
  # @param offset [Integer] number of chars stripped from the left of the text
  # @return [Array<Hash>] `[{start:, end:, cmd:}, ...]`
  def extract_sax_links(line_colors, offset = 0)
    line_colors.select { |c| c[:cmd] }.map do |c|
      { start: c[:start] - offset, end: c[:end] - offset, cmd: c[:cmd] }
    end
  end

  # Extract creature names from monsterbold regions in SAX-computed line colors.
  # Finds color regions that match the monsterbold preset and extracts the
  # corresponding text from the stripped clean text.
  #
  # @param line_colors [Array<Hash>] the tag parser's color regions
  # @param text [String] original text (SAX text buffer, before strip)
  # @param offset [Integer] left strip offset applied to produce clean text
  # @return [Array<String>] creature names
  def extract_sax_creatures(line_colors, text, offset = 0)
    monsterbold = Presets.colors(Presets::MONSTERBOLD)
    return [] unless monsterbold

    stripped = text.strip
    line_colors.select { |c| c[:fg] == monsterbold[:fg] && c[:bg] == monsterbold[:bg] && !c[:cmd] }
               .filter_map { |c| stripped[(c[:start] - offset)...(c[:end] - offset)]&.strip }
               .reject(&:empty?)
               .uniq
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

  # Extract the raw roomDesc content from a styled text line.
  # Preserves <d>/<a> link tags that would otherwise be stripped by tag handlers.
  #
  # @param raw_line [String] the full raw server line
  # @return [String, nil] raw description content, or nil if not found
  def extract_styled_desc(raw_line)
    segments = XmlTokenizer.tokenize(raw_line)
    # DR: <style id="roomDesc"/>...content...<style id=""/> (or the line's end)
    desc = text_between(segments, ->(tag) { id_tag?(tag, 'style', Presets::ROOM_DESC) }, ->(tag) { id_tag?(tag, 'style', '') })
    return desc if desc

    # GS/alt: <preset id='roomDesc'>...content...</preset>
    text_between(segments, ->(tag) { id_tag?(tag, 'preset', Presets::ROOM_DESC) && !tag.end_with?('/>') },
                 ->(tag) { tag == '</preset>' }, close_required: true)
  end

  # Whether a tag is an opening or self-closing +name+ tag whose id is +id+.
  #
  # @param tag [String] a tag segment from {XmlTokenizer.tokenize}
  # @param name [String] the element name
  # @param id [String] the id attribute's value
  # @return [Boolean]
  def id_tag?(tag, name, id)
    !tag.start_with?('</') && XmlTokenizer.tag_name(tag) == name && XmlTokenizer.attrs(tag)['id'] == id
  end

  # The raw text, tags kept, from just after the first opening tag up to the
  # closing tag that follows it.
  #
  # @param segments [Array<Array(Symbol, String)>] a line, from {XmlTokenizer.tokenize}
  # @param opening [Proc] whether a tag is the opening tag
  # @param closing [Proc] whether a tag is the closing tag
  # @param close_required [Boolean] when false, the line's end also closes
  # @return [String, nil] the text, or nil if there is no opening tag, no
  #   closing tag where one is required, or no text between them
  def text_between(segments, opening, closing, close_required: false)
    start = segments.index { |type, s| type == :tag && opening.call(s) }
    return unless start

    rest = segments.drop(start + 1)
    stop = rest.index { |type, s| type == :tag && closing.call(s) }
    return if stop.nil? && close_required

    text = rest.take(stop || rest.length).map(&:last).join
    text unless text.empty?
  end

  # Convert raw XML text to structured data: clean text + link regions.
  # Used by the inline path (commit_room_data_batch) where pending data
  # may contain raw XML from @current_raw_line.
  #
  # @param raw_text [String] text potentially containing XML tags
  # @return [Array(String, Array<Hash>)] [clean_text, `[{start:, end:, cmd:}, ...]`]
  def structurize_text(raw_text)
    return [raw_text, []] if raw_text.empty?

    clean, colors = LinkExtractor.extract_links(raw_text, links_enabled: true)
    links = colors.map { |c| { start: c[:start], end: c[:end], cmd: c[:cmd] } }
    [clean.strip, links]
  end

  # Extract creature names from pushBold regions in raw XML text.
  # Used by the inline path where SAX bold tracking isn't available.
  #
  # A region runs from a <pushBold/> to the next <popBold/>; its text, with
  # any tags inside it removed, is a creature name.
  #
  # @param raw_text [String] raw objects text with XML bold tags
  # @return [Array<String>] creature names, each once, in order
  def extract_inline_creatures(raw_text)
    creatures = []
    name = nil
    XmlTokenizer.tokenize(raw_text, paired: false).each do |type, segment|
      if type == :text
        name&.<<(segment)
      elsif (tag = XmlTokenizer.start_tag_name(segment)) == 'pushBold'
        name ||= String.new(encoding: raw_text.encoding)
      elsif tag == 'popBold' && name
        creatures << name.strip
        name = nil
      end
    end
    creatures.reject(&:empty?).uniq
  end

  # Remove component and compDef start and end tags from raw text, keeping
  # every other tag and all the text.
  #
  # @param raw_text [String] raw text with XML tags
  # @return [String] the text without component/compDef tags
  def strip_component_tags(raw_text)
    XmlTokenizer.tokenize(raw_text, paired: false)
                .reject { |type, segment| type == :tag && COMPONENT_TAGS.include?(XmlTokenizer.tag_name(segment)) }
                .map(&:last)
                .join
  end

  # Commit all pending room data to the RoomWindow and clear the staging area.
  #
  # Called when exits arrive (the last expected room component). Only commits
  # if there is actual pending data to avoid double-updates that would clear
  # previously committed data.
  #
  # @return [void]
  def commit_room_data_batch
    return unless room_window?

    # Save exits before clearing — clear_pending_room_data wipes all
    # pending fields, but exits are emitted separately after the batch.
    exits_raw = @room_pending_exits || ''

    # Only update if we have pending data (avoid double-updates clearing data)
    if @room_pending_title || @room_pending_desc || @room_pending_objects || @room_pending_players
      @event_bus.emit(:room_title, text: @room_pending_title || '')

      # Inline path stores raw XML — convert to structured data at emission time.
      # Without a roomDesc (DR leaves it out when room descriptions are off,
      # and so does a brief LOOK) the lines keep the description the room
      # desc component, sent with every room change, gave this room. A room
      # the component didn't describe gets none, not the last room's.
      if @room_pending_desc || @component_desc_room != @state.room_title
        desc_clean, desc_links = structurize_text(@room_pending_desc || '')
        @event_bus.emit(:room_desc, text: desc_clean, links: desc_links)
      end

      obj_raw = @room_pending_objects || ''
      obj_clean, obj_links = structurize_text(obj_raw)
      creatures = extract_inline_creatures(obj_raw)
      @event_bus.emit(:room_objects, text: obj_clean, links: obj_links, creatures: creatures)

      player_clean, player_links = structurize_text(@room_pending_players || '')
      @event_bus.emit(:room_players, text: player_clean, links: player_links)

      @event_bus.emit(:room_supplemental_clear)

      # Also update the room players indicator (fallback for games that don't use streams)
      update_room_players_indicator(@room_pending_players)

      clear_pending_room_data
    end

    # Always update exits (even on subsequent exit lines).
    # update_exits triggers render internally.
    exits_clean, exits_links = structurize_text(exits_raw)
    @event_bus.emit(:room_exits, text: exits_clean, links: exits_links)
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
