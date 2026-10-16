# frozen_string_literal: true

require 'socket'
require_relative 'server_reader'

# The TCP connection to the game server (Lich).
#
# Opens the socket and announces the front end's PID (and, when asked to,
# the parts of DragonRealms' rich stream it renders; see
# {FRONTEND_CAPABILITIES}), writes commands to it without holding the
# render lock, runs the thread that reads from it, and reports how that
# thread ended so the main thread can end the session.
#
# @example
#   connection = ServerConnection.new(host: '127.0.0.1', port: 8000)
#   connection.connect
#   connection.start_reader { |socket| processor.run(socket) }
#   connection.send_line('look')
#   connection.take_outcome if connection.ended?
class ServerConnection
  # Seconds to wait for the TCP connection to the game server before giving
  # up, so an unreachable --host fails instead of hanging.
  CONNECT_TIMEOUT = 10

  # Seconds {#stop} waits for the reader thread to end.
  STOP_TIMEOUT = 1

  # The parts of DragonRealms' rich stream (the stream the game sends when
  # Lich identifies as the Saga client) that Profanity renders itself, as
  # Lich's +SET_FRONTEND_CAPS+ line names them. A Lich that knows the line
  # (lich-5 #1726) then stops rewriting them to the old stream's shape for
  # this connection:
  #
  # - +room_element+: the inline +<room>+ block, read by TagHandlers (its
  #   parts go on lines of their own and into the room window);
  # - +game_links+: +<a exist>+ links, which TagHandlers#handle_open_link
  #   reads as it reads GemStone's;
  # - +double_bold+: doubled +<pushBold/>+, which nests (bold spans stack in
  #   SpanTracker), as GemStone's always has.
  FRONTEND_CAPABILITIES = %w[room_element game_links double_bold].freeze

  # The line that declares {FRONTEND_CAPABILITIES} to Lich.
  CAPABILITY_DECLARATION = "SET_FRONTEND_CAPS #{FRONTEND_CAPABILITIES.join(' ')}".freeze

  # Raised by {#connect} when the connection cannot be opened. The message
  # names the host and port and says why; +cause+ is the original error.
  class ConnectError < StandardError; end

  # @return [String] game server host
  attr_reader :host

  # @return [Integer] game server port
  attr_reader :port

  # @param host [String] game server (Lich) host
  # @param port [Integer] game server (Lich) port
  # @param connect_timeout [Numeric] seconds {#connect} waits for the
  #   connection before giving up
  # @param declare_capabilities [Boolean] whether {#connect} also sends
  #   {CAPABILITY_DECLARATION} (+--rich-stream+). Off by default: a Lich
  #   without lich-5 #1726 doesn't know the line and sends it to the game
  #   as a command.
  def initialize(host:, port:, connect_timeout: CONNECT_TIMEOUT, declare_capabilities: false)
    @host = host
    @port = port
    @connect_timeout = connect_timeout
    @declare_capabilities = declare_capabilities
    @socket = nil
    # Receives the reader thread's outcome (see #start_reader)
    @session_end = Queue.new
    @reader = nil
  end

  # Open the connection and tell the server the front end's PID, then, with
  # +declare_capabilities+, the parts of the rich stream it renders
  # ({CAPABILITY_DECLARATION}). Both go before any command, on every
  # connection, so Lich reads the declaration before most of the game's
  # output; Lich sends no reply to either.
  #
  # @return [self]
  # @raise [ConnectError] if the connection cannot be opened or the lines
  #   cannot be written
  def connect
    @socket = Socket.tcp(@host, @port, connect_timeout: @connect_timeout)
    @socket.puts "SET_FRONTEND_PID #{Process.pid}"
    @socket.puts CAPABILITY_DECLARATION if @declare_capabilities
    @socket.flush
    self
  # SystemCallError covers refused, unreachable, timed out, and bad
  # address; SocketError covers name lookup. IO::TimeoutError is what
  # TCPSocket's connect_timeout raises, should the socket class change.
  rescue SystemCallError, SocketError, IO::TimeoutError => e
    raise ConnectError, "Failed to connect to game server at #{@host}:#{@port}: #{e.message}"
  end

  # Use an already open socket (or any object with +gets+, +puts+ and
  # +close+) instead of connecting.
  #
  # @param socket [#gets, #puts] the open connection
  # @return [self]
  def attach(socket)
    @socket = socket
    self
  end

  # Write one line to the game server, never while holding the render lock.
  #
  # Key handlers run inside {CursesRenderer.synchronize}. If the server
  # stops reading and the socket's send buffer fills, the write blocks; with
  # the lock held that would also stop the server thread from drawing. So
  # the write waits until the lock is released (see
  # {CursesRenderer.outside_lock}); lines keep the order they were sent in.
  #
  # A write that fails because the connection is gone (one of
  # {ServerReader::DISCONNECT_ERRORS}, e.g. EPIPE once Lich has closed) is
  # logged and closes the socket. That ends the reader thread's read, so
  # it reports +:disconnected+ (if it has not already) and the session ends
  # as it does when the server closes the connection. Other errors are
  # raised.
  #
  # @param line [String] the command to send
  # @return [void]
  def send_line(line)
    CursesRenderer.outside_lock do
      @socket.puts line
    rescue *ServerReader::DISCONNECT_ERRORS => e
      ProfanityLog.write('main', "send failed, disconnected: #{e.class}: #{e.message}")
      close
    end
  end

  # Start the thread that reads from the server. The thread only reports
  # how the connection ended: the block's return value, or +:crashed+ if it
  # raised. {#ended?} and {#take_outcome} pick that up on the main thread.
  #
  # @yieldparam socket [#gets, #puts] the connection, read when the thread runs
  # @yieldreturn [Symbol] how the connection ended (+:disconnected+ or
  #   +:crashed+, see {GameTextProcessor#run})
  # @return [Thread] the reader thread
  def start_reader
    @reader = Thread.new do
      outcome = :crashed
      outcome = yield @socket
    ensure
      @session_end << outcome
    end
  end

  # Whether the reader thread has reported that the connection is over.
  #
  # @return [Boolean]
  def ended?
    !@session_end.empty?
  end

  # Take the reader thread's report, waiting for it if there is none yet.
  #
  # @return [Symbol, nil] what the {#start_reader} block returned, or
  #   +:crashed+ if it raised
  def take_outcome
    @session_end.pop
  end

  # Close the socket and wait for the reader thread to end, at most
  # +timeout+ seconds, so it draws nothing more. Closing the socket ends a
  # read in progress; a line already read is drawn first.
  #
  # @param timeout [Numeric] seconds to wait for the reader thread
  # @return [void]
  def stop(timeout: STOP_TIMEOUT)
    close
    @reader&.join(timeout)
    nil
  end

  # Close the socket, ignoring errors; does nothing if never connected.
  #
  # @return [void]
  def close
    @socket&.close
  rescue StandardError
    # ignore
  end
end
