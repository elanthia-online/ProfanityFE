# frozen_string_literal: true

require_relative '../link_extractor'
require_relative '../streams'
require_relative '../presets'

# Dedicated room display with atomic updates and creature highlighting.

# Room information display window.
#
# Shows the current room title, description, objects (with creature
# highlighting), players, exits, room number, and string procs.
# Updates arrive incrementally via the +update_*+ methods, which only
# store the new text: nothing is drawn until {#render}. The server loop
# renders the window once per flush when a room part changed (see
# {RoomAssembler} and {ServerReader}, which also draws a render still
# pending when the connection closes), and a resize, a layout change or
# +.links+ renders it at once. Mirrors Genie4's room window behavior.
#
# All room sections receive pre-computed structured data from the SAX
# parser: clean text, link regions (with :cmd for click dispatch), and
# creature names. The room window only applies its own presets/colors
# during rendering — no XML parsing or regex tag stripping occurs here.
class RoomWindow < BaseWindow
  # Resized after the spell window (see {BaseWindow.resize_order}).
  #
  # @return [Integer]
  def self.resize_order
    50
  end

  # @return [String, nil] preset name applied to the room title color
  attr_accessor :title_preset

  # @return [String, nil] preset name applied to the room description color
  attr_accessor :desc_preset

  # @return [String, nil] preset name applied to creature highlight color
  attr_accessor :creatures_preset

  # Where the window reads whether links are on: the {SharedState} that
  # +--links+ and +.links+ set. The builder hands every room window the
  # {WindowManager}'s, so a window a layout builds, at startup or by
  # +.layout+, follows the current setting. Without one, links are off.
  #
  # @return [SharedState, nil]
  attr_accessor :shared_state

  # Create a new room window with empty section fields.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @title = ''
    @description = ''
    @desc_links = []
    @objects = ''
    @objects_links = []
    @extracted_creatures = []
    @players = ''
    @players_links = []
    @exits = ''
    @exits_links = []
    @lich_exits = ''
    @lich_exits_links = []
    @room_number = ''
    @stringprocs = ''
    @rendered_lines = [] # {text:, colors:} per window row, for link_cmd_at
    @shared_state = nil
    super
  end

  # Whether clickable links are rendered: the current setting of
  # {#shared_state}, read at every render.
  #
  # @return [Boolean]
  def links_enabled
    @shared_state&.blue_links || false
  end

  # Update the room title text.
  #
  # @param text [String] the title row's text, shown as it is: the room's
  #   title as {RoomTitle#to_s} gives it (+"[Town Square] (1234)"+), or an
  #   empty string for no title row
  # @return [void]
  def update_title(text)
    @title = text.strip
  end

  # Update the room description with pre-computed link data.
  #
  # @param text [String] clean description text
  # @param links [Array<Hash>] pre-computed link regions `[{start:, end:, cmd:}]`
  # @return [void]
  def update_desc(text, links: [])
    @description = text.strip
    @desc_links = links
  end

  # Update the room objects with pre-computed link and creature data.
  #
  # @param text [String] clean objects text
  # @param links [Array<Hash>] pre-computed link regions `[{start:, end:, cmd:}]`
  # @param creatures [Array<String>] creature names for monsterbold highlighting
  # @return [void]
  def update_objects(text, links: [], creatures: [])
    @objects = text.strip
    @objects_links = links
    @extracted_creatures = creatures
  end

  # Update the room players with pre-computed link data.
  #
  # @param text [String] clean players text
  # @param links [Array<Hash>] pre-computed link regions `[{start:, end:, cmd:}]`
  # @return [void]
  def update_players(text, links: [])
    @players = text.strip
    @players_links = links
  end

  # Update the room exits text.
  #
  # @param text [String] clean exits text
  # @param links [Array<Hash>] pre-computed link regions `[{start:, end:, cmd:}]`
  # @return [void]
  def update_exits(text, links: [])
    @exits = text.strip
    @exits_links = links
  end

  # Update the Lich-injected supplemental exits (non-cardinal "Room Exits:")
  # with pre-computed link data.
  #
  # @param text [String] clean Lich exits text
  # @param links [Array<Hash>] pre-computed link regions `[{start:, end:, cmd:}]`
  # @return [void]
  def update_lich_exits(text, links: [])
    @lich_exits = text.strip
    @lich_exits_links = links
  end

  # Update the room number text.
  #
  # @param text [String] the raw room number text
  # @return [void]
  def update_room_number(text)
    @room_number = text.strip
  end

  # Update the string procs text.
  #
  # @param text [String] the raw string procs text
  # @return [void]
  def update_stringprocs(text)
    @stringprocs = text.strip
  end

  # Clear supplemental fields (room number, stringprocs) between room changes
  # so stale data does not persist.
  #
  # @return [void]
  def clear_supplemental
    @lich_exits = ''
    @lich_exits_links = []
    @room_number = ''
    @stringprocs = ''
  end

  # Re-render room content after a resize or layout change.
  #
  # @return [void]
  def redraw
    render
  end

  # Draw the window again from its current state: the same as {#redraw}
  # (see {BaseWindow#repaint}).
  #
  # @return [void]
  def repaint
    redraw
  end

  # Render the complete room display.
  # Wraps each section (title, description, objects, players, exits, room
  # number, stringprocs) into rows with appropriate presets and highlight
  # processing, each section starting on a new row, then clears the window
  # and draws the rows that fit, one per window row (see {#fit_rows} for a
  # room longer than the window). The rows drawn are the rows
  # {#link_cmd_at} answers clicks from.
  #
  # @return [void]
  def render
    rows = []

    # Room title with preset
    rows.concat(section_rows(@title, @title_preset)) unless @title.empty?

    # Room description
    rows.concat(section_rows_with_links(@description, @desc_links, @desc_preset)) unless @description.empty?

    # Objects (with creature highlighting and clickable links)
    rows.concat(objects_rows) unless @objects.empty?

    # Players
    rows.concat(section_rows_with_links(@players, @players_links, nil)) unless @players.empty?

    exits = []

    # Exits (with clickable direction links when links are enabled)
    exits.concat(exits_rows(@exits, @exits_links)) unless @exits.empty?

    # Lich supplemental exits (non-cardinal "Room Exits:")
    exits.concat(exits_rows(@lich_exits, @lich_exits_links)) unless @lich_exits.empty?

    below = []

    # Room number
    below.concat(section_rows(@room_number, nil)) unless @room_number.empty?

    # StringProcs
    below.concat(section_rows(@stringprocs, nil)) unless @stringprocs.empty?

    draw_rows(fit_rows(rows, exits, below))
  end

  # Find a clickable link command at the given window-relative coordinates.
  # Searches the rendered lines for a color region with a :cmd key.
  #
  # @param rel_y [Integer] row relative to window top
  # @param rel_x [Integer] column relative to window left
  # @return [String, nil] the link command string, or nil if no link
  def link_cmd_at(rel_y, rel_x)
    return nil if rel_y < 0

    colors = @rendered_lines[rel_y]&.fetch(:colors)
    return nil unless colors

    colors.each do |h|
      return h[:cmd] if h[:cmd] && rel_x >= h[:start] && rel_x < h[:end]
    end
    nil
  end

  private

  # The rows to draw, at most one per window row. A room that fits shows
  # every row. A room longer than the window keeps its exits: the rows
  # below the exits (room number, stringprocs) are cut first, from the
  # end, then the rows above them, from the end, so the exits end on the
  # bottom row. Exits longer than the window show their first rows.
  #
  # @param above [Array<Hash>] rows of the sections above the exits
  # @param exits [Array<Hash>] rows of the game's exits, then Lich's
  # @param below [Array<Hash>] rows of the sections below the exits
  # @return [Array<Hash>] `{text:, colors:}` per row, at most +maxy+
  # @api private
  def fit_rows(above, exits, below)
    exits = exits.first(maxy)
    above = above.first(maxy - exits.length)
    above + exits + below.first(maxy - above.length - exits.length)
  end

  # Clear the window and draw +rows+ one per window row from the top,
  # keeping them for {#link_cmd_at}.
  #
  # @param rows [Array<Hash>] `{text:, colors:}` per row, at most +maxy+
  # @return [void]
  # @api private
  def draw_rows(rows)
    erase
    rows.each_with_index do |row, y|
      setpos(y, 0)
      add_line(row[:text], row[:colors])
    end
    @rendered_lines = rows
    noutrefresh
  end

  # Wrap a text section with an optional preset color.
  # No link processing — used for title, room number, stringprocs.
  #
  # @param text [String] clean section text
  # @param preset_name [String, nil] preset color key from the PRESET hash
  # @return [Array<Hash>] the section's rows (see {#wrap_rows})
  # @api private
  def section_rows(text, preset_name)
    line_colors = []

    if preset_name && (colors = Presets.colors(preset_name))
      line_colors.push({ start: 0, end: text.length, **colors })
    end

    HighlightProcessor.apply_highlights(text, line_colors)
    wrap_rows(text, line_colors)
  end

  # Wrap a text section with pre-computed links and optional preset color.
  #
  # @param text [String] clean section text
  # @param links [Array<Hash>] pre-computed link regions `[{start:, end:, cmd:}]`
  # @param preset_name [String, nil] preset color key from the PRESET hash
  # @return [Array<Hash>] the section's rows (see {#wrap_rows})
  # @api private
  def section_rows_with_links(text, links, preset_name)
    line_colors = build_link_colors(links)

    if preset_name && (colors = Presets.colors(preset_name))
      line_colors.push({ start: 0, end: text.length, **colors })
    end

    HighlightProcessor.apply_highlights(text, line_colors)
    wrap_rows(text, line_colors)
  end

  # Wrap the objects section with creature bold highlighting and clickable links.
  #
  # @return [Array<Hash>] the section's rows (see {#wrap_rows})
  # @api private
  def objects_rows
    line_colors = build_link_colors(@objects_links)

    # Highlight creatures with monsterbold preset
    preset_name = @creatures_preset || Presets::MONSTERBOLD
    if (colors = Presets.colors(preset_name))
      @extracted_creatures.each do |creature|
        # Whole words only ("rat" not inside "pirate"); apostrophes and
        # hyphens count as part of a word, as in "Adan'f" or "void-black".
        whole_word = /(?<![[:word:]'-])#{Regexp.escape(creature)}(?![[:word:]'-])/
        pos = 0
        while (idx = @objects.index(whole_word, pos))
          line_colors.push({ start: idx, end: idx + creature.length, **colors })
          pos = idx + creature.length
        end
      end
    end

    HighlightProcessor.apply_highlights(@objects, line_colors)
    wrap_rows(@objects, line_colors)
  end

  # Wrap an exits section (the game's, or Lich's "Room Exits:") with
  # pre-computed clickable links; an empty list of exits ends in "none.".
  #
  # @param text [String] clean exits text
  # @param links [Array<Hash>] pre-computed link regions
  # @return [Array<Hash>] the section's rows (see {#wrap_rows})
  # @api private
  def exits_rows(text, links)
    clean_text = text.rstrip.end_with?(':') ? "#{text} none." : text

    line_colors = build_link_colors(links)
    HighlightProcessor.apply_highlights(clean_text, line_colors)
    wrap_rows(clean_text, line_colors)
  end

  # Build color regions from pre-computed link data when links are enabled.
  #
  # @param links [Array<Hash>] `[{start:, end:, cmd:}]`
  # @return [Array<Hash>] color regions with link preset colors and :cmd
  # @api private
  def build_link_colors(links)
    return [] unless links_enabled && links&.any?

    colors = Presets.colors(Presets::LINKS, LinkExtractor::DEFAULT_LINK_COLOR)
    links.map do |link|
      {
        start: link[:start],
        end: link[:end],
        fg: colors[:fg],
        bg: colors[:bg],
        cmd: link[:cmd]
      }
    end
  end

  # Word-wrap text to the window width, one row per window row, each with
  # its colors (including :cmd) for {#link_cmd_at}.
  #
  # Rows are wrapped by {StyledText#wrap} at the full width, without
  # indenting continuation rows (a space starting one is dropped), and
  # lose trailing spaces. A row of only spaces (from a run of spaces wider
  # than the window) is left out, as it has always been on screen.
  #
  # @param text [String] clean section text
  # @param line_colors [Array<Hash>] color regions for +text+
  # @return [Array<Hash>] `{text:, colors:}` per row
  # @api private
  def wrap_rows(text, line_colors)
    return [] if text.empty?

    StyledText.new(text, line_colors).wrap(maxx, indent: false).filter_map do |row|
      line = row.text.rstrip
      { text: line, colors: row.runs } unless line.empty?
    end
  end
end

BaseWindow.register_type('room') do |height, width, top, left, element, wm|
  # The previous layout's room window keeps the room it shows
  window = wm.claim_window(:room, Streams::ROOM, RoomWindow) || RoomWindow.new(height, width, top, left)
  window.scrollok(false)
  window.title_preset = element.attributes['title-preset'] || Presets::ROOM_NAME
  window.desc_preset = element.attributes['desc-preset']
  window.creatures_preset = element.attributes['creatures-preset'] || Presets::MONSTERBOLD
  window.shared_state = wm.shared_state
  wm.room[Streams::ROOM] = window
  window
end
