# frozen_string_literal: true

# Multi-tab text window sharing one display area with tab bar and keyboard switching.

require_relative 'line_buffered'
require_relative 'stream_window'

# Multi-tab text window.
#
# Manages multiple named text buffers that share a single display area.
# A tab bar at the top shows all tabs with an activity indicator (*) for
# background tabs that have received new content. Tabs can be switched by
# name, index, or next/prev cycling. Each tab has its own {LineBuffer}, so
# it keeps its own lines and scroll position; the text area below the tab
# bar shows the active tab's (see {LineBuffered}). The scrollbar is shown
# only while the window is the active one (see {#update_scrollbar}).
class TabbedTextWindow < BaseWindow
  include LineBuffered
  include StreamWindow

  # Height in rows reserved for the tab bar at the top of the window.
  TAB_BAR_HEIGHT = 1

  # The layout's last column holds the scrollbar.
  #
  # @return [Integer]
  def self.right_margin
    1
  end

  # Tabbed windows are resized after text windows (see
  # {BaseWindow.resize_order}).
  #
  # @return [Integer]
  def self.resize_order
    20
  end

  # @return [String, nil] name of the currently displayed tab
  attr_reader :active_tab

  # @return [Integer] maximum number of logical lines retained per tab buffer
  attr_reader :max_buffer_size

  # Create a new tabbed text window with an empty tab set.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @tab_buffers = {}       # { "main" => LineBuffer, ... }: lines and scroll position per tab
    @tab_activity = {}      # Track unread content in background tabs
    @active_tab = nil
    @max_buffer_size = DEFAULT_BUFFER_SIZE
    @indent_word_wrap = true
    super
    # Set scroll region to exclude tab bar (row 0)
    setscrreg(TAB_BAR_HEIGHT, maxy - 1)
  end

  # Set the maximum number of logical lines retained per tab buffer. The
  # oldest lines over a lowered limit are dropped at once, from every tab.
  #
  # @param val [Integer, #to_i] new buffer size limit
  # @return [void]
  def max_buffer_size=(val)
    @max_buffer_size = val.to_i
    cap_line_buffers(@max_buffer_size)
  end

  # Each tab's display rows.
  #
  # @return [Hash{String => Array}] tab name to rows (newest first)
  #   mapping, in tab order
  def tabs
    @tab_buffers.transform_values(&:lines)
  end

  # Give the window exactly these tabs, in this order. A tab it already
  # has keeps its lines, scroll position and unread mark; a new one starts
  # empty; a tab not listed is dropped with its lines. The active tab
  # stays active while it is listed; otherwise the first tab becomes
  # active, and the selection, anchored to the rows the window showed, is
  # dropped (see {SelectionManager.forget_window}).
  #
  # @param names [Array<String>] tab names (e.g. "main", "combat"); a
  #   repeated name counts once
  # @return [void]
  def keep_tabs(names)
    names = names.uniq
    @tab_buffers = names.to_h { |name| [name, @tab_buffers[name] || LineBuffer.new(cap: @max_buffer_size, width: wrap_width)] }
    @tab_activity = names.to_h { |name| [name, @tab_activity.fetch(name, false)] }
    unless @tab_buffers.key?(@active_tab)
      @active_tab = names.first
      @tab_activity[@active_tab] = false if @active_tab
      @selection_start = nil
      @selection_end = nil
      SelectionManager.forget_window(self)
    end
    draw_tab_bar
  end

  # Switch to a specific tab by name.
  # Clears the activity indicator and redraws the content area.
  #
  # @param name [String] the tab name to switch to
  # @return [void]
  def switch_tab(name)
    return unless @tab_buffers.key?(name)
    return if name == @active_tab

    # Selection line IDs are per-tab; a stale selection would map onto
    # unrelated text in the new tab
    drop_selection
    @active_tab = name
    @tab_activity[name] = false
    redraw
    draw_tab_bar
  end

  # Switch to the next tab, cycling back to the first after the last.
  #
  # @return [void]
  def next_tab
    return if @tab_buffers.empty?

    tab_names = @tab_buffers.keys
    current_idx = tab_names.index(@active_tab) || 0
    next_idx = (current_idx + 1) % tab_names.length
    switch_tab(tab_names[next_idx])
  end

  # Switch to the previous tab, cycling to the last after the first.
  #
  # @return [void]
  def prev_tab
    return if @tab_buffers.empty?

    tab_names = @tab_buffers.keys
    current_idx = tab_names.index(@active_tab) || 0
    prev_idx = (current_idx - 1) % tab_names.length
    switch_tab(tab_names[prev_idx])
  end

  # Switch to a tab by its 1-based index.
  #
  # @param index [Integer] 1-based tab position
  # @return [void]
  def switch_tab_by_index(index)
    tab_names = @tab_buffers.keys
    return if index < 1 || index > tab_names.length

    switch_tab(tab_names[index - 1])
  end

  # Draw the tab bar at the top of the window.
  # Active tab is rendered with reverse video; background tabs with
  # unread content show an asterisk (*) activity indicator. A bar wider
  # than the window is cut off at its right edge (tabs past it are still
  # reachable by index or cycling), so it never spills onto the text rows.
  #
  # @return [void]
  def draw_tab_bar
    setpos(0, 0)
    clrtoeol

    tab_names = @tab_buffers.keys
    # Writing a window's last column moves the cursor to the next row,
    # which scrolls a one-row window: leave that column blank there.
    room = maxy > 1 ? maxx : maxx - 1

    tab_names.each_with_index do |name, idx|
      activity = @tab_activity[name] && name != @active_tab ? '*' : ''
      label = " #{idx + 1}:#{name}#{activity} "

      room = add_tab_bar_text(label, room, name == @active_tab ? Curses::A_REVERSE : Curses::A_NORMAL)
      room = add_tab_bar_text('|', room) if idx < tab_names.length - 1
    end

    noutrefresh
  end

  # First window row of the text area: the row below the tab bar.
  #
  # @return [Integer]
  def content_top
    TAB_BAR_HEIGHT
  end

  # Height of the content area excluding the tab bar.
  #
  # @return [Integer] number of rows available for text content
  def content_height
    maxy - TAB_BAR_HEIGHT
  end

  # Resize the window and set its scroll region to the text rows again.
  # ncurses keeps a region across a resize (a region it refused, in a
  # window of one or two rows, stays the whole window), so without this
  # a window that grew would scroll its tab bar away with the text.
  #
  # @param height [Integer] new height in rows
  # @param width [Integer] new width in columns
  # @return [void]
  def resize(height, width)
    super
    setscrreg(TAB_BAR_HEIGHT, maxy - 1)
  end

  # Show the window again after {#move_to_layout} moved it: move its
  # scrollbar, if it has one, beside it, re-wrap every tab's lines to the
  # new width, clear the scrollbar and redraw the tab bar and text. The
  # scrollbar is drawn again only if the window is the active one.
  #
  # @return [void]
  # @api private
  def redraw_after_resize
    fit_scrollbar if scrollbar
    rewrap
    clear_scrollbar
    redraw
    noutrefresh
  end

  # Scroll the text rows. ncurses refuses a scroll region of one row, so
  # with a single text row the region is the whole window and scrolling
  # it would move the tab bar too: blank that row instead, which is all
  # scrolling a one-row region does, and let the caller redraw it.
  #
  # @param lines [Integer] rows to scroll (negative = down)
  # @return [void]
  def scrl(lines)
    return super unless content_height == 1

    setpos(content_top, 0)
    clrtoeol
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
    target_tab = stream && @tab_buffers.key?(stream) ? stream : (@active_tab || MAIN_STREAM)
    add_string_to_tab(target_tab, text, colors, indent: indent)
  end

  # Prompts land in the "main" tab, whichever tab is shown.
  #
  # @return [LineBuffer, nil] nil when the window has no "main" tab
  private def prompt_buffer
    @tab_buffers[MAIN_STREAM]
  end

  # Append a string to a specific tab's buffer.
  # If the tab is active and not scrolled, the text is rendered immediately.
  # Background tabs receive an activity indicator on the tab bar.
  #
  # @param tab_name [String] the target tab name
  # @param string [String] the text to append
  # @param string_colors [Array<Hash>] color region descriptors
  # @param indent [Boolean, nil] indent continuation lines (nil = window default)
  # @return [void]
  def add_string_to_tab(tab_name, string, string_colors = [], indent: nil)
    return unless @tab_buffers.key?(tab_name)

    shown = tab_name == @active_tab
    append_string(@tab_buffers[tab_name], string, string_colors, indent: indent, shown: shown) do
      unless @tab_activity[tab_name]
        @tab_activity[tab_name] = true
        draw_tab_bar
      end
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

  # Redraw the active tab's content area and tab bar, and the scrollbar
  # if the window is the active one (see {#update_scrollbar}): an
  # inactive window's scrollbar is left as it is, blank.
  #
  # @return [void]
  def redraw
    draw_tab_bar
    return unless @active_tab

    tab_buffer = @tab_buffers[@active_tab]
    ch = content_height

    (TAB_BAR_HEIGHT...maxy).each do |y|
      setpos(y, 0)
      clrtoeol
    end

    return if tab_buffer.empty?

    visible_lines = tab_buffer.visible_count(ch)
    return if visible_lines <= 0

    visible_lines.times do |i|
      _id, line_data = tab_buffer.line_at_row(i, ch)
      next unless line_data

      setpos(TAB_BAR_HEIGHT + i, 0)
      add_line(line_data[0], line_data[1])
    end

    update_scrollbar
    noutrefresh
  end

  # Repaint the tab bar and the active tab's visible text from its buffer
  # (see {BaseWindow#repaint}), as {#redraw} does.
  #
  # @return [void]
  def repaint
    redraw
  end

  # Refresh the scrollbar, as {LineBuffered#update_scrollbar} does, but
  # only while the window is the active one (the one the scroll keys act
  # on, see {LineBuffered#set_active}). An inactive tabbed window shows no
  # scrollbar: {LineBuffered#set_active} clears it when the window stops
  # being active, and nothing draws it again until the window is active:
  # not lines arriving, a redraw (a resize, a layout reusing the window, a
  # tab switch, clearing a selection) or a scroll (a drag held at the
  # window's edge scrolls an inactive window).
  #
  # @return [void]
  def update_scrollbar
    super if active?
  end

  # The active tab's buffer.
  #
  # @return [LineBuffer, nil] nil before the first tab is added
  private def shown_buffer
    @tab_buffers[@active_tab]
  end

  # Write tab-bar text at the cursor, cut to the columns the bar has left.
  #
  # @param text [String] the text to write
  # @param room [Integer] columns left for the tab bar
  # @param attrs [Integer] curses attributes for the text
  # @return [Integer] columns left after writing
  private def add_tab_bar_text(text, room, attrs = Curses::A_NORMAL)
    shown = text[0, [room, 0].max]
    attron(attrs) { addstr(shown) } unless shown.empty?
    room - shown.length
  end

  # Every tab's buffer.
  #
  # @return [Array<LineBuffer>]
  private def line_buffers
    @tab_buffers.values
  end
end

BaseWindow.register_type('tabbed') do |height, width, top, left, element, wm|
  next nil unless width > 1

  tab_names = (element.attributes['tabs'] || element.attributes['value'] || MAIN_STREAM).split(',').map(&:strip)
  # Reuse the previous layout's tabbed window that has any of these tabs
  unless (window = wm.claim_window(:stream, tab_names, TabbedTextWindow))
    window = TabbedTextWindow.new(height, width - TabbedTextWindow.right_margin, top, left)
    window.add_scrollbar
  end
  window.scrollok(true)
  window.setscrreg(1, window.maxy - 1)
  window.max_buffer_size = element.attributes['buffer-size'] || 1000
  window.time_stamp = BaseWindow.parse_flag_attr(element, 'timestamp')
  window.clock = wm.clock
  window.keep_tabs(tab_names)
  tab_names.each do |tab_name|
    wm.stream[tab_name] = window
  end
  window.redraw
  SCROLL_WINDOW.push(window) unless SCROLL_WINDOW.include?(window)
  window
end
