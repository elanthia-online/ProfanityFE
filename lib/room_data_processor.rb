# frozen_string_literal: true

=begin
Room data capture and assembly for RoomWindow.
Extracts room title, description, objects, players, exits, and room number
from game server XML component streams and inline text patterns.
=end

# Handles room data capture from game server component streams and inline text.
#
# Assembles room information (title, description, objects, players, exits)
# from multiple XML component lines and inline text patterns, updating the
# RoomWindow atomically when all components have arrived.
#
# UI updates are emitted via @event_bus rather than calling window methods
# directly. The @wm.room['room'] reference is retained only as a read-only
# check for whether a RoomWindow is configured in the current layout.
#
# Expects the including class to provide:
# - @wm           [WindowManager]
# - @event_bus    [EventBus]
# - @room_capture_mode, @room_pending_title, @room_pending_title_colors,
#   @room_pending_desc, @room_pending_desc_colors, @room_pending_objects,
#   @room_pending_objects_colors, @room_pending_players, @room_pending_exits,
#   @room_pending_number, @current_raw_line, @current_stream
# - @line_colors   [Array<Hash>]
# - @need_update   [Boolean]
#
# @api private
module RoomDataProcessor
  # Process room-related text from inline game text and update RoomWindow
  # data if applicable.
  #
  # Handles title and description via capture mode, "You also see" objects,
  # "Also here:" players, "Obvious paths/exits:" exits, room number, and
  # StringProcs.  When exits arrive (typically the last component), all
  # pending room data is committed to the RoomWindow atomically.
  #
  # @param text [String] the current line of game text (XML-unescaped)
  # @param line_colors [Array<Hash>] color regions for this line
  # @return [Boolean] true if this line was consumed by the RoomWindow
  #   (caller should not route it to the main window).  Returns false
  #   when title/desc text is captured for the terminal title but the
  #   template has no RoomWindow — the text must still flow to the
  #   main text window for display.
  # @api private
  def process_room_data(text, line_colors)
    return false if text.empty?

    room_data_captured = false

    # Handle room capture mode (roomName/roomDesc styled text).
    # Always update the terminal title from the roomName text since it
    # includes the room number in DR (e.g., "[Room] (230008)").
    # For templates without a RoomWindow, store the title for the
    # terminal but do NOT consume the text — it must still flow to
    # the main text window.
    case @room_capture_mode
    when :title
      room_title = parse_room_subtitle(text)
      @state.room_title = room_title unless room_title.empty?
      if @wm.room['room']
        @room_pending_title = text.sub(/^\[/, '').sub(/\]\s*\(/, ' (').strip
        @room_pending_title_colors = line_colors.dup
        room_data_captured = true
      end
      @room_capture_mode = nil
    when :desc
      if @wm.room['room']
        # Don't overwrite if already set by component stream (preserves raw XML for links)
        unless @room_pending_desc
          # Extract from raw line to preserve <d>/<a> link tags for room window.
          raw_desc = extract_styled_desc(@current_raw_line) if @current_raw_line
          @room_pending_desc = (raw_desc || text).strip
        end
        room_data_captured = true
      end
      @room_capture_mode = nil
    end

    # Without a RoomWindow, only update the room players indicator from
    # inline text patterns (objects, exits, etc. are not applicable).
    unless @wm.room['room']
      if text =~ /^Also here:\s*(.+)$/
        update_room_players_indicator(text.strip)
      end
      return room_data_captured
    end

    # Skip inline pattern matching when inside a component stream.
    # Component stream data (room objs, room players, room exits) is
    # handled by process_room_stream instead. Without this guard,
    # process_room_data would consume the text and prevent
    # process_room_stream from running.
    return room_data_captured if @current_stream&.start_with?('room')

    # Detect "You also see" for objects (may have leading whitespace)
    if text =~ /^\s*You also see\b/
      # Extract from raw line to preserve <pushBold/> tags for RoomWindow creature highlighting.
      # Use regex here (not REXML) since inline text isn't inside a component element.
      @room_pending_objects = if @current_raw_line && (match = @current_raw_line.match(/You also see\b.*/))
                                match[0].gsub(%r{</?(?:component|compDef)[^>]*>}, '').strip
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
      @need_update = true
    elsif text =~ /^Room Number:\s*\d+/
      @event_bus.emit(:room_number, text: text.strip)
      room_data_captured = true
      @need_update = true
    elsif text =~ /^StringProcs:/
      @event_bus.emit(:room_stringprocs, text: text.strip)
      room_data_captured = true
      @need_update = true
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
  # @return [Symbol, nil] :consumed if text was fully handled (caller should
  #   return), :continue if caller should keep processing (room players
  #   also needs indicator handling), or nil if not a room stream
  # @api private
  def process_room_stream(text)
    return nil unless @current_stream&.start_with?('room')

    # Without a RoomWindow, only handle room players for the indicator
    unless @wm.room['room']
      return @current_stream == 'room players' ? :continue : nil
    end

    # Extract pre-computed link regions from SAX-parsed @line_colors.
    # These have correct positions relative to `text` (the clean text
    # buffer) and include :cmd for click dispatch. Creature bold regions
    # are also extracted from @line_colors for the objects section.
    #
    # Adjust positions for leading whitespace that .strip removes,
    # since SAX positions are relative to the original text buffer.
    left_offset = text.length - text.lstrip.length
    links = extract_sax_links(left_offset)
    clean = text.strip

    case @current_stream
    when 'room', 'room title'
      @room_pending_title = clean
      @event_bus.emit(:room_title, text: clean)
    when 'room desc', 'roomDesc'
      @room_pending_desc = clean
      @event_bus.emit(:room_desc, text: clean, links: links)
    when 'room objs'
      creatures = extract_sax_creatures(text, left_offset)
      @room_pending_objects = clean
      @event_bus.emit(:room_objects, text: clean, links: links, creatures: creatures)
    when 'room players'
      @room_pending_players = clean
      @event_bus.emit(:room_players, text: clean, links: links)
    when 'room exits'
      @room_pending_exits = clean
      @event_bus.emit(:room_exits, text: clean, links: links)
      clear_pending_room_data
    end

    # Defer room window render to the IO.select flush point to reduce
    # curses operation frequency (update_exits already renders internally)
    @need_room_render = true unless @current_stream == 'room exits'

    @need_update = true
    # Don't skip for room players - let the indicator handler also process it
    @current_stream == 'room players' ? :continue : :consumed
  end

  private

  # Extract link regions from SAX-computed @line_colors.
  # Returns only color regions that have a :cmd key (clickable links),
  # stripping color info (the room window applies its own link preset).
  # Adjusts positions by the given offset (for leading whitespace removed by .strip).
  #
  # @param offset [Integer] number of chars stripped from the left of the text
  # @return [Array<Hash>] [{start:, end:, cmd:}, ...]
  def extract_sax_links(offset = 0)
    @line_colors.select { |c| c[:cmd] }.map do |c|
      { start: c[:start] - offset, end: c[:end] - offset, cmd: c[:cmd] }
    end
  end

  # Extract creature names from monsterbold regions in SAX-computed @line_colors.
  # Finds color regions that match the monsterbold preset and extracts the
  # corresponding text from the stripped clean text.
  #
  # @param text [String] original text (SAX text buffer, before strip)
  # @param offset [Integer] left strip offset applied to produce clean text
  # @return [Array<String>] creature names
  def extract_sax_creatures(text, offset = 0)
    monsterbold = PRESET['monsterbold']
    return [] unless monsterbold

    stripped = text.strip
    @line_colors.select { |c| c[:fg] == monsterbold[0] && c[:bg] == monsterbold[1] && !c[:cmd] }
                .filter_map { |c| stripped[(c[:start] - offset)...(c[:end] - offset)]&.strip }
                .reject(&:empty?)
                .uniq
  end

  # Reset all pending room data slots to nil.
  #
  # @return [void]
  def clear_pending_room_data
    @room_pending_title = nil
    @room_pending_title_colors = nil
    @room_pending_desc = nil
    @room_pending_objects = nil
    @room_pending_players = nil
    @room_pending_exits = nil
    @room_pending_number = nil
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
    # DR: <style id="roomDesc"/>...content...<style id=""/>
    if (m = raw_line.match(%r{<style id=["']roomDesc["']\s*/?>(.+?)(?:<style id=["']["']\s*/?>|$)}))
      return m[1]
    end

    # GS/alt: <preset id='roomDesc'>...content...</preset>
    if (m = raw_line.match(%r{<preset id=["']roomDesc["']>(.+?)</preset>}))
      return m[1]
    end

    nil
  end

  # Convert raw XML text to structured data: clean text + link regions.
  # Used by the inline path (commit_room_data_batch) where pending data
  # may contain raw XML from @current_raw_line.
  #
  # @param raw_text [String] text potentially containing XML tags
  # @return [Array(String, Array<Hash>)] [clean_text, [{start:, end:, cmd:}, ...]]
  def structurize_text(raw_text)
    return [raw_text, []] if raw_text.empty?

    clean, colors = LinkExtractor.extract_links(raw_text, links_enabled: true)
    links = colors.map { |c| { start: c[:start], end: c[:end], cmd: c[:cmd] } }
    [clean.strip, links]
  end

  # Extract creature names from pushBold regions in raw XML text.
  # Used by the inline path where SAX bold tracking isn't available.
  #
  # @param raw_text [String] raw objects text with XML bold tags
  # @return [Array<String>] creature names
  def extract_inline_creatures(raw_text)
    raw_text.scan(%r{<pushBold\s*/?>(.*?)<popBold\s*/?>})
            .flatten
            .map { |c| c.gsub(%r{<[^>]+>}, '').strip }
            .reject(&:empty?)
            .uniq
  end

  # Strip all XML tags from text, keeping only the text content.
  #
  # @param text [String] text potentially containing XML tags
  # @return [String] text with all XML tags removed
  def strip_xml_tags(text)
    text.gsub(%r{<[^>]+>}, '')
  end

  # Commit all pending room data to the RoomWindow and clear the staging area.
  #
  # Called when exits arrive (the last expected room component). Only commits
  # if there is actual pending data to avoid double-updates that would clear
  # previously committed data.
  #
  # @return [void]
  def commit_room_data_batch
    return unless @wm.room['room']

    # Save exits before clearing — clear_pending_room_data wipes all
    # pending fields, but exits are emitted separately after the batch.
    exits_raw = @room_pending_exits || ''

    # Only update if we have pending data (avoid double-updates clearing data)
    if @room_pending_title || @room_pending_desc || @room_pending_objects || @room_pending_players
      @event_bus.emit(:room_title, text: @room_pending_title || '')

      # Inline path stores raw XML — convert to structured data at emission time.
      desc_clean, desc_links = structurize_text(@room_pending_desc || '')
      @event_bus.emit(:room_desc, text: desc_clean, links: desc_links)

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
    @need_update = true
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
