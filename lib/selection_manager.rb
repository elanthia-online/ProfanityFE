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
  @active_window = nil
  @press_y = nil
  @press_x = nil
  @start_id = nil
  @start_x = nil
  @end_id = nil
  @end_x = nil
  @selecting = false

  class << self
    attr_reader :active_window, :start_id, :start_x, :end_id, :end_x, :selecting

    # Return the window-relative [y, x] press coordinates, or nil if no
    # selection. Used by the input loop's click-vs-drag heuristic, which
    # compares screen positions — not buffer anchors.
    #
    # @return [Array<Integer>, nil] [y, x] pair or nil
    def start_pos
      @press_y && @press_x ? [@press_y, @press_x] : nil
    end

    # Begin a new text selection at the given window coordinates.
    # Clears any previous selection highlight first, then resolves the
    # press position to a stable [line_id, x] anchor immediately — before
    # any incoming text can shift the buffer under it.
    #
    # @param window [BaseWindow] the window where selection starts
    # @param y [Integer] starting row (window-relative)
    # @param x [Integer] starting column (window-relative)
    # @return [void]
    def start_selection(window, y, x)
      clear_selection
      @active_window = window
      @press_y = y
      @press_x = x
      if (anchor = window.selection_anchor_at(y, x))
        @start_id, @start_x = anchor
        @end_id, @end_x = anchor
      end
      @selecting = true
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

    # Finalize the selection and copy text to the clipboard.
    # The highlight is kept visible until the next selection or click.
    #
    # @return [void]
    def end_selection
      return unless @selecting && @active_window

      @selecting = false
      return unless @start_id && @end_id

      text = @active_window.extract_selection(@start_id, @start_x, @end_id, @end_x)
      if text && !text.empty?
        copy_to_clipboard(text)
      else
        ProfanityLog.write('SelectionManager', "No text extracted: start=(#{@start_id},#{@start_x}) end=(#{@end_id},#{@end_x})")
      end
      # Keep highlight visible — cleared on next start_selection or clear_selection
    end

    # Reset all selection state and clear any active highlight.
    #
    # @return [void]
    def clear_selection
      @active_window&.clear_highlight
      @active_window = nil
      @press_y = @press_x = nil
      @start_id = @start_x = @end_id = @end_x = nil
      @selecting = false
    end

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
