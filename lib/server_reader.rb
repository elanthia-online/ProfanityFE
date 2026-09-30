# frozen_string_literal: true

require_relative 'boot_profiler'
require_relative 'pending_render'

# Reads the game server socket and hands each line to a line handler,
# flushing the screen only when no more server data is waiting.
#
# Owns the read loop, how it ends (a disconnect or a crash), the per-line
# error guard, and the batched flush: handlers record what changed in a
# {PendingRender}, and the screen is drawn once a burst of lines is over.
#
# The line handler (a {GameTextProcessor}) provides:
# - +prepare_line(line)+, called outside the render lock: returns the line
#   to process, or nil to drop it;
# - +process_line(line)+, called inside the render lock.
class ServerReader
  # Socket errors that mean the connection closed normally rather than
  # that ProfanityFE failed: the socket was closed by another thread
  # (IOError), or Lich closed it (ECONNRESET when Lich closes with client
  # data still unread, EPIPE, ECONNABORTED).
  DISCONNECT_ERRORS = [IOError, Errno::ECONNRESET, Errno::EPIPE, Errno::ECONNABORTED].freeze

  # @param line_handler [#prepare_line, #process_line] parses each line
  # @param pending_render [PendingRender] the updates the handler asked for
  # @param event_bus [EventBus] receives +:room_render+ and +:disconnect+
  # @param cmd_buffer [CommandBuffer] its window is refreshed with every flush
  # @param shared_state [SharedState] its terminal title is written after each line
  # @param boot_profiler [BootProfiler] logs when the first server data and
  #   the first screen render arrive (--profile)
  def initialize(line_handler:, pending_render:, event_bus:, cmd_buffer:, shared_state:,
                 boot_profiler: BootProfiler.new(enabled: false))
    @line_handler = line_handler
    @pending = pending_render
    @event_bus = event_bus
    @cmd_buffer = cmd_buffer
    @state = shared_state
    @boot_profiler = boot_profiler
    @first_render = true
  end

  # Read lines from the server until the connection ends, processing each.
  #
  # It does not show the disconnect message or exit: it reports how the
  # connection ended, and {Application} ends the session on the main
  # thread, which owns keyboard input.
  #
  # @param server [IO] TCP socket (or socket-like) connected to the game server
  # @return [Symbol] +:disconnected+ when the connection closed (EOF or one
  #   of {DISCONNECT_ERRORS}); +:crashed+ when any other error ended the
  #   loop (logged with its backtrace)
  def run(server)
    @server = server
    line = nil
    first_line = true

    while (line = server.gets)
      if first_line && @boot_profiler.enabled?
        @boot_profiler.log_elapsed('first server data received')
        first_line = false
      end

      process_server_line(line)
    end
    :disconnected
  rescue *DISCONNECT_ERRORS => e
    ProfanityLog.write('game_text_processor', "disconnected: #{e.class}: #{e.message}")
    :disconnected
  rescue StandardError => e
    ProfanityLog.write('game_text_processor', e.to_s, backtrace: e.backtrace)
    :crashed
  end

  # Show the "Connection closed / Press any key to exit" notice in the
  # main window and flush it to the screen.
  #
  # This is the flush the last burst never got: a closed connection reads
  # as ready, so {#flush_if_idle} skipped it. A room render that burst
  # asked for is drawn here.
  #
  # @return [void]
  def show_disconnect_message
    CursesRenderer.render do
      render_pending_room
      @event_bus.emit(:disconnect)
      @cmd_buffer.window&.noutrefresh
    end
  end

  private

  # Process one line from the server, then flush the screen if no more
  # server data is waiting.
  #
  # A line the handler drops is not processed and writes no terminal
  # title, but the flush still runs: the dropped line may end a burst whose
  # earlier lines staged text.
  #
  # An error in one line is logged and the line is skipped, so a bad line
  # (or a failing window handler) cannot end the session. Connection errors
  # propagate to {#run}, which handles the disconnect. The log names the
  # line as the handler kept it, or the raw line if the handler dropped it.
  #
  # @param line [String] raw line read from the server
  # @return [void]
  # @raise [IOError, SystemCallError] a connection error, passed on to
  #   {#run}
  # @api private
  def process_server_line(line)
    # Socket reads are BINARY. Treat them as UTF-8 (replacing invalid bytes)
    # so a non-ASCII byte can't raise Encoding::CompatibilityError against
    # the UTF-8 gag and highlight patterns loaded from settings.
    line.force_encoding(Encoding::UTF_8).scrub!
    line.chomp!
    kept = @line_handler.prepare_line(line)

    # Synchronize all curses operations (noutrefresh calls from indicator,
    # text, countdown, and room window updates) with the final doupdate so
    # that timer and input threads cannot flush a half-updated virtual screen.
    CursesRenderer.synchronize do
      @line_handler.process_line(kept) unless kept.nil?
      # A dropped line can end a burst: flush what the lines before it staged.
      flush_if_idle
    end
    return if kept.nil?

    # Flush terminal title AFTER curses operations complete.
    # Writing escape sequences to $stdout inside the synchronize block
    # interleaves with curses output, causing visible artifacts.
    @state.update_terminal_title
  rescue IOError, SystemCallError
    raise
  rescue StandardError => e
    ProfanityLog.write('game_text_processor', "error processing line #{(kept || line).inspect}: #{e.message}", backtrace: e.backtrace)
  end

  # Flush the screen update unless more game lines are waiting (batch
  # rendering). IO.select returns nil (no data waiting) when we should
  # flush now. A pending room render is drawn first.
  #
  # @return [void]
  # @api private
  def flush_if_idle
    return unless @pending.update_requested? && !IO.select([@server], nil, nil, 0.001)

    @pending.clear_update
    render_pending_room
    @cmd_buffer.window&.noutrefresh
    Curses.doupdate
    return unless @first_render && @boot_profiler.enabled?

    @boot_profiler.log_elapsed('first screen render')
    @first_render = false
  end

  # Draw the room window if a room render was asked for since the last
  # flush.
  #
  # @return [void]
  # @api private
  def render_pending_room
    return unless @pending.room_render_requested?

    @event_bus.emit(:room_render)
    @pending.clear_room_render
  end
end
