# frozen_string_literal: true

# Tests ServerConnection against a real TCP server on an ephemeral port:
# the line it sends on connect, the order of writes made with and without
# the render lock, the errors for a refused or timed-out connection, and
# how the reader thread reports the end of the session.

require 'monitor'
require 'socket'
require 'timeout'
require_relative '../../lib/server_connection'

RSpec.describe ServerConnection do
  let(:listener) { TCPServer.new('127.0.0.1', 0) }
  let!(:port) { listener.addr[1] }
  let(:connection) { described_class.new(host: '127.0.0.1', port: port) }

  after do
    connection.close
    listener.close unless listener.closed?
  end

  # Accept the connection made by the example, with a timeout so a missing
  # connect fails the example instead of hanging.
  def accept_peer
    Timeout.timeout(5) { listener.accept }
  end

  # Everything the peer can read right now without waiting.
  def readable_now(peer)
    peer.read_nonblock(4096)
  rescue IO::WaitReadable
    ''
  end

  # Read exactly +n+ lines from the peer, waiting at most 5 seconds.
  def read_lines(peer, n)
    Timeout.timeout(5) { Array.new(n) { peer.gets } }
  end

  describe '#connect' do
    it "sends the front end's PID as the first line and returns the connection" do
      expect(connection.connect).to equal connection
      peer = accept_peer

      expect(peer.gets).to eq "SET_FRONTEND_PID #{Process.pid}\n"
    ensure
      peer&.close
    end

    it 'waits CONNECT_TIMEOUT (10) seconds by default' do
      expect(described_class::CONNECT_TIMEOUT).to eq 10
      expect(Socket).to receive(:tcp).with('127.0.0.1', port, connect_timeout: 10).and_call_original

      connection.connect
    end

    it 'raises ConnectError naming the host and port when nothing listens there' do
      listener.close

      expect { connection.connect }.to raise_error(described_class::ConnectError) { |error|
        expect(error.message).to start_with("Failed to connect to game server at 127.0.0.1:#{port}: Connection refused")
        expect(error.cause).to be_a(Errno::ECONNREFUSED)
      }
    end

    # 192.0.2.1 is TEST-NET-1 (RFC 5737), never routed, so the connect gets no
    # answer and runs into the timeout.
    it 'raises ConnectError once the connect timeout runs out' do
      slow = described_class.new(host: '192.0.2.1', port: 8000, connect_timeout: 0.2)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      error = begin
        slow.connect
        nil
      rescue described_class::ConnectError => e
        e
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      if [Errno::ENETUNREACH, Errno::EHOSTUNREACH].any? { |klass| error&.cause.is_a?(klass) }
        skip "this network rejects TEST-NET at once (#{error.cause.class})"
      end
      expect(error&.cause).to be_a(Errno::ETIMEDOUT).or be_a(IO::TimeoutError)
      expect(error.message).to start_with('Failed to connect to game server at 192.0.2.1:8000: ')
      expect(elapsed).to be_between(0.2, 3)
    end

    it 'raises ConnectError for a host name that does not resolve' do
      unresolvable = described_class.new(host: 'no-such-host.invalid', port: 8000)

      expect { unresolvable.connect }.to raise_error(described_class::ConnectError) { |error|
        expect(error.message).to start_with('Failed to connect to game server at no-such-host.invalid:8000: ')
        expect(error.cause).to be_a(SocketError)
      }
    end
  end

  describe '#send_line' do
    # spec_helper's CursesRenderer has no lock. Use the real one, loaded into
    # a wrapper module so the rest of the suite keeps the stub.
    real_renderer = Module.new.tap { |wrapper| load(File.expand_path('../../lib/curses_renderer.rb', __dir__), wrapper) }
    before { stub_const('CursesRenderer', real_renderer::CursesRenderer) }

    let!(:peer) do
      connection.connect
      accept_peer.tap(&:gets) # the SET_FRONTEND_PID line
    end

    after { peer.close }

    it 'writes the line at once outside the render lock' do
      connection.send_line('look')

      expect(read_lines(peer, 1)).to eq ["look\n"]
    end

    it 'holds lines written inside the render lock until it is released, in the order written' do
      connection.send_line('one')
      held = CursesRenderer.synchronize do
        connection.send_line('two')
        connection.send_line('three')
        sleep 0.05
        readable_now(peer)
      end
      connection.send_line('four')

      expect(held).to eq "one\n"
      expect(read_lines(peer, 3)).to eq ["two\n", "three\n", "four\n"]
    end

    it 'waits for the outermost lock when the lock is taken twice' do
      CursesRenderer.synchronize do
        CursesRenderer.synchronize { connection.send_line('inner') }
        sleep 0.05
        expect(readable_now(peer)).to eq ''
      end

      expect(read_lines(peer, 1)).to eq ["inner\n"]
    end
  end

  # BUG FOUND (fixed here): a command sent after Lich closed the connection
  # raised EPIPE (or ECONNRESET) out of the input loop, and the client exited
  # 1 as if it had crashed. The failed write now closes the socket, so the
  # reader thread reports :disconnected and the session ends normally.
  describe '#send_line when the connection is gone' do
    real_renderer = Module.new.tap { |wrapper| load(File.expand_path('../../lib/curses_renderer.rb', __dir__), wrapper) }
    let(:sockets) { UNIXSocket.pair }
    let(:local) { sockets.first }
    let(:peer) { sockets.last }

    before do
      stub_const('CursesRenderer', real_renderer::CursesRenderer)
      allow(ProfanityLog).to receive(:write)
      connection.attach(local)
    end

    after { peer.close unless peer.closed? }

    # A reader thread that reports :eof when the server closes the
    # connection and :socket_closed when our side is closed during a read.
    def start_reader
      connection.start_reader do |socket|
        nil while socket.gets
        :eof
      rescue IOError
        :socket_closed
      end
    end

    it 'does not raise on EPIPE when the server has closed, and closes the socket' do
      peer.close

      expect { connection.send_line('look') }.not_to raise_error
      expect(local).to be_closed
    end

    ServerReader::DISCONNECT_ERRORS.each do |error_class|
      it "on #{error_class}, closes the socket, which ends the reader thread's read" do
        allow(local).to receive(:puts).and_raise(error_class)
        start_reader

        connection.send_line('look')

        expect(Timeout.timeout(5) { connection.take_outcome }).to eq :socket_closed
        expect(ProfanityLog).to have_received(:write).with('main', a_string_starting_with("send failed, disconnected: #{error_class}"))
      end
    end

    it 'does not raise for the lines after the first either (a macro sending two lines)' do
      peer.close

      expect do
        CursesRenderer.synchronize do
          connection.send_line('one')
          connection.send_line('two')
        end
      end.not_to raise_error
      expect(ProfanityLog).to have_received(:write).with('main', a_string_including('Errno::EPIPE')).once
      expect(ProfanityLog).to have_received(:write).with('main', a_string_including('IOError')).once
    end

    it 'raises any other error and leaves the socket open' do
      allow(local).to receive(:puts).and_raise(Errno::ETIMEDOUT)

      expect { connection.send_line('look') }.to raise_error(Errno::ETIMEDOUT)
      expect(local).not_to be_closed
    end
  end

  describe 'the reader thread' do
    it 'passes the socket to the block and reports what it returned' do
      connection.connect
      peer = accept_peer
      peer.puts 'Welcome'
      read = nil

      thread = connection.start_reader do |socket|
        socket.gets # Welcome
        read = socket.gets
        :disconnected
      end

      expect(thread).to be_a(Thread)
      peer.puts 'Obvious exits: none.'
      expect(connection.take_outcome).to eq :disconnected
      expect(read).to eq "Obvious exits: none.\n"
    ensure
      peer&.close
    end

    it 'has not ended until the block returns' do
      gate = Queue.new
      connection.attach(StringIO.new)
      thread = connection.start_reader { gate.pop }

      expect(connection.ended?).to be false
      gate << :disconnected
      thread.join

      expect(connection.ended?).to be true
      expect(connection.take_outcome).to eq :disconnected
      expect(connection.ended?).to be false
    end

    it 'reports :crashed when the block raises' do
      report = Thread.report_on_exception
      Thread.report_on_exception = false
      connection.attach(StringIO.new)
      thread = connection.start_reader { raise 'boom' }

      expect { thread.join }.to raise_error(RuntimeError, 'boom')
      expect(connection.take_outcome).to eq :crashed
    ensure
      Thread.report_on_exception = report
    end
  end

  describe '#stop' do
    it 'closes the socket and waits for the reader thread to end' do
      connection.connect
      peer = accept_peer
      # The reader takes a moment to finish after its read is ended.
      thread = connection.start_reader do |socket|
        nil while socket.gets
      rescue IOError
        sleep 0.1
        :disconnected
      end

      connection.stop

      expect(thread).not_to be_alive
      expect(Timeout.timeout(5) { peer.read }).to eq "SET_FRONTEND_PID #{Process.pid}\n"
    ensure
      peer&.close
    end

    it 'stops waiting after the timeout if the reader thread does not end' do
      gate = Queue.new
      connection.attach(StringIO.new)
      thread = connection.start_reader { gate.pop }

      connection.stop(timeout: 0.05)

      expect(thread).to be_alive
    ensure
      gate << :disconnected
    end

    it 'only closes the socket when no reader thread was started' do
      socket = StringIO.new
      connection.attach(socket)

      connection.stop

      expect(socket).to be_closed
    end
  end

  describe '#close' do
    it 'closes the socket, so the server reads end of file' do
      connection.connect
      peer = accept_peer
      peer.gets

      connection.close

      expect(Timeout.timeout(5) { peer.gets }).to be_nil
    ensure
      peer&.close
    end

    it 'does nothing before a connection is made' do
      expect { connection.close }.not_to raise_error
    end

    it 'ignores an error from the socket' do
      socket = Object.new
      def socket.close = raise(IOError, 'closed stream')
      connection.attach(socket)

      expect(connection.close).to be_nil
    end
  end
end
