# frozen_string_literal: true

# Multi-tab text window sharing one display area with tab bar and keyboard switching.

# Multi-tab text window.
#
# Manages multiple named text buffers that share a single display area.
# A tab bar at the top shows all tabs with an activity indicator (*) for
# background tabs that have received new content. Tabs can be switched by
# name, index, or next/prev cycling. Each tab maintains its own independent
# scroll position.
class TabbedTextWindow < BaseWindow
  # Height in rows reserved for the tab bar at the top of the window.
  TAB_BAR_HEIGHT = 1

  # @return [Hash{String => Array}] tab name to line buffer mapping
  attr_reader :tabs

  # @return [String, nil] name of the currently displayed tab
  attr_reader :active_tab

  # @return [Integer] maximum number of lines retained per tab buffer
  attr_reader :max_buffer_size

  # @return [Boolean] whether continuation lines are indented during word wrap
  attr_accessor :indent_word_wrap

  # @return [Boolean] whether a timestamp is appended to each non-empty line
  attr_accessor :time_stamp

  # Create a new tabbed text window with an empty tab set.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @tabs = {}              # { "main" => [[line, colors], ...], ... }
    @buffer_positions = {}  # Per-tab scroll positions
    @tab_activity = {}      # Track unread content in background tabs
    @lines_appended = {}    # Per-tab monotonic append counters (stable line IDs)
    @active_tab = nil
    @max_buffer_size = DEFAULT_BUFFER_SIZE
    @indent_word_wrap = true
    super
    # Set scroll region to exclude tab bar (row 0)
    setscrreg(TAB_BAR_HEIGHT, maxy - 1)
  end

  # Set the maximum number of lines retained per tab buffer.
  #
  # @param val [Integer, #to_i] new buffer size limit
  # @return [void]
  def max_buffer_size=(val)
    @max_buffer_size = val.to_i
  end

  # Add a new named tab to this window.
  # The first tab added becomes the active tab.
  #
  # @param name [String] unique tab name (e.g. "main", "combat")
  # @return [void]
  def add_tab(name)
    @tabs[name] = []
    @buffer_positions[name] = 0
    @tab_activity[name] = false
    @lines_appended[name] = 0
    @active_tab ||= name
    draw_tab_bar
  end

  # Monotonic count of lines ever appended to the active tab's buffer.
  # Gives each buffer line a stable ID for selection anchoring
  # (see {AnchoredSelection}).
  #
  # @return [Integer]
  def lines_appended
    @lines_appended[@active_tab] || 0
  end

  # Return the active tab's line buffer for TextWindow-compatible access.
  #
  # @return [Array<Array(String, Array<Hash>)>] line buffer of the active tab
  def buffer
    @tabs[@active_tab] || []
  end

  # Return the active tab's scroll offset.
  #
  # @return [Integer] number of lines scrolled from the bottom
  def buffer_pos
    @buffer_positions[@active_tab] || 0
  end

  # Switch to a specific tab by name.
  # Clears the activity indicator and redraws the content area.
  #
  # @param name [String] the tab name to switch to
  # @return [void]
  def switch_tab(name)
    return unless @tabs.key?(name)
    return if name == @active_tab

    # Selection line IDs are per-tab; a stale selection would map onto
    # unrelated text in the new tab
    @selection_start = nil
    @selection_end = nil
    @active_tab = name
    @tab_activity[name] = false
    redraw
    draw_tab_bar
  end

  # Switch to the next tab, cycling back to the first after the last.
  #
  # @return [void]
  def next_tab
    return if @tabs.empty?

    tab_names = @tabs.keys
    current_idx = tab_names.index(@active_tab) || 0
    next_idx = (current_idx + 1) % tab_names.length
    switch_tab(tab_names[next_idx])
  end

  # Switch to the previous tab, cycling to the last after the first.
  #
  # @return [void]
  def prev_tab
    return if @tabs.empty?

    tab_names = @tabs.keys
    current_idx = tab_names.index(@active_tab) || 0
    prev_idx = (current_idx - 1) % tab_names.length
    switch_tab(tab_names[prev_idx])
  end

  # Switch to a tab by its 1-based index.
  #
  # @param index [Integer] 1-based tab position
  # @return [void]
  def switch_tab_by_index(index)
    tab_names = @tabs.keys
    return if index < 1 || index > tab_names.length

    switch_tab(tab_names[index - 1])
  end

  # Draw the tab bar at the top of the window.
  # Active tab is rendered with reverse video; background tabs with
  # unread content show an asterisk (*) activity indicator.
  #
  # @return [void]
  def draw_tab_bar
    setpos(0, 0)
    clrtoeol

    tab_names = @tabs.keys
    x_pos = 0

    tab_names.each_with_index do |name, idx|
      activity = @tab_activity[name] && name != @active_tab ? '*' : ''
      label = " #{idx + 1}:#{name}#{activity} "

      if name == @active_tab
        attron(Curses::A_REVERSE) do
          addstr(label)
        end
      else
        addstr(label)
      end
      x_pos += label.length

      addstr('|') if idx < tab_names.length - 1
      x_pos += 1
    end

    noutrefresh
  end

  # Height of the content area excluding the tab bar.
  #
  # @return [Integer] number of rows available for text content
  def content_height
    maxy - TAB_BAR_HEIGHT
  end

  # Route text to the appropriate tab based on stream name.
  # Falls back to the active tab (or "main") when the stream has no
  # dedicated tab.
  #
  # @param text [String] the text to display
  # @param colors [Array<Hash>] color region descriptors
  # @param stream [String, nil] stream name used for tab routing
  # @return [void]
  def route_string(text, colors, stream = nil, indent: nil)
    target_tab = stream && @tabs.key?(stream) ? stream : (@active_tab || MAIN_STREAM)
    add_string_to_tab(target_tab, text, colors, indent: indent)
  end

  # Check if the most recent non-empty line in the "main" tab matches the
  # given prompt text. Used to suppress duplicate bare prompts.
  #
  # @param prompt_text [String] the prompt string to check against
  # @return [Boolean] true if the last non-empty line in "main" equals prompt_text
  def duplicate_prompt?(prompt_text)
    main_buffer = @tabs[MAIN_STREAM] || []
    return false if main_buffer.empty?

    recent_line = main_buffer.find { |entry| entry[0] && !entry[0].empty? }
    recent_line && recent_line[0] == prompt_text
  end

  # Append a string to a specific tab's buffer.
  # If the tab is active and not scrolled, the text is rendered immediately.
  # Background tabs receive an activity indicator on the tab bar.
  #
  # @param tab_name [String] the target tab name
  # @param string [String] the text to append
  # @param string_colors [Array<Hash>] color region descriptors
  # @return [void]
  def add_string_to_tab(tab_name, string, string_colors = [], indent: nil)
    return unless @tabs.key?(tab_name)
    return if string.nil? || string.chomp.empty?

    string += format_timestamp if @time_stamp

    content_width = maxx - 1
    tab_buffer = @tabs[tab_name]
    tab_buffer_pos = @buffer_positions[tab_name]

    effective_indent = indent.nil? ? @indent_word_wrap : indent
    wrap_text(string, content_width, string_colors, indent: effective_indent) do |line, line_colors, continuation|
      tab_buffer.unshift([line, line_colors, continuation])
      @lines_appended[tab_name] += 1
      if tab_buffer.length > @max_buffer_size
        tab_buffer.pop
        max_pos = tab_buffer.length - content_height
        @buffer_positions[tab_name] = max_pos if max_pos >= 0 && @buffer_positions[tab_name] > max_pos
      end

      if tab_name == @active_tab
        if tab_buffer_pos == 0
          scrl(1) if tab_buffer.length > content_height
          visible_lines = [tab_buffer.length, content_height].min
          write_row = TAB_BAR_HEIGHT + visible_lines - 1
          setpos(write_row, 0)
          clrtoeol
          add_line(line, line_colors)
        else
          @buffer_positions[tab_name] += 1
          tab_buffer_pos = @buffer_positions[tab_name]
          scrl(1) if @buffer_positions[tab_name] > (@max_buffer_size - content_height)
          update_scrollbar
        end
      else
        unless @tab_activity[tab_name]
          @tab_activity[tab_name] = true
          draw_tab_bar
        end
      end
    end

    return unless tab_name == @active_tab && @buffer_positions[tab_name] == 0

    # Re-apply selection highlight if active (new text overwrites it)
    if has_highlight?
      redraw_with_highlight
    else
      noutrefresh
    end
  end

  # Append a string to the active tab's buffer.
  #
  # @param string [String] the text to append
  # @param string_colors [Array<Hash>] color region descriptors
  # @return [void]
  def add_string(string, string_colors = [], indent: nil)
    return unless @active_tab

    add_string_to_tab(@active_tab, string, string_colors, indent: indent)
  end

  # Scroll the active tab's buffer by the given number of lines.
  # Negative values scroll up (toward older content), positive values scroll
  # down (toward newer content).
  #
  # @param scroll_num [Integer] lines to scroll (negative = up, positive = down)
  # @return [void]
  def scroll(scroll_num)
    return unless @active_tab

    tab_buffer = @tabs[@active_tab]
    tab_buffer_pos = @buffer_positions[@active_tab]
    ch = content_height

    if scroll_num < 0
      if (tab_buffer_pos + ch + scroll_num.abs) >= tab_buffer.length
        scroll_num = 0 - (tab_buffer.length - tab_buffer_pos - ch)
      end
      if scroll_num < 0
        @buffer_positions[@active_tab] += scroll_num.abs
        setpos(TAB_BAR_HEIGHT, 0)
        scrl(scroll_num)
        setpos(TAB_BAR_HEIGHT, 0)
        pos = @buffer_positions[@active_tab] + ch - 1
        scroll_num.abs.times do
          add_line(tab_buffer[pos][0], tab_buffer[pos][1])
          addstr "\n"
          pos -= 1
        end
        noutrefresh
      end
      update_scrollbar
    elsif scroll_num > 0
      if tab_buffer_pos > 0
        scroll_num = tab_buffer_pos if (tab_buffer_pos - scroll_num) < 0
        @buffer_positions[@active_tab] -= scroll_num
        setpos(TAB_BAR_HEIGHT, 0)
        scrl(scroll_num)
        setpos(TAB_BAR_HEIGHT + ch - scroll_num, 0)
        pos = @buffer_positions[@active_tab] + scroll_num - 1
        (scroll_num - 1).times do
          add_line(tab_buffer[pos][0], tab_buffer[pos][1])
          addstr "\n"
          pos -= 1
        end
        add_line(tab_buffer[pos][0], tab_buffer[pos][1])
        noutrefresh
      end
    end
    # Selection is anchored to line IDs; re-render so the highlight
    # follows its text to the new scroll position
    redraw_with_highlight if has_highlight?
    update_scrollbar
  end

  # Redraw the active tab's content area and tab bar.
  #
  # @return [void]
  def redraw
    draw_tab_bar
    return unless @active_tab

    tab_buffer = @tabs[@active_tab]
    tab_buffer_pos = @buffer_positions[@active_tab]
    ch = content_height

    (TAB_BAR_HEIGHT...maxy).each do |y|
      setpos(y, 0)
      clrtoeol
    end

    return if tab_buffer.empty?

    visible_lines = [tab_buffer.length - tab_buffer_pos, ch].min
    return if visible_lines <= 0

    visible_lines.times do |i|
      buf_idx = tab_buffer_pos + (visible_lines - 1 - i)
      next if buf_idx >= tab_buffer.length || buf_idx < 0

      setpos(TAB_BAR_HEIGHT + i, 0)
      line_data = tab_buffer[buf_idx]
      add_line(line_data[0], line_data[1]) if line_data
    end

    update_scrollbar
    noutrefresh
  end

  # Refresh the scrollbar to reflect the active tab's buffer and scroll state.
  #
  # @return [void]
  def update_scrollbar
    return unless @active_tab

    render_scrollbar(@tabs[@active_tab].length, @buffer_positions[@active_tab], content_height)
  end

  # Clear (hide) the scrollbar.
  #
  # @return [void]
  def clear_scrollbar
    reset_scrollbar
  end

  # Return the active tab's buffer for selection support.
  #
  # @return [Array<Array(String, Array<Hash>)>] line buffer of the active tab
  def buffer_content
    @tabs[@active_tab] || []
  end

  # Resolve window-relative coordinates to a stable [line_id, x] anchor
  # in the active tab's buffer. Adjusts for the tab bar offset first.
  #
  # @param rel_y [Integer] row relative to window top (includes tab bar)
  # @param rel_x [Integer] column relative to window left
  # @return [Array<Integer>, nil] [line_id, x] anchor, or nil if the tab is empty
  def selection_anchor_at(rel_y, rel_x)
    tab_buffer = @tabs[@active_tab] || []
    id = AnchoredSelection.id_at_row(rel_y - TAB_BAR_HEIGHT,
                                     lines_appended: lines_appended,
                                     buffer_pos: buffer_pos,
                                     buffer_length: tab_buffer.length,
                                     height: content_height)
    id ? [id, [rel_x, 0].max] : nil
  end

  # Extract text from the active tab's buffer for a selection anchored
  # to stable line IDs. Lines evicted past max_buffer_size are skipped.
  #
  # @param start_id [Integer] starting line ID
  # @param start_x [Integer] starting column
  # @param end_id [Integer] ending line ID
  # @param end_x [Integer] ending column
  # @return [String] the selected text, lines joined by newlines
  def extract_selection(start_id, start_x, end_id, end_x)
    tab_buffer = @tabs[@active_tab] || []
    AnchoredSelection.extract(tab_buffer, lines_appended, start_id, start_x, end_id, end_x)
  end

  # Scroll one line when a drag pointer sits at the content area's top or
  # bottom edge, extending a selection past the visible area. The top
  # threshold is the tab bar row.
  #
  # @param rel_y [Integer] drag row relative to window top (includes tab bar)
  # @return [Boolean] true if the view actually scrolled
  def drag_auto_scroll(rel_y)
    before = buffer_pos
    if rel_y <= TAB_BAR_HEIGHT
      scroll(-1)
    elsif rel_y >= maxy - 1
      scroll(1)
    end
    buffer_pos != before
  end

  # Redraw the active tab's content with reverse-video selection highlighting.
  # The selection is anchored to stable line IDs, so the highlight follows
  # its text as new lines arrive or the user scrolls.
  #
  # @return [void]
  def redraw_with_highlight
    return unless @selection_start && @selection_end && @active_tab

    start_id, start_x, end_id, end_x = normalize_selection(*@selection_start, *@selection_end)

    tab_buffer = @tabs[@active_tab] || []
    tab_buffer_pos = @buffer_positions[@active_tab] || 0
    visible_lines = [tab_buffer.length - tab_buffer_pos, content_height].min

    (0...content_height).each do |i|
      y = TAB_BAR_HEIGHT + i
      setpos(y, 0)
      clrtoeol

      buffer_idx = tab_buffer_pos + (visible_lines - 1 - i)
      next if buffer_idx >= tab_buffer.length || buffer_idx < 0

      line_text, line_colors = tab_buffer[buffer_idx]
      id = lines_appended - buffer_idx

      if id >= start_id && id <= end_id
        draw_line_with_selection(id, line_text, line_colors || [], start_id, start_x, end_id, end_x)
      else
        add_line(line_text, line_colors || [])
      end
    end
    noutrefresh
  end

  # Find a clickable link command at the given window-relative coordinates.
  # Adjusts for the tab bar offset, then scans the active tab's buffer
  # for a color region with a :cmd at the given column.
  #
  # @param rel_y [Integer] row relative to window top (includes tab bar)
  # @param rel_x [Integer] column relative to window left
  # @return [String, nil] the link command string, or nil if no link at that position
  def link_cmd_at(rel_y, rel_x)
    content_y = rel_y - TAB_BAR_HEIGHT
    return nil if content_y < 0

    tab_buffer = @tabs[@active_tab] || []
    tab_buffer_pos = @buffer_positions[@active_tab] || 0
    visible_lines = [tab_buffer.length - tab_buffer_pos, content_height].min
    return nil if content_y >= visible_lines

    buffer_idx = tab_buffer_pos + (visible_lines - 1 - content_y)
    return nil if buffer_idx < 0 || buffer_idx >= tab_buffer.length

    _text, colors = tab_buffer[buffer_idx]
    return nil unless colors

    colors.each do |h|
      return h[:cmd] if h[:cmd] && rel_x >= h[:start] && rel_x < h[:end]
    end
    nil
  end
end

BaseWindow.register_type('tabbed') do |height, width, top, left, element, wm|
  next nil unless width > 1

  window = TabbedTextWindow.new(height, width - 1, top, left)
  window.scrollbar = Curses::Window.new(window.maxy, 1, window.begy, window.begx + window.maxx)
  window.layout = [element.attributes['height'], element.attributes['width'], element.attributes['top'], element.attributes['left']]
  window.scrollok(true)
  window.setscrreg(1, window.maxy - 1)
  window.max_buffer_size = element.attributes['buffer-size'] || 1000
  window.time_stamp = element.attributes['timestamp']
  tab_names = (element.attributes['tabs'] || element.attributes['value'] || MAIN_STREAM).split(',')
  tab_names.each do |tab_name|
    window.add_tab(tab_name.strip)
    wm.stream[tab_name.strip] = window
  end
  window.redraw
  SCROLL_WINDOW.push(window)
  window
end
