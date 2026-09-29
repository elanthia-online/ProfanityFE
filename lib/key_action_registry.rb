# frozen_string_literal: true

# The named key actions a settings file can bind a key to
# (+<key id='ctrl+a' action='cursor_home'/>+), as Procs by name.
#
# Command-line editing and history recall act on the {CommandBuffer};
# scrolling acts on the current scroll window (+SCROLL_WINDOW[0]+); tab
# actions act on every {TabbedTextWindow}; +resize+ refits the layout
# through the {WindowManager}; +switch_arrow_mode+ rebinds the up and down
# arrows in the key binding map. Sending a command is not done here: the
# +send_command+ and +send_last_command+ family call back into the owner,
# which echoes and dispatches the line.
#
# Each cursor/edit action delegates to {CommandBuffer}, which only stages
# its changes to the curses virtual screen via +noutrefresh+. The physical
# terminal is not repainted until +doupdate+ is called, so *every* action
# that changes the screen must end with {CommandBuffer#flush_screen},
# which also leaves the terminal cursor on the command line. Omitting it
# leaves the edit invisible until the next keystroke happens to trigger a
# flush -- the class of bug that previously affected
# +cursor_backspace_word+, +cursor_delete_word+, and +cursor_yank+.
#
# @example
#   actions = KeyActionRegistry.new(cmd_buffer: cmd_buffer, window_mgr: window_mgr,
#                                   key_binding: key_binding,
#                                   send_command: -> { ... },
#                                   send_history_command: ->(index) { ... }).actions
#   actions['cursor_home'].call
#
# @see CommandBuffer#backspace_word
# @see CommandBuffer#flush_screen
class KeyActionRegistry
  # @return [Hash{String => Proc}] the actions by name; +switch_tab+ and
  #   +switch_tab_reverse+ are the same Procs as +next_tab+ and +prev_tab+
  attr_reader :actions

  # @param cmd_buffer [CommandBuffer] the command line
  # @param window_mgr [WindowManager] resizes the layout and gives the main
  #   window that autocomplete lists candidates in
  # @param key_binding [Hash] the key binding map (key code => Proc or
  #   combo Hash) that +switch_arrow_mode+ rebinds
  # @param send_command [#call] sends the command line; called with no
  #   arguments
  # @param send_history_command [#call] resends a history entry; called
  #   with its index (1 = the last command sent)
  def initialize(cmd_buffer:, window_mgr:, key_binding:, send_command:, send_history_command:)
    @cmd_buffer = cmd_buffer
    @window_mgr = window_mgr
    @key_binding = key_binding
    @send_command = send_command
    @send_history_command = send_history_command
    @actions = {}
    register_editing_actions
    register_window_actions
    register_history_actions
  end

  private

  # +resize+ and the command-line cursor and edit actions.
  #
  # @return [void]
  def register_editing_actions
    @actions['resize'] = proc {
      @window_mgr.resize(@cmd_buffer)
      @cmd_buffer.flush_screen
    }

    @actions['cursor_left']           = proc { @cmd_buffer.cursor_left; @cmd_buffer.flush_screen }
    @actions['cursor_right']          = proc { @cmd_buffer.cursor_right; @cmd_buffer.flush_screen }
    @actions['cursor_word_left']      = proc { @cmd_buffer.cursor_word_left; @cmd_buffer.flush_screen }
    @actions['cursor_word_right']     = proc { @cmd_buffer.cursor_word_right; @cmd_buffer.flush_screen }
    @actions['cursor_home']           = proc { @cmd_buffer.cursor_home; @cmd_buffer.flush_screen }
    @actions['cursor_end']            = proc { @cmd_buffer.cursor_end; @cmd_buffer.flush_screen }
    @actions['cursor_backspace']      = proc { @cmd_buffer.backspace; @cmd_buffer.flush_screen }
    @actions['cursor_delete']         = proc { @cmd_buffer.delete_char; @cmd_buffer.flush_screen }
    @actions['cursor_backspace_word'] = proc { @cmd_buffer.backspace_word; @cmd_buffer.flush_screen }
    @actions['cursor_delete_word']    = proc { @cmd_buffer.delete_word; @cmd_buffer.flush_screen }
    @actions['cursor_kill_forward']   = proc { @cmd_buffer.kill_forward; @cmd_buffer.flush_screen }
    @actions['cursor_kill_line']      = proc { @cmd_buffer.kill_line; @cmd_buffer.flush_screen }
    @actions['cursor_yank']           = proc { @cmd_buffer.yank; @cmd_buffer.flush_screen }
  end

  # The scroll-window, tab and scrolling actions.
  #
  # @return [void]
  def register_window_actions
    @actions['switch_current_window'] = proc {
      SCROLL_WINDOW[0]&.set_active(false)
      SCROLL_WINDOW.push(SCROLL_WINDOW.shift)
      SCROLL_WINDOW[0]&.set_active(true)
      @cmd_buffer.flush_screen
    }

    @actions['next_tab'] = proc {
      TabbedTextWindow.list.each(&:next_tab)
      @cmd_buffer.flush_screen
    }
    @actions['switch_tab'] = @actions['next_tab']

    @actions['prev_tab'] = proc {
      TabbedTextWindow.list.each(&:prev_tab)
      @cmd_buffer.flush_screen
    }
    @actions['switch_tab_reverse'] = @actions['prev_tab']

    (1..5).each do |n|
      @actions["switch_tab_#{n}"] = proc {
        TabbedTextWindow.list.each { |w| w.switch_tab_by_index(n) }
        @cmd_buffer.flush_screen
      }
    end

    @actions['scroll_current_window_up_one'] = proc {
      SCROLL_WINDOW[0]&.scroll_lines(-1)
      @cmd_buffer.flush_screen
    }

    @actions['scroll_current_window_down_one'] = proc {
      SCROLL_WINDOW[0]&.scroll_lines(1)
      @cmd_buffer.flush_screen
    }

    @actions['scroll_current_window_up_page'] = proc {
      if (w = SCROLL_WINDOW[0])
        w.scroll_lines(0 - w.maxy + 1)
      end
      @cmd_buffer.flush_screen
    }

    @actions['scroll_current_window_down_page'] = proc {
      if (w = SCROLL_WINDOW[0])
        w.scroll_lines(w.maxy - 1)
      end
      @cmd_buffer.flush_screen
    }

    @actions['scroll_current_window_bottom'] = proc {
      # buffer_pos counts rows; the buffer size counts (wrapped) lines
      SCROLL_WINDOW[0]&.scroll_lines(SCROLL_WINDOW[0]&.buffer_pos)
      @cmd_buffer.flush_screen
    }
  end

  # History recall, the arrow-mode switch, sending and autocomplete.
  #
  # @return [void]
  def register_history_actions
    @actions['previous_command'] = proc { @cmd_buffer.previous_command; @cmd_buffer.flush_screen }
    @actions['next_command']     = proc { @cmd_buffer.next_command; @cmd_buffer.flush_screen }

    @actions['switch_arrow_mode'] = proc {
      if @key_binding[Curses::KEY_UP] == @actions['previous_command']
        @key_binding[Curses::KEY_UP] = @actions['scroll_current_window_up_page']
        @key_binding[Curses::KEY_DOWN] = @actions['scroll_current_window_down_page']
      elsif @key_binding[Curses::KEY_UP] == @actions['scroll_current_window_up_page']
        @key_binding[Curses::KEY_UP] = @actions['scroll_current_window_up_one']
        @key_binding[Curses::KEY_DOWN] = @actions['scroll_current_window_down_one']
      else
        @key_binding[Curses::KEY_UP] = @actions['previous_command']
        @key_binding[Curses::KEY_DOWN] = @actions['next_command']
      end
    }

    @actions['send_command']             = proc { @send_command.call }
    @actions['send_last_command']        = proc { @send_history_command.call(1) }
    @actions['send_second_last_command'] = proc { @send_history_command.call(2) }
    @actions['autocomplete']             = proc { Autocomplete.complete(@cmd_buffer, @window_mgr.stream[MAIN_STREAM]) }
  end
end
