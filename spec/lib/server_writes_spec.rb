# frozen_string_literal: true

# Tests that nothing is written to the game server socket while the writing
# thread holds the curses render lock, and that commands are still echoed
# and sent in the same order.
#
# BUG FOUND (fixed here): typed commands, macros, history resends, link
# clicks and the first-prompt 'look' were written to the socket inside
# CursesRenderer's monitor. When the peer stopped reading and the send
# buffer filled, the write blocked with the lock held, and the server
# thread then blocked on the lock: the whole UI froze.

require 'monitor'
require 'socket'
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
require_relative '../../lib/event_bus'

RSpec.describe 'Writes to the game server' do
  # spec_helper's CursesRenderer has no lock. Use the real one, loaded into
  # a wrapper module so the rest of the suite keeps the stub.
  real_renderer = Module.new.tap { |wrapper| load(File.expand_path('../../lib/curses_renderer.rb', __dir__), wrapper) }
  before { stub_const('CursesRenderer', real_renderer::CursesRenderer) }

  # Each line written to the socket: [line, whether the render lock was
  # free (another thread could draw), what main showed at that moment].
  let(:sends) { [] }

  # Whether this thread holds the render lock: another thread (the server
  # thread) can't take it. The other thread gets 5 seconds, so a busy
  # machine doesn't read as a held lock.
  def lock_held? = !Thread.new { CursesRenderer.synchronize { true } }.join(5)

  # The rows main shows; none without a main window.
  def main_rows = []

  # A socket that records each line written (see #sends).
  let(:server) do
    spec = self
    socket = Object.new
    socket.define_singleton_method(:puts) do |line|
      spec.sends << [line, spec.lock_held? ? :lock_held : :lock_free, spec.main_rows]
    end
    socket.define_singleton_method(:flush) { self }
    socket.define_singleton_method(:close) { nil }
    socket
  end

  def sent = sends.map { |line, lock, _shown| [:sent, line, lock] }

  describe 'from the input loop' do
    let(:mouse_scroll) do
      obj = Object.new
      %i[enable_click_events disable_click_events process start_configuration].each do |name|
        obj.define_singleton_method(name) { |*| nil }
      end
      obj.define_singleton_method(:configuring?) { false }
      obj
    end
    let(:cli_options) { { char: nil, no_status: true, links: true, remote_url: false, room_window_only: false } }
    let(:app) { Application.new(cli_options, settings_file: File.join(SPEC_HOME, 'settings.xml'), host: '127.0.0.1', port: 8000) }
    let(:main) { app.window_mgr.stream['main'] }

    def main_rows = main.rows.reject(&:empty?)

    # Key codes bound below: Enter sends, ctrl+a runs a two-command macro,
    # ctrl+b resends the last command.
    let(:enter) { 13 }
    let(:macro_key) { 1 }
    let(:resend_key) { 2 }

    # Where the link 'go door' is on screen: main's top row, on "door".
    let(:link_position) { [0, 10] }

    before do
      allow(MouseScroll).to receive(:new).and_return(mouse_scroll)
      allow(IO).to receive(:select).and_return(nil)
      allow(Curses).to receive(:getmouse)
        .and_return(Struct.new(:y, :x, :bstate).new(*link_position, Curses::BUTTON1_CLICKED))
      LAYOUT['writes'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='10' width='40' value='main'/>
          <window class='command' top='11' left='0' height='1' width='40'/>
        </layout>
      XML
      app.window_mgr.load_layout('writes')
      app.cmd_buffer.window = app.window_mgr.command_window
      main.add_string('Open the door.', [{ start: 9, end: 13, cmd: 'go door' }])
      app.key_binding[enter] = app.key_action['send_command']
      app.key_binding[macro_key] = proc { app.do_macro('look\\rnorth\\r') }
      app.key_binding[resend_key] = app.key_action['send_last_command']
    end

    # Type +keys+ into the real input loop, then end it as Ctrl+C would.
    # The command window hands out the same keys from getch as from
    # get_char (what read_key reads): the virtual screen's getch returns
    # nil forever, so a read_key that stopped calling get_char would
    # otherwise never reach the Interrupt and the loop would never end.
    def type(*keys)
      %i[get_char getch].each do |reader|
        app.cmd_buffer.window.define_singleton_method(reader) { keys.empty? ? raise(Interrupt) : keys.shift }
      end
      app.connection.attach(server)
      app.send(:input_loop)
    end

    let(:keys) { [*'get sword'.chars, enter, macro_key, resend_key, Curses::KEY_MOUSE] }

    it 'echoes each command in main before sending it, and keeps both in order' do
      type(*keys)

      commands = ['get sword', 'look', 'north', 'north', 'go door']
      echoes = commands.map { |cmd| ">#{cmd}" }
      expect(main_rows).to eq ['Open the door.', *echoes]
      expect(sends.map(&:first)).to eq commands
      # The nth command sent found at least n echoes on main already.
      echoes_on_main = sends.map { |_line, _lock, shown| shown.count { |row| row.start_with?('>') } }
      expect(echoes_on_main.zip(1..)).to all(satisfy { |count, nth| count >= nth })
    end

    it 'sends typed commands, macros, history resends and link clicks without the render lock' do
      type(*keys)

      expect(sends.map { |_line, lock, _shown| lock }).to all(eq :lock_free)
      expect(sends.size).to eq 5
    end

    it 'forwards a dot-command to Lich without the render lock' do
      type(*'.script'.chars, enter)

      expect(sent).to eq [[:sent, ';script', :lock_free]]
    end

    it 'still sends immediately when called outside the lock' do
      app.connection.attach(server)

      app.execute_command('get sword')

      expect(sent).to eq [[:sent, 'get sword', :lock_free]]
    end

    it 'sends SET_FRONTEND_PID on connect without the render lock' do
      allow(Socket).to receive(:tcp).and_return(server)

      app.connection.connect

      expect(sent).to eq [[:sent, "SET_FRONTEND_PID #{Process.pid}", :lock_free]]
    end
  end

  describe 'from the server thread' do
    let(:wm) do
      Struct.new(:stream, :indicator, :progress, :countdown, :room,
                 :command_window, :command_window_layout).new({ 'main' => Object.new }, {}, {}, {}, {}, nil, nil)
    end
    let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
    let(:processor) do
      GameTextProcessor.new(
        window_mgr: wm,
        shared_state: state,
        cmd_buffer: Struct.new(:window).new(nil),
        xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
        event_bus: EventBus.new
      )
    end

    before do
      GagPatterns.load_defaults
      allow(IO).to receive(:select).and_return(nil)
    end

    it "sends 'look' at the first prompt without the render lock, and only once" do
      lines = ["<prompt time=\"1\">&gt;</prompt>\r\n", "<prompt time=\"2\">&gt;</prompt>\r\n"]
      server.define_singleton_method(:gets) { lines.shift&.dup }

      expect(processor.run(server)).to eq :disconnected
      expect(sent).to eq [[:sent, 'look', :lock_free]]
    end
  end
end
