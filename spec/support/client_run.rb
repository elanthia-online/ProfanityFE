# frozen_string_literal: true

require 'socket'

# Runs the real client, Application#run, on the virtual screen: it loads
# the settings file, connects to a scripted game server, starts the server
# thread, and reads keys from a scripted keyboard until the keys run out
# or the session ends.
#
# Include it in an example group that defines +app+, the Application, and
# write the settings file +app+ was given before calling {#run_client}.
#
# @example
#   File.write(settings_path, settings)
#   status, stderr = run_client(keyboard("look\n"))
#   expect(game_server.commands).to eq ['look']
module ClientRun
  # How long a keyboard waits for something (see {#wait_until} and the
  # +idle+ option of {#keyboard}) before giving up.
  DEADLINE = 5

  # The game server (Lich) connection that +Socket.tcp+ returns. +gets+
  # hands the client the lines sent with {#say}, waiting for the next one;
  # +puts+ records what the client sends.
  class GameServer
    # @return [Array<String>] every line the client sent, its PID line first
    attr_reader :received

    # @param write_error [Exception, nil] raised by every write after the
    #   PID line, as a socket whose other end is gone raises EPIPE
    def initialize(write_error: nil)
      @lines = Queue.new
      @received = []
      @write_error = write_error
    end

    # Send lines to the client, as the game does.
    #
    # @param lines [Array<String>] server lines, without line endings
    # @return [void]
    def say(*lines)
      lines.each { |line| @lines << "#{line}\r\n" }
    end

    # End the connection from the game's side: after the lines already
    # sent, the client's next read returns end of file, or raises +error+.
    #
    # @param error [Exception, nil]
    # @return [void]
    def hang_up(error = nil)
      @lines << (error || :eof)
    end

    # @return [String, nil] the next line, or nil at end of file
    def gets
      line = @lines.pop
      raise line if line.is_a?(Exception)

      line unless line == :eof
    end

    def puts(line)
      raise @write_error if @write_error && !@received.empty?

      @received << line
      nil
    end

    def flush = nil

    # Closing the client's end makes a read waiting on it raise IOError,
    # as a socket closed in another thread does.
    def close
      return if @lines.closed?

      @lines << IOError.new('stream closed in another thread')
      @lines.close
      nil
    end

    # @return [Array<String>] the lines the client sent after its PID line
    def commands = @received.drop(1)
  end

  # The game server +Socket.tcp+ returns in {#run_client}.
  #
  # @return [GameServer]
  def game_server
    @game_server ||= GameServer.new
  end

  # A keyboard step (see {#keyboard}) that holds the keys after it back:
  # the reads return no key until the block returns true, for at most
  # {DEADLINE} seconds. The input loop keeps polling meanwhile, so the
  # server thread can draw.
  WaitUntil = Struct.new(:condition, :deadline) do
    # @return [Boolean] whether the keys after it may come
    def over?
      self.deadline ||= Time.now + DEADLINE
      condition.call || Time.now > deadline
    end
  end

  # A keyboard step (see {#keyboard}) that runs an action, then presses a
  # key, in the same read of the input loop.
  PressAfter = Struct.new(:key, :action)

  # A command window (a virtual screen, one row of 80 columns) that is
  # also the keyboard: each read the input loop makes (+get_char+) takes
  # the next key.
  #
  # - A String is typed, one character per read. A control character
  #   ("\n", "\e", "\x01") is read as itself, as curses returns it.
  # - An Integer is a function key's code (Curses::KEY_RESIZE, ...).
  # - A Proc runs at that read, which returns no key.
  # - A {#press_after} step runs its block, then returns its key, in the
  #   same read.
  # - A {#wait_until} step returns no key until its condition holds.
  #
  # When the keys run out, the next read raises Interrupt (Ctrl+C), which
  # ends the input loop. With +idle: true+ the reads return no key
  # instead, until the session ends, or for at most {DEADLINE} seconds.
  #
  # The "Press any key to exit..." wait reads with +getch+, which returns
  # each of +exit_keys+ in turn (a Proc is called for the key), then nil,
  # as a read that timed out does.
  #
  # @param keys [Array<String, Integer, Proc, PressAfter, WaitUntil>]
  # @param idle [Boolean] wait for the session to end once the keys run out
  # @param exit_keys [Array<String, Integer, Proc>] keys for the exit wait;
  #   keys not read are left in the Array
  # @return [Curses::Window]
  def keyboard(*keys, idle: false, exit_keys: [])
    reads = keys.flat_map { |key| key.is_a?(String) ? key.chars : [key] }
    idle_until = nil
    Curses::Window.new(1, 80, 0, 0).tap do |window|
      window.define_singleton_method(:get_char) do
        if reads.empty?
          raise Interrupt unless idle

          idle_until ||= Time.now + DEADLINE
          raise Interrupt if Time.now > idle_until

          next nil
        end

        key = reads.first
        if key.is_a?(WaitUntil)
          reads.shift if key.over?
          next nil
        end

        reads.shift
        case key
        when Proc
          key.call
          nil
        when PressAfter
          key.action.call
          key.key
        else key
        end
      end
      window.define_singleton_method(:getch) do
        key = exit_keys.shift
        key.is_a?(Proc) ? key.call : key
      end
    end
  end

  # A keyboard step that runs the block, then presses +key+ in the same
  # read (see {PressAfter}).
  #
  # @param key [String, Integer]
  # @return [PressAfter]
  def press_after(key, &action)
    PressAfter.new(key, action)
  end

  # A keyboard step that returns no key until the block returns true (see
  # {WaitUntil}).
  #
  # @return [WaitUntil]
  def wait_until(&condition)
    WaitUntil.new(condition)
  end

  # Run the client (Application#run) with +command_window+ as its command
  # line and keyboard, connected to +server+, until it exits or the input
  # loop ends.
  #
  # The threads the client started and left running (the time sync
  # thread, which sleeps 15 seconds, and a server thread still reading)
  # are stopped when it returns, so they don't pile up across examples.
  #
  # @param command_window [Curses::Window] see {#keyboard}
  # @param server [GameServer, #gets, nil] what +Socket.tcp+ returns; nil
  #   connects for real
  # @param connect_error [Exception, Class, nil] what +Socket.tcp+ raises
  #   instead, when given
  # @return [Array(Integer, String), Array(nil, String), Array(Symbol, String)]
  #   the exit status (nil when the client returned without exiting,
  #   :interrupt when Interrupt escaped it) and what it printed to stderr
  def run_client(command_window, server: game_server, connect_error: nil)
    if connect_error
      allow(Socket).to receive(:tcp).and_raise(connect_error)
    elsif server
      allow(Socket).to receive(:tcp).and_return(server)
    end
    # The input loop's 0.1 s wait for a key becomes a short pause, taken
    # outside the render lock as in the client; the server thread's check
    # for more data finds none.
    allow(IO).to receive(:select) do |readers, *|
      sleep 0.0002 if readers == [$stdin]
      nil
    end
    # The layout keeps the command window it finds (it is created once)
    app.window_mgr.install_command_window(nil) { command_window }
    threads_before = Thread.list
    status = nil
    stderr = capture_stderr do
      app.run
    rescue SystemExit => e
      status = e.status
    rescue Interrupt
      status = :interrupt
    end
    [status, stderr]
  ensure
    (Thread.list - threads_before).each { |thread| thread.kill.join } if threads_before
  end

  # Run a block with $stderr captured.
  #
  # @return [String] what the block wrote to $stderr
  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end
end
