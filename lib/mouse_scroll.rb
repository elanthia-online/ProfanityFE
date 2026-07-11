# frozen_string_literal: true

require_relative 'profanity_settings'

=begin
Configurable mouse scroll wheel support.
Ported from elanthia-online/ProfanityFE.
=end

# Handles mouse scroll wheel events for window scrolling.
#
# Scroll wheel button masks vary by terminal emulator, so this class
# supports a calibration mode (`.scrollcfg`) that detects and saves
# the correct masks to +~/.profanity/settings.json+.
#
# @example
#   mouse = MouseScroll.new(key_action, display_callback)
#   mouse.process(ch)          # call from input loop on KEY_MOUSE
#   mouse.start_configuration  # call from .scrollcfg command
class MouseScroll
  MIN_EVENT_COUNT = 20

  # Bitmask for mouse events when .links is active.
  # BUTTON1 press/release/click for link detection and drag-to-select.
  # Does NOT include REPORT_MOUSE_POSITION in the steady state — a
  # constant motion-event stream corrupts the display. Motion reporting
  # is added only while button 1 is held (see {#begin_drag_capture}).
  CLICK_EVENTS = Curses::BUTTON1_PRESSED | Curses::BUTTON1_RELEASED |
                 (defined?(Curses::BUTTON1_CLICKED) ? Curses::BUTTON1_CLICKED : 0)

  # Bitmask for pointer motion reports, used for live drag highlight.
  # Zero when the curses build doesn't expose it (feature degrades to
  # highlight-on-release).
  MOTION_EVENTS = defined?(Curses::REPORT_MOUSE_POSITION) ? Curses::REPORT_MOUSE_POSITION : 0

  # @return [Boolean] whether the live drag highlight is enabled.
  #   When false, selection falls back to highlight-on-release and no
  #   motion events are ever requested from the terminal.
  attr_reader :drag_highlight

  # @param key_action [Hash<String, Proc>] the key action registry
  # @param display_fn [Proc] callback to display messages: display_fn.call(text)
  def initialize(key_action, display_fn)
    @key_action = key_action
    @display_fn = display_fn
    @config_state = :idle
    @listener_enabled = false
    @button4_mask = nil
    @button5_mask = nil
    @bstate_counts = {}

    @click_events_enabled = false
    @drag_highlight = ProfanitySettings.load_setting('DRAG_HIGHLIGHT', true)
    @saved_mouseinterval = nil
    load_settings
  end

  # Process a mouse event from the input loop.
  # Accepts either a key code (legacy) or a pre-fetched mouse event object.
  # When called with a mouse event, avoids double-consuming via Curses.getmouse.
  #
  # @param event [Integer, Curses::MouseEvent] KEY_MOUSE code or a mouse event object
  # @return [void]
  def process(event)
    if event.is_a?(Integer)
      return unless event == Curses::KEY_MOUSE

      m = Curses.getmouse
    else
      m = event
    end
    return unless m

    bstate = m.respond_to?(:bstate) ? m.bstate : nil
    return if bstate.nil?

    if configuring?
      configure(bstate)
    else
      handle_scroll(bstate)
    end
  rescue StandardError => e
    ProfanityLog.write('MouseScroll', e.message)
  end

  # Start scroll wheel calibration mode.
  #
  # @return [void]
  def start_configuration
    if configuring?
      reset_configuration
      @display_fn.call('[PROFANITY] Scroll configuration cancelled')
      return
    end

    @bstate_counts = {}
    @config_state = :up
    Curses.mousemask(Curses::ALL_MOUSE_EVENTS | Curses::REPORT_MOUSE_POSITION)
    @display_fn.call('[PROFANITY] Scroll up with your mouse wheel or trackpad')
  end

  # Whether calibration is in progress.
  #
  # @return [Boolean]
  def configuring?
    @config_state != :idle
  end

  # Enable mouse click events for clickable links and drag-to-select.
  # Called when .links or .select is toggled on.
  #
  # With drag highlight on, click resolution is also disabled
  # (mouseinterval 0) so presses and releases arrive raw — the
  # application's own click-vs-drag heuristic takes over, and no events
  # are buffered waiting to synthesize BUTTON1_CLICKED.
  #
  # @return [void]
  def enable_click_events
    @click_events_enabled = true
    suppress_click_resolution if @drag_highlight
    apply_mouse_mask
  end

  # Disable mouse click events, restoring native terminal selection.
  # Called when .links / .select are toggled off.
  #
  # @return [void]
  def disable_click_events
    @click_events_enabled = false
    restore_click_resolution
    apply_mouse_mask
  end

  # Toggle the live drag highlight. Adjusts click resolution to match
  # if mouse capture is currently active, and persists the choice.
  #
  # @param value [Boolean] true to highlight while dragging
  # @return [void]
  def drag_highlight=(value)
    @drag_highlight = value
    if @click_events_enabled
      value ? suppress_click_resolution : restore_click_resolution
    end
    ProfanitySettings.save_setting('DRAG_HIGHLIGHT', value)
  end

  # Add pointer-motion reporting to the mouse mask for the duration of
  # a button-1 drag. Called on press; {#end_drag_capture} restores the
  # steady-state mask on release. Keeping motion reporting scoped to
  # the drag avoids the constant event stream that corrupts the display.
  #
  # @return [void]
  def begin_drag_capture
    return unless @click_events_enabled && @drag_highlight && MOTION_EVENTS.nonzero?

    Curses.mousemask(base_mask | MOTION_EVENTS)
  end

  # Restore the steady-state mouse mask after a drag ends.
  #
  # @return [void]
  def end_drag_capture
    apply_mouse_mask if @click_events_enabled
  end

  private

  # Compute the steady-state mouse mask from scroll and click event bits.
  #
  # @return [Integer]
  def base_mask
    mask = 0
    mask |= @button4_mask | @button5_mask if @button4_mask && @button5_mask
    mask |= CLICK_EVENTS if @click_events_enabled
    mask
  end

  # Apply the current mouse mask combining scroll and click event bits.
  #
  # @return [void]
  def apply_mouse_mask
    mask = base_mask
    if mask.nonzero?
      Curses.mousemask(mask)
      @listener_enabled = true
    elsif @listener_enabled
      Curses.mousemask(0)
      @listener_enabled = false
    end
  end

  # Stop ncurses from buffering press/release pairs to synthesize
  # click events; remembers the previous interval for restoration.
  #
  # @return [void]
  def suppress_click_resolution
    return unless Curses.respond_to?(:mouseinterval)

    previous = Curses.mouseinterval(0)
    @saved_mouseinterval ||= previous
  end

  # Restore the click-resolution interval saved by
  # {#suppress_click_resolution}, if any.
  #
  # @return [void]
  def restore_click_resolution
    return unless @saved_mouseinterval && Curses.respond_to?(:mouseinterval)

    Curses.mouseinterval(@saved_mouseinterval)
    @saved_mouseinterval = nil
  end

  # Load saved scroll button masks from settings and enable the mouse listener.
  #
  # @return [void]
  def load_settings
    settings = ProfanitySettings.load_mouse_settings
    return unless settings

    @button4_mask = settings['BUTTON4_PRESSED_MASK']
    @button5_mask = settings['BUTTON5_PRESSED_MASK']

    return unless @button4_mask && @button5_mask

    apply_mouse_mask
  end

  # Cancel calibration and reset state to idle.
  #
  # @return [void]
  def reset_configuration
    @config_state = :idle
    @bstate_counts = {}
  end

  # Process a mouse event during calibration to detect scroll-up/down masks.
  #
  # @param bstate [Integer] the mouse button state bitmask
  # @return [void]
  def configure(bstate)
    case @config_state
    when :up
      @bstate_counts[bstate] = (@bstate_counts[bstate] || 0) + 1
      return unless @bstate_counts[bstate] >= MIN_EVENT_COUNT

      @button4_mask = bstate
      @config_state = :down
      @bstate_counts = {}
      @display_fn.call('[PROFANITY] Scroll down with your mouse wheel or trackpad')
    when :down
      return if bstate == @button4_mask

      @bstate_counts[bstate] = (@bstate_counts[bstate] || 0) + 1
      return unless @bstate_counts[bstate] >= MIN_EVENT_COUNT

      @button5_mask = bstate
      @config_state = :idle
      @bstate_counts = {}
      apply_mouse_mask
      ProfanitySettings.save_mouse_settings(@button4_mask, @button5_mask)
      @display_fn.call('[PROFANITY] Scroll wheel configuration complete!')
    end
  end

  # Dispatch a scroll-up or scroll-down action based on the button state.
  #
  # @param bstate [Integer] the mouse button state bitmask
  # @return [void]
  def handle_scroll(bstate)
    return unless @button4_mask && @button5_mask

    apply_mouse_mask unless @listener_enabled

    if (bstate & @button4_mask).nonzero?
      @key_action['scroll_current_window_up_one']&.call
    elsif (bstate & @button5_mask).nonzero?
      @key_action['scroll_current_window_down_one']&.call
    end
  end
end
