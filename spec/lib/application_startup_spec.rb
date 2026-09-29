# frozen_string_literal: true

# Tests starting the real client (Application#run) on the virtual screen:
# loading the settings file it was given, and connecting to the game
# server at the host and port it was given. A settings file that cannot
# be used, or a connection that fails, ends startup with the reason on
# stderr and exit status 1.

require 'rexml/document'
require_relative '../../lib/shared_state'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../../lib/window_manager'
require_relative '../../lib/mouse_scroll'
require_relative '../../lib/autocomplete'
require_relative '../../lib/selection_manager'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/application'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../support/client_run'

RSpec.describe 'Starting the client' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'given.xml') }
  let(:host) { '192.0.2.10' }
  let(:port) { 8000 }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: host, port: port)
  end

  # A settings file with one highlight, Enter bound to send the command
  # line, and a layout with a main and a command window.
  def settings_highlighting(word)
    <<~XML
      <settings>
        <highlight fg='ff0000'>#{word}</highlight>
        <key id='enter' action='send_command'/>
        <layout id='default'>
          <window class='text' value='main' top='0' left='0' height='5' width='60'/>
          <window class='command' top='5' left='0' height='1' width='60'/>
        </layout>
      </settings>
    XML
  end

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    allow(ProfanityLog).to receive(:write)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    File.write(settings_path, settings_highlighting('goblin'))
  end

  # BUG FOUND (fixed here): a settings file that failed to parse on startup
  # showed only "No layouts found ... may be malformed"; why it failed (an
  # empty file, or where the XML broke) was only in the log.
  describe 'loading the settings file' do
    it 'says the file is empty when it is, and exits 1' do
      File.write(settings_path, '')

      status, stderr = run_client(keyboard)

      expect(status).to eq 1
      expect(stderr.lines.map(&:chomp)).to eq ["ERROR: Could not load settings from #{settings_path}.",
                                               "Settings file is empty: #{settings_path}"]
    end

    it 'says where the XML broke when it is malformed, and exits 1' do
      File.write(settings_path, "<settings>\n  <layout id='default'>\n  </layuot>\n</settings>\n")

      status, stderr = run_client(keyboard)

      expect(status).to eq 1
      expect(stderr.lines.map(&:chomp)).to eq ["ERROR: Could not load settings from #{settings_path}.",
                                               "Missing end tag for 'layout' (got 'layuot') (line 3)"]
    end

    # Application used to read SETTINGS_FILENAME, HOST and PORT, constants
    # only profanity.rb defined. It now uses the values it is constructed
    # with, so the messages name the file it was given.
    it 'says no layouts were found in the file it was given when a well-formed file has none, and exits 1' do
      File.write(settings_path, "<settings><preset id='speech' fg='00ff00'/></settings>\n")

      status, stderr = run_client(keyboard)

      expect(status).to eq 1
      expect(stderr.lines.map(&:chomp)).to eq [
        "ERROR: No layouts found in #{settings_path}.",
        'The XML file may be malformed. Check for unclosed tags or encoding errors.'
      ]
    end

    it 'loads the file it was given at startup, and again on .reload' do
      highlights_at_startup = nil
      edit_the_file = lambda do
        highlights_at_startup = HIGHLIGHT.keys
        File.write(settings_path, settings_highlighting('troll'))
        nil
      end

      run_client(keyboard(edit_the_file, ".reload\n"))

      expect(highlights_at_startup).to eq [/goblin/]
      expect(HIGHLIGHT.keys).to eq [/troll/]
    end
  end

  describe 'connecting to the game server' do
    it 'connects to the host and port it was given, with a timeout, and sends its PID first' do
      run_client(keyboard)

      expect(Socket).to have_received(:tcp).with('192.0.2.10', 8000, connect_timeout: Application::CONNECT_TIMEOUT)
      expect(game_server.received).to eq ["SET_FRONTEND_PID #{Process.pid}"]
    end

    it 'forgets the server time offset measured on the last connection' do
      app.window_mgr.clock.server_time_offset = 12.5

      run_client(keyboard)

      expect(app.window_mgr.clock.server_time_offset).to eq 0.0
    end

    # The first prompt's time sets the offset the clock and the countdown
    # windows use, so the server thread must set it on the window
    # manager's clock.
    it "measures the server time offset from the first prompt on the window manager's clock" do
      server_time = 1_000_000_000
      game_server.say("<prompt time=\"#{server_time}\">&gt;</prompt>")

      run_client(keyboard(wait_until { app.window_mgr.clock.server_time_offset.nonzero? }))

      expect(app.window_mgr.clock.server_time_offset).to be_within(60).of(Time.now.to_f - server_time)
    end

    [
      Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL, Errno::ECONNREFUSED,
      SocketError.new('getaddrinfo: nodename nor servname provided')
    ].each do |error|
      it "reports #{error.is_a?(Exception) ? error.class : error} naming the host and port, and exits 1" do
        status, stderr = run_client(keyboard, connect_error: error)

        expect(status).to eq 1
        expect(stderr).to start_with('Failed to connect to game server at 192.0.2.10:8000: ')
        expect(stderr).to end_with("\nIs the game server running?\n")
      end
    end

    # BUG FOUND (fixed here): fatal errors were printed with Kernel#warn,
    # which prints nothing when warnings are off (ruby -W0, $VERBOSE nil),
    # so the client exited 1 without saying why.
    it 'still reports the failure with warnings turned off (ruby -W0)' do
      verbose = $VERBOSE
      $VERBOSE = nil

      _, stderr = run_client(keyboard, connect_error: Errno::ECONNREFUSED)

      expect(stderr.lines.map(&:chomp)).to eq [
        'Failed to connect to game server at 192.0.2.10:8000: Connection refused',
        'Is the game server running?'
      ]
    ensure
      $VERBOSE = verbose
    end

    it 'closes the curses screen before printing, so the error is not wiped with it' do
      stderr_at_close = []
      allow(Curses).to receive(:close_screen) { stderr_at_close << $stderr.string.dup }

      _, stderr = run_client(keyboard, connect_error: Errno::ECONNREFUSED)

      expect(stderr_at_close).to eq ['']
      expect(stderr).to include('Connection refused')
    end

    context 'with a game server listening on an ephemeral port' do
      let(:host) { '127.0.0.1' }
      let(:listener) { TCPServer.new('127.0.0.1', 0) }
      let(:port) { listener.addr[1] }

      after { listener.close }

      it 'connects to that host and port' do
        run_client(keyboard, server: nil)
        # The connection is made before #run returns, so it is waiting
        client = listener.accept_nonblock(exception: false)

        expect(client).to be_a(TCPSocket)
        expect(client.gets).to eq "SET_FRONTEND_PID #{Process.pid}\n"
      ensure
        client.close if client.is_a?(TCPSocket)
      end
    end

    context 'with nothing listening on the port' do
      let(:host) { '127.0.0.1' }
      # A port that was free a moment ago: bind, note it, and close.
      let(:port) { TCPServer.open('127.0.0.1', 0).then { |server| server.addr[1].tap { server.close } } }

      it 'names that host and port in the error and exits 1' do
        status, stderr = run_client(keyboard, server: nil)

        expect(status).to eq 1
        expect(stderr).to start_with("Failed to connect to game server at 127.0.0.1:#{port}: ")
      end
    end
  end
end
