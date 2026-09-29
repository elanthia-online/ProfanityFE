# frozen_string_literal: true

# Handles mouse events (KEY_MOUSE): the scroll wheel, drag-to-select with
# copy to the clipboard, and clicks on in-game links.
#
# Owns the {MouseScroll}, which learns and applies the wheel buttons and
# switches mouse capture on and off. Selection state lives in
# {SelectionManager}; a finished selection is copied and a short notice is
# shown with the +write_to_client+ callback. A click on a link echoes the
# link's command after the prompt in the main window, adds it to the
# history and sends it with the +send_to_server+ callback, but only while
# links are on (+SharedState#blue_links+).
#
# @example
#   mouse = MouseController.new(key_action: key_action, window_mgr: window_mgr,
#                               shared_state: shared_state, cmd_buffer: cmd_buffer,
#                               write_to_client: method(:write_to_client),
#                               send_to_server: connection.method(:send_line),
#                               links: cli_options[:links])
#   mouse.handle_event if ch == Curses::KEY_MOUSE
class MouseController
  # @return [MouseScroll] the scroll wheel handler and mouse capture switch
  attr_reader :mouse_scroll

  # @param key_action [Hash{String => Proc}] the key actions; the wheel
  #   runs +scroll_current_window_up_one+/+scroll_current_window_down_one+
  # @param window_mgr [WindowManager] gives the main window link commands
  #   are echoed in
  # @param shared_state [SharedState] whether links are on, and the prompt
  # @param cmd_buffer [CommandBuffer] the history a clicked link is added
  #   to; flushes the screen (see {CommandBuffer#flush_screen})
  # @param write_to_client [#call] shows feedback lines in the main window;
  #   returns whether there was one (see {Application}'s +write_to_client+)
  # @param send_to_server [#call] sends one line to the game server
  # @param links [Boolean] start with click events on (--links)
  def initialize(key_action:, window_mgr:, shared_state:, cmd_buffer:, write_to_client:, send_to_server:, links:)
    @window_mgr = window_mgr
    @shared_state = shared_state
    @cmd_buffer = cmd_buffer
    @write_to_client = write_to_client
    @send_to_server = send_to_server
    @mouse_scroll = MouseScroll.new(key_action, write_to_client)
    @mouse_scroll.enable_click_events if links
  end

  # Handle one mouse event, read with +Curses.getmouse+. While
  # +.scrollcfg+ is learning the wheel, the event only goes to it.
  #
  # @return [void]
  def handle_event
    mouse = Curses.getmouse
    return unless mouse

    if @mouse_scroll.configuring?
      @mouse_scroll.process(mouse)
      return
    end
    @mouse_scroll.process(mouse)

    screen_y = mouse.y
    screen_x = mouse.x
    bstate = mouse.bstate

    if (bstate & Curses::BUTTON1_PRESSED) != 0
      handle_press(screen_y, screen_x)
    elsif (bstate & Curses::BUTTON1_RELEASED) != 0
      handle_release(screen_y, screen_x)
    elsif defined?(Curses::BUTTON1_CLICKED) && (bstate & Curses::BUTTON1_CLICKED) != 0
      SelectionManager.clear_selection
      window = BaseWindow.find_window_at(screen_y, screen_x)
      if window
        rel_y = screen_y - window.begy
        rel_x = screen_x - window.begx
        dispatch_link(window, rel_y, rel_x)
      end
    elsif MouseScroll::MOTION_EVENTS.nonzero? && (bstate & MouseScroll::MOTION_EVENTS) != 0
      handle_drag(screen_y, screen_x)
    end
  end

  # While a drag is held at a window's top or bottom edge, keep scrolling
  # one line per input-loop tick (~100ms) and extend the selection.
  # Motion events stop when the pointer stops moving, so the tick drives
  # the repeat.
  #
  # @return [Boolean] true if the screen needs a refresh
  def tick_drag_auto_scroll
    return false unless SelectionManager.selecting

    window = SelectionManager.active_window
    pos = SelectionManager.last_drag_pos
    return false unless window && pos

    scrolled = window.drag_auto_scroll(pos[0])
    SelectionManager.update_selection(pos[0], pos[1]) if scrolled
    scrolled
  end

  private

  # Button 1 pressed: start a selection in the window under the pointer.
  def handle_press(screen_y, screen_x)
    window = BaseWindow.find_window_at(screen_y, screen_x)
    unless window
      SelectionManager.clear_selection
      return
    end

    rel_y = screen_y - window.begy
    rel_x = screen_x - window.begx
    multi_click = SelectionManager.start_selection(window, rel_y, rel_x)
    @cmd_buffer.flush_screen if multi_click
  end

  # Live highlight update from a motion report while button 1 is held.
  # SelectionManager throttles redraws so a motion flood coalesces.
  def handle_drag(screen_y, screen_x)
    window = SelectionManager.active_window
    return unless window && SelectionManager.selecting

    rel_y = screen_y - window.begy
    rel_x = screen_x - window.begx
    @cmd_buffer.flush_screen if SelectionManager.drag_update(rel_y, rel_x)
  end

  # Button 1 released: a click follows a link, a double or triple click or
  # a drag copies the selection. A release on the press's row, at most 3
  # columns from it, ends a click; the link it follows is the one under
  # the press, the cell the user aimed at. A double or triple click whose
  # first click followed a link does nothing more.
  def handle_release(screen_y, screen_x)
    return unless SelectionManager.selecting

    window = SelectionManager.active_window
    unless window
      SelectionManager.clear_selection
      return
    end

    rel_y = screen_y - window.begy
    rel_x = screen_x - window.begx
    start_pos = SelectionManager.start_pos

    if start_pos && start_pos[0] == rel_y && (start_pos[1] - rel_x).abs <= 3
      if SelectionManager.multi_click_selected?
        # Double/triple click: copy the expanded word/line selection
        finalize_selection
      elsif SelectionManager.repeats_link_click?
        # Double/triple click on a link just followed: nothing more
        SelectionManager.clear_selection
      else
        # Single click (no drag): check for a link under the press, skip selection
        SelectionManager.link_followed if dispatch_link(window, *start_pos)
        SelectionManager.clear_selection
      end
    else
      # Actual drag: finalize selection and copy to clipboard
      SelectionManager.update_selection(rel_y, rel_x)
      finalize_selection
    end
  end

  # Copy the finished selection and show brief feedback in the main window.
  def finalize_selection
    chars = SelectionManager.end_selection
    # write_to_client flushes when it shows the notice
    return if chars&.positive? && @write_to_client.call("* [copied #{chars} chars]")

    @cmd_buffer.flush_screen
  end

  # Send the command of the link at a window position, if links are on
  # and there is one there.
  def dispatch_link(window, rel_y, rel_x)
    # Links may be toggled off while selection capture (.select) stays on;
    # lines rendered earlier can still carry cmd runs that must not fire
    return unless @shared_state.blue_links

    if (link_cmd = window.link_cmd_at(rel_y, rel_x))
      if (main = @window_mgr.stream[MAIN_STREAM])
        @window_mgr.add_prompt(main, @shared_state.prompt_text, link_cmd)
        @cmd_buffer.flush_screen
      end
      @cmd_buffer.add_to_history(link_cmd)
      @send_to_server.call(link_cmd)
      true
    end
  end
end
