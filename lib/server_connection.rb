# frozen_string_literal: true

require 'socket'

# The TCP connection to the game server (Lich).
#
# Opens the socket and announces the front end's PID, writes commands to it
# without holding the render lock, runs the thread that reads from it, and
# reports how that thread ended so the main thread can end the session.
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
  def initialize(host:, port:, connect_timeout: CONNECT_TIMEOUT)
    @host = host
    @port = port
    @connect_timeout = connect_timeout
    @socket = nil
    # Receives the reader thread's outcome (see #start_reader)
    @session_end = Queue.new
  end

  # Open the connection and tell the server the front end's PID.
  #
  # @return [self]
  # @raise [ConnectError] if the connection cannot be opened or the PID
  #   line cannot be written
  def connect
    @socket = Socket.tcp(@host, @port, connect_timeout: @connect_timeout)
    @socket.puts "SET_FRONTEND_PID #{Process.pid}"
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
  # @param line [String] the command to send
  # @return [void]
  def send_line(line)
    CursesRenderer.outside_lock { @socket.puts line }
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
    Thread.new do
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

  # Close the socket, ignoring errors; does nothing if never connected.
  #
  # @return [void]
  def close
    @socket&.close
  rescue StandardError
    # ignore
  end
end
