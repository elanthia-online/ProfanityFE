# frozen_string_literal: true

# selection_manager.rb: Mouse text selection and clipboard operations for ProfanityFE.

# Manages mouse text selection state and clipboard operations.
# Active when .links is enabled (which captures mouse events).
# Selection is per-window: drag coordinates are clamped to the
# active window's bounds so selections never bleed across windows.
#
# Endpoints are anchored to stable buffer line IDs (see
# {AnchoredSelection}) at press time, so the selection stays glued to
# the same text even when new lines arrive or the user scrolls between
# press and release. The raw press coordinates are kept separately for
# the click-vs-drag heuristic in the input loop.
#
# The highlight persists after release so the user can see what was
# selected. It is cleared on the next mouse press or link click.
# Selected text is copied to the system clipboard (pbcopy/xclip/wl-copy),
# OSC 52 (for remote/SSH sessions), and /tmp/profanity_selection.txt.
module SelectionManager
  # Minimum seconds between highlight redraws during a live drag.
  # Motion events can flood; redrawing every one of them is what caused
  # display corruption in earlier drag-highlight attempts.
  DRAG_REDRAW_INTERVAL = 0.05

  # Maximum seconds between presses for double/triple-click detection.
  MULTI_CLICK_INTERVAL = 0.4

  @active_window = nil
  @press_y = nil
  @press_x = nil
  @start_id = nil
  @start_x = nil
  @end_id = nil
  @end_x = nil
  @selecting = false
  @last_drag_pos = nil
  @last_drag_redraw = nil
  @click_count = 0
  @last_press_time = nil
  @last_press_window = nil
  @last_press_y = nil
  @last_press_x = nil
  @multi_click_selected = false

  class << self
    attr_reader :active_window, :start_id, :start_x, :end_id, :end_x, :selecting,
                :last_drag_pos, :click_count

    # Return the window-relative [y, x] press coordinates, or nil if no
    # selection. Used by the input loop's click-vs-drag heuristic, which
    # compares screen positions — not buffer anchors.
    #
    # @return [Array<Integer>, nil] [y, x] pair or nil
    def start_pos
      @press_y && @press_x ? [@press_y, @press_x] : nil
    end

    # Whether the current press expanded to a word/line selection via
    # double/triple-click. The release handler copies this selection
    # instead of dispatching a link click.
    #
    # @return [Boolean]
    def multi_click_selected?
      @multi_click_selected
    end

    # Begin a new text selection at the given window coordinates.
    # Clears any previous selection highlight first, then resolves the
    # press position to a stable [line_id, x] anchor immediately — before
    # any incoming text can shift the buffer under it.
    #
    # Rapid repeat presses at the same spot count as double/triple clicks
    # and expand the selection to the word / logical line under the cursor.
    #
    # @param window [BaseWindow] the window where selection starts
    # @param y [Integer] starting row (window-relative)
    # @param x [Integer] starting column (window-relative)
    # @param now [Float, nil] monotonic clock override for tests
    # @return [Boolean] true if a multi-click expanded the highlight
    #   (the caller should refresh the screen)
    def start_selection(window, y, x, now: nil)
      now ||= monotonic_now
      count_click(window, y, x, now)
      clear_selection
      @active_window = window
      @press_y = y
      @press_x = x
      if (anchor = window.selection_anchor_at(y, x))
        @start_id, @start_x = anchor
        @end_id, @end_x = anchor
      end
      @selecting = true
      @multi_click_selected = expand_multi_click
    end

    # Extend the current selection to a new endpoint and redraw highlights.
    # The endpoint is resolved against the window's current scroll/buffer
    # state, so dragging works even after the content has moved.
    #
    # @param y [Integer] new end row (window-relative)
    # @param x [Integer] new end column (window-relative)
    # @return [void]
    def update_selection(y, x)
      return unless @selecting && @active_window && @start_id

      anchor = @active_window.selection_anchor_at(y, x)
      return unless anchor

      @end_id, @end_x = anchor
      @active_window.highlight_selection(@start_id, @start_x, @end_id, @end_x)
    end

    # Live-drag update from a mouse motion event, throttled so a flood
    # of motion reports coalesces into at most one redraw per
    # {DRAG_REDRAW_INTERVAL}. The drag position is always recorded (for
    # edge auto-scroll) even when the redraw is skipped.
    #
    # @param y [Integer] pointer row (window-relative)
    # @param x [Integer] pointer column (window-relative)
    # @param now [Float, nil] monotonic clock override for tests
    # @return [Boolean] true if the highlight was redrawn
    def drag_update(y, x, now: nil)
      return false unless @selecting && @active_window && @start_id

      @last_drag_pos = [y, x]
      now ||= monotonic_now
      return false if @last_drag_redraw && (now - @last_drag_redraw) < DRAG_REDRAW_INTERVAL

      @last_drag_redraw = now
      update_selection(y, x)
      true
    end

    # Finalize the selection and copy text to the clipboard.
    # The highlight is kept visible until the next selection or click.
    #
    # @return [Integer, nil] number of characters copied, or nil if
    #   nothing was extracted
    def end_selection
      return unless @selecting && @active_window

      @selecting = false
      return unless @start_id && @end_id

      text = @active_window.extract_selection(@start_id, @start_x, @end_id, @end_x)
      if text && !text.empty?
        copy_to_clipboard(text)
        text.length
      else
        ProfanityLog.write('SelectionManager', "No text extracted: start=(#{@start_id},#{@start_x}) end=(#{@end_id},#{@end_x})")
        nil
      end
      # Keep highlight visible — cleared on next start_selection or clear_selection
    end

    # Reset all selection state and clear any active highlight.
    # Multi-click timing memory survives so a double-click's second press
    # (which begins with this reset) still counts.
    #
    # @return [void]
    def clear_selection
      @active_window&.clear_highlight
      @active_window = nil
      @press_y = @press_x = nil
      @start_id = @start_x = @end_id = @end_x = nil
      @selecting = false
      @last_drag_pos = nil
      @last_drag_redraw = nil
      @multi_click_selected = false
    end

    private

    # @return [Float] monotonic clock reading in seconds
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Track rapid repeat presses at the same spot for double/triple-click.
    # Called before the previous press state is cleared.
    #
    # @param window [BaseWindow] the pressed window
    # @param y [Integer] press row (window-relative)
    # @param x [Integer] press column (window-relative)
    # @param now [Float] monotonic clock reading
    # @return [void]
    def count_click(window, y, x, now)
      repeat = @last_press_time &&
               (now - @last_press_time) <= MULTI_CLICK_INTERVAL &&
               @last_press_window.equal?(window) &&
               @last_press_y == y && @last_press_x && (@last_press_x - x).abs <= 1
      @click_count = repeat ? (@click_count % 3) + 1 : 1
      @last_press_time = now
      @last_press_window = window
      @last_press_y = y
      @last_press_x = x
    end

    # Expand the just-anchored selection to the word (double-click) or
    # logical line (triple-click) under the cursor, and highlight it.
    #
    # @return [Boolean] true if the selection was expanded
    def expand_multi_click
      return false unless @click_count >= 2 && @start_id && @active_window.respond_to?(:buffer_content)

      buffer = @active_window.buffer_content
      appended = @active_window.lines_appended

      if @click_count == 2
        text = AnchoredSelection.line_at(buffer, appended, @start_id)
        span = text && AnchoredSelection.word_span(text, @start_x)
        return false unless span

        @start_x, @end_x = span
      else
        first, last = AnchoredSelection.logical_line_span(buffer, appended, @start_id)
        last_text = AnchoredSelection.line_at(buffer, appended, last) || ''
        @start_id = first
        @start_x = 0
        @end_id = last
        @end_x = last_text.length
      end

      @active_window.highlight_selection(@start_id, @start_x, @end_id, @end_x)
      true
    end

    public

    # Copy text to the system clipboard, OSC 52, and a temp file.
    #
    # Tries platform-native clipboard commands first (pbcopy on macOS,
    # xclip or wl-copy on Linux), then OSC 52 for remote/SSH sessions,
    # and always writes to /tmp/profanity_selection.txt as a fallback.
    #
    # @param text [String] the text to copy
    # @return [void]
    def copy_to_clipboard(text)
      # Try platform-native clipboard
      clipboard_cmd = if RbConfig::CONFIG['host_os'] =~ /darwin/
                        'pbcopy'
                      elsif ENV['WAYLAND_DISPLAY']
                        'wl-copy'
                      elsif ENV['DISPLAY']
                        'xclip -selection clipboard'
                      end

      if clipboard_cmd
        IO.popen(clipboard_cmd, 'w') { |io| io.write(text) }
        ProfanityLog.write('Clipboard', "Copied #{text.length} chars via #{clipboard_cmd}")
      else
        ProfanityLog.write('Clipboard', "No clipboard command available (no DISPLAY); using OSC 52 + file")
      end

      # OSC 52 for remote/SSH sessions (write to tty to avoid curses interference)
      # Wrap in DCS passthrough for terminal multiplexers that strip raw OSC 52.
      # GNU Screen limits DCS sequence length, so chunk large selections.
      # Ref: https://nieko.net/blog/osc-52-and-nested-gnu-screen
      encoded = [text].pack('m0')
      begin
        File.open('/dev/tty', 'w') do |tty|
          if ENV['STY']
            # GNU Screen: DCS passthrough with chunking for length limit.
            # Screen's DCS limit is ~768 bytes; chunk base64 at 512 to be safe.
            chunks = encoded.scan(/.{1,512}/)
            chunks.each do |chunk|
              tty.write("\eP\e]52;c;#{chunk}\a\e\\")
            end
          elsif ENV['TMUX']
            # tmux DCS passthrough
            tty.write("\ePtmux;\e\e]52;c;#{encoded}\a\e\\")
          else
            # Direct OSC 52
            tty.write("\e]52;c;#{encoded}\a")
          end
          tty.flush
        end
        ProfanityLog.write('Clipboard', "OSC 52 sent (#{ENV['STY'] ? 'screen' : ENV['TMUX'] ? 'tmux' : 'direct'}, #{encoded.length} bytes)")
      rescue StandardError
        nil # /dev/tty may not be available in all environments
      end

      # Always write to file as fallback
      File.write('/tmp/profanity_selection.txt', text)
    rescue StandardError => e
      ProfanityLog.write('Clipboard', "Error: #{e.message}")
    end
  end
end
