# frozen_string_literal: true

# Tests how a session ends once the game server connection is over, with
# the real client (Application#run) on the virtual screen: the server
# thread reports how the connection ended, and the input loop, on the main
# thread, shows the disconnect notice, waits for a key (at most 30
# seconds) and exits 0, or exits 1 with the error when something crashed.

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

RSpec.describe 'The end of a session' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:main) { app.window_mgr.stream['main'] }
  let(:notice) { ['*', '* Connection closed', '* Press any key to exit...', '*'] }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    allow(ProfanityLog).to receive(:write)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    File.write(settings_path, <<~XML)
      <settings>
        <key id='enter' action='send_command'/>
        <layout id='default'>
          <window class='text' top='0' left='0' height='6' width='60' value='main'/>
          <window class='command' top='7' left='0' height='1' width='60'/>
        </layout>
      </settings>
    XML
  end

  def notices_shown = main.rows.count('* Connection closed')

  describe 'when the game server closes the connection' do
    # The thread each screen update (CursesRenderer.render) ran on
    let(:render_threads) { [] }

    before do
      allow(CursesRenderer).to receive(:render).and_wrap_original do |original, &block|
        render_threads << Thread.current
        original.call(&block)
      end
    end

    it 'shows the notice, then waits for a key on the main thread, and exits 0' do
      game_server.hang_up
      waits = []
      exit_key = lambda do
        waits << [Thread.current, main.rows.last(4)]
        'q'
      end

      status, = run_client(keyboard(idle: true, exit_keys: [exit_key]))

      expect(status).to eq 0
      expect(waits).to eq [[Thread.current, notice]]
      expect(render_threads.uniq).to eq [Thread.current]
    end

    [IOError.new('stream closed'), Errno::ECONNRESET.new, Errno::EPIPE.new, Errno::ECONNABORTED.new].each do |error|
      it "does the same when the read fails with #{error.class}" do
        game_server.hang_up(error)
        exit_keys = ['q']

        status, = run_client(keyboard(idle: true, exit_keys: exit_keys))

        expect(status).to eq 0
        expect(main.rows.last(4)).to eq notice
        expect(exit_keys).to be_empty
        expect(render_threads.uniq).to eq [Thread.current]
      end
    end
  end

  describe 'the wait for a key' do
    before { game_server.hang_up }

    # The timeout (ms) set before each read of the exit key
    def read_timeouts(command_window)
      command_window.call_log.filter_map { |name, (ms)| ms if name == :timeout= }
    end

    it 'waits past terminal resizes and mouse events for a real key' do
      exit_keys = [Curses::KEY_RESIZE, Curses::KEY_MOUSE, 'q', 'not read']

      status, = run_client(keyboard(idle: true, exit_keys: exit_keys))

      expect(status).to eq 0
      expect(exit_keys).to eq ['not read']
    end

    # BUG FOUND (fixed here): "Press any key to exit..." waited forever, so an
    # unattended client never exited after a disconnect.
    it 'stops waiting after 30 seconds without a key, and exits 0' do
      command_window = keyboard(idle: true, exit_keys: [])

      status, = run_client(command_window)

      expect(status).to eq 0
      expect(read_timeouts(command_window)).to eq [30_000]
    end

    it 'keeps the 30 second deadline across resizes and mouse events' do
      now = 100.0
      allow(Process).to receive(:clock_gettime).and_call_original
      allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { now }
      exit_keys = [-> { now += 20; Curses::KEY_RESIZE }, -> { now += 11; Curses::KEY_MOUSE }, 'not read']
      command_window = keyboard(idle: true, exit_keys: exit_keys)

      status, = run_client(command_window)

      expect(status).to eq 0
      expect(read_timeouts(command_window)).to eq [30_000, 10_000]
      expect(exit_keys).to eq ['not read']
    end
  end

  it 'exits 1 without the disconnect notice when the server thread crashes' do
    game_server.hang_up(RuntimeError.new('boom'))
    exit_keys = ['q']

    status, stderr = run_client(keyboard(idle: true, exit_keys: exit_keys))

    expect(status).to eq 1
    expect(stderr).to eq "ProfanityFE stopped: error reading from the game server. See the log file for details.\n"
    expect(notices_shown).to eq 0
    expect(exit_keys).to eq ['q']
  end

  # BUG FOUND (fixed here): a command sent after Lich closed the connection
  # raised EPIPE or ECONNRESET out of the input loop, which ended the
  # client as a crash (exit 1) instead of showing the disconnect notice.
  describe 'a command sent after the game server has closed' do
    real_renderer = Module.new.tap { |wrapper| load(File.expand_path('../../lib/curses_renderer.rb', __dir__), wrapper) }

    # The real render lock, so the command is written after the key
    # handler, outside the lock, as in the client.
    before { stub_const('CursesRenderer', real_renderer::CursesRenderer) }

    [Errno::EPIPE, Errno::ECONNRESET].each do |error_class|
      it "on #{error_class} from the write, shows the disconnect notice once, waits for a key, and exits 0" do
        exit_keys = ['q']

        status, stderr = run_client(keyboard("look\n", idle: true, exit_keys: exit_keys),
                                    server: ClientRun::GameServer.new(write_error: error_class.new))

        expect(status).to eq 0
        expect(stderr).to eq ''
        expect(notices_shown).to eq 1
        expect(main.rows.last(4)).to eq notice
        expect(exit_keys).to be_empty
      end
    end

    it 'exits 1 with the error message when the write fails with any other error' do
      status, stderr = run_client(keyboard("look\n", idle: true),
                                  server: ClientRun::GameServer.new(write_error: Errno::ETIMEDOUT.new))

      expect(status).to eq 1
      expect(notices_shown).to eq 0
      expect(stderr).to start_with('ProfanityFE stopped: error in the input loop (Errno::ETIMEDOUT: ')
    end

    it 'still exits 1 with the error message on an IOError that is not from a write' do
      terminal_gone = -> { raise IOError, 'terminal gone' }

      status, stderr = run_client(keyboard(terminal_gone),
                                  server: ClientRun::GameServer.new(write_error: Errno::EPIPE.new))

      expect(status).to eq 1
      expect(notices_shown).to eq 0
      expect(stderr).to eq "ProfanityFE stopped: error in the input loop (IOError: terminal gone). See the log file for details.\n"
    end

    # The server closes, the server thread reports the disconnect, and then
    # the command already typed is written to the closed connection (EPIPE).
    it 'shows the notice once when the server thread has already reported the disconnect' do
      client_end, game_end = UNIXSocket.pair
      enter_after_the_disconnect = press_after("\n") do
        game_end.close
        sleep 0.001 until app.connection.ended?
      end

      status, stderr = run_client(keyboard('look', enter_after_the_disconnect, idle: true, exit_keys: ['q']),
                                  server: client_end)

      expect(status).to eq 0
      expect(stderr).to eq ''
      expect(notices_shown).to eq 1
      expect(ProfanityLog).to have_received(:write).with('main', 'send failed, disconnected: Errno::EPIPE: Broken pipe')
    ensure
      [client_end, game_end].each { |socket| socket.close unless socket.nil? || socket.closed? }
    end
  end
end
