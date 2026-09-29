# frozen_string_literal: true

require_relative '../link_extractor'
require_relative '../streams'
require_relative '../presets'

# Dedicated room display with atomic updates and creature highlighting.

# Room information display window.
#
# Shows the current room title, description, objects (with creature
# highlighting), players, exits, room number, and string procs.
# Updates arrive incrementally via the +update_*+ methods and a full
# {#render} is triggered when exits arrive (the last component in the
# batch). Mirrors Genie4's room window behavior.
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
  # @param text [String] clean title text
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

  # Update the room exits and trigger a full render.
  # Exits are typically the last component in a room update batch.
  #
  # @param text [String] clean exits text
  # @param links [Array<Hash>] pre-computed link regions `[{start:, end:, cmd:}]`
  # @return [void]
  def update_exits(text, links: [])
    @exits = text.strip
    @exits_links = links
    render # Trigger full redraw on exits (last component)
  end

  # Update the Lich-injected supplemental exits (non-cardinal "Room Exits:").
  #
  # @param text [String] the raw Lich exits text (may contain <d> link tags)
  # @return [void]
  def update_lich_exits(text)
    @lich_exits = text.strip
    render
  end

  # Update the room number text and re-render.
  #
  # @param text [String] the raw room number text
  # @return [void]
  def update_room_number(text)
    @room_number = text.strip
    render
  end

  # Update the string procs text and re-render.
  #
  # @param text [String] the raw string procs text
  # @return [void]
  def update_stringprocs(text)
    @stringprocs = text.strip
    render
  end

  # Clear supplemental fields (room number, stringprocs) between room changes
  # so stale data does not persist.
  #
  # @return [void]
  def clear_supplemental
    @lich_exits = ''
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
  # Clears the window and draws each section (title, description, objects,
  # players, exits, room number, stringprocs) with appropriate presets and
  # highlight processing.
  #
  # @return [void]
  def render
    erase
    setpos(0, 0)
    @rendered_lines = []

    # Room title with preset
    unless @title.empty?
      if (match = @title.match(/^(?<room_name>.+?)\s+\((?<room_id>\d+)\)$/))
        formatted_title = "[#{match[:room_name]}] (#{match[:room_id]})"
        render_section(formatted_title, @title_preset)
      else
        render_section("[#{@title}]", @title_preset)
      end
      section_break
    end

    # Room description
    unless @description.empty?
      render_section_with_links(@description, @desc_links, @desc_preset)
      section_break
    end

    # Objects (with creature highlighting and clickable links)
    unless @objects.empty?
      render_objects_section
      section_break
    end

    # Players
    unless @players.empty?
      render_section_with_links(@players, @players_links, nil)
      section_break
    end

    # Exits (with clickable direction links when links are enabled)
    unless @exits.empty?
      render_exits_section(@exits, @exits_links)
      section_break
    end

    # Lich supplemental exits (non-cardinal "Room Exits:")
    unless @lich_exits.empty?
      render_lich_exits_section(@lich_exits)
      section_break
    end

    # Room number
    unless @room_number.empty?
      render_section(@room_number, nil)
      section_break
    end

    # StringProcs
    render_section(@stringprocs, nil) unless @stringprocs.empty?

    noutrefresh
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

  # Advance to the next line after a section or a wrapped row. When the
  # last rendered line exactly fills the window width, curses auto-wraps
  # the cursor to column 0 of the next line. An unconditional
  # addstr("\n") would then produce a spurious blank line. This checks the
  # cursor column first.
  #
  # @return [void]
  # @api private
  def section_break
    addstr("\n") unless curx == 0
  end

  # Render a text section with an optional preset color.
  # No link processing — used for title, room number, stringprocs.
  #
  # @param text [String] clean section text
  # @param preset_name [String, nil] preset color key from the PRESET hash
  # @return [void]
  # @api private
  def render_section(text, preset_name)
    line_colors = []

    if preset_name && (colors = Presets.colors(preset_name))
      line_colors.push({ start: 0, end: text.length, **colors })
    end

    HighlightProcessor.apply_highlights(text, line_colors)
    add_line_wrapped_with_links(text, line_colors)
  end

  # Render a text section with pre-computed links and optional preset color.
  #
  # @param text [String] clean section text
  # @param links [Array<Hash>] pre-computed link regions `[{start:, end:, cmd:}]`
  # @param preset_name [String, nil] preset color key from the PRESET hash
  # @return [void]
  # @api private
  def render_section_with_links(text, links, preset_name)
    line_colors = build_link_colors(links)

    if preset_name && (colors = Presets.colors(preset_name))
      line_colors.push({ start: 0, end: text.length, **colors })
    end

    HighlightProcessor.apply_highlights(text, line_colors)
    add_line_wrapped_with_links(text, line_colors)
  end

  # Render the objects section with creature bold highlighting and clickable links.
  #
  # @return [void]
  # @api private
  def render_objects_section
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
    add_line_wrapped_with_links(@objects, line_colors)
  end

  # Render the exits section with pre-computed clickable direction links.
  #
  # @param text [String] clean exits text
  # @param links [Array<Hash>] pre-computed link regions
  # @return [void]
  # @api private
  def render_exits_section(text, links)
    clean_text = text.rstrip.end_with?(':') ? "#{text} none." : text

    line_colors = build_link_colors(links)
    HighlightProcessor.apply_highlights(clean_text, line_colors)
    add_line_wrapped_with_links(clean_text, line_colors)
  end

  # Render Lich-injected exits (may still contain raw XML from Lich injection).
  # Uses extract_links as these come from inline text, not SAX-processed components.
  #
  # @param text [String] raw Lich exits text
  # @return [void]
  # @api private
  def render_lich_exits_section(text)
    clean_text, line_colors = LinkExtractor.extract_links(text, links_enabled: links_enabled)
    clean_text = "#{clean_text} none." if clean_text.rstrip.end_with?(':')

    HighlightProcessor.apply_highlights(clean_text, line_colors)
    add_line_wrapped_with_links(clean_text, line_colors)
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

  # Word-wrap text to the window width and draw one wrapped row per window
  # row, recording each row's colors (including :cmd) under the window row
  # it is drawn on, for {#link_cmd_at}.
  #
  # Rows are wrapped by {StyledText#wrap} at the full width, without
  # indenting continuation rows (a space starting one is dropped). A row that fills the width leaves the
  # cursor at the start of the next row, so rows are separated by
  # {#section_break}, which only moves down when the cursor hasn't. Past
  # the bottom row curses keeps the cursor there; only the first row drawn
  # on a window row is recorded for it.
  #
  # @param text [String] clean section text
  # @param line_colors [Array<Hash>] color regions for +text+
  # @return [void]
  # @api private
  def add_line_wrapped_with_links(text, line_colors)
    return if text.empty?

    StyledText.new(text, line_colors).wrap(maxx, indent: false).each_with_index do |row, index|
      section_break if index.positive?
      line = row.text.rstrip
      @rendered_lines[cury] ||= { text: line, colors: row.runs }
      add_line(line, row.runs)
    end
  end
end

BaseWindow.register_type('room') do |height, width, top, left, element, wm|
  window = RoomWindow.new(height, width, top, left)
  window.scrollok(false)
  window.title_preset = element.attributes['title-preset'] || Presets::ROOM_NAME
  window.desc_preset = element.attributes['desc-preset']
  window.creatures_preset = element.attributes['creatures-preset'] || Presets::MONSTERBOLD
  window.shared_state = wm.shared_state
  wm.room[Streams::ROOM] = window
  window
end
