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

  let(:timeline) { [] }

  # A socket that records each line written and whether the writing thread
  # held the render lock at the time.
  let(:server) do
    timeline = self.timeline
    socket = Object.new
    socket.define_singleton_method(:puts) do |line|
      held = CursesRenderer.instance_variable_get(:@monitor).mon_owned?
      timeline << [:sent, line, held ? :lock_held : :lock_free]
    end
    socket.define_singleton_method(:flush) { self }
    socket.define_singleton_method(:close) { nil }
    socket
  end

  def sent = timeline.select { |event, *| event == :sent }

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
    let(:app) { Application.new(cli_options) }

    # The main window records each echoed command line.
    let(:main_window) do
      timeline = self.timeline
      window = Object.new
      window.define_singleton_method(:route_string) { |text, *, **| timeline << [:echo, text] }
      window.define_singleton_method(:add_string) { |text, *| timeline << [:echo, text] }
      window
    end

    # A window whose link under the pointer is 'go door'.
    let(:link_window) do
      window = Object.new
      window.define_singleton_method(:begy) { 0 }
      window.define_singleton_method(:begx) { 0 }
      window.define_singleton_method(:link_cmd_at) { |*| 'go door' }
      window
    end

    # Key codes bound below: Enter sends, ctrl+a runs a two-command macro,
    # ctrl+b resends the last command.
    let(:enter) { 13 }
    let(:macro_key) { 1 }
    let(:resend_key) { 2 }

    before do
      allow(MouseScroll).to receive(:new).and_return(mouse_scroll)
      allow(IO).to receive(:select).and_return(nil)
      allow(Curses).to receive(:getmouse).and_return(Struct.new(:y, :x, :bstate).new(3, 4, Curses::BUTTON1_CLICKED))
      allow(BaseWindow).to receive(:find_window_at).and_return(link_window)
      app.window_mgr.instance_variable_set(:@stream, { 'main' => main_window })
      app.key_binding[enter] = app.key_action['send_command']
      app.key_binding[macro_key] = proc { app.do_macro('look\\rnorth\\r') }
      app.key_binding[resend_key] = app.key_action['send_last_command']
    end

    # Type +keys+ into the real input loop, then end it as Ctrl+C would.
    def type(*keys)
      keyboard = Curses::Window.new(1, 80, 0, 0)
      next_key = -> { keys.empty? ? raise(Interrupt) : keys.shift }
      # The input loop reads with getch or get_char depending on the version;
      # answer both from the same keys.
      keyboard.define_singleton_method(:getch, &next_key)
      keyboard.define_singleton_method(:get_char, &next_key)
      app.cmd_buffer.window = keyboard
      app.instance_variable_set(:@server, server)
      app.send(:input_loop)
    end

    let(:keys) { [*'get sword'.chars, enter, macro_key, resend_key, Curses::KEY_MOUSE] }

    it 'echoes each command before sending it, and keeps both in order' do
      type(*keys)

      commands = ['get sword', 'look', 'north', 'north', 'go door']
      echoes = timeline.each_index.select { |i| timeline[i][0] == :echo }
      sends = timeline.each_index.select { |i| timeline[i][0] == :sent }
      expect(echoes.map { |i| timeline[i][1] }).to eq(commands.map { |cmd| ">#{cmd}" })
      expect(sends.map { |i| timeline[i][1] }).to eq commands
      expect(echoes.zip(sends)).to all(satisfy { |echo, send| echo < send })
    end

    it 'sends typed commands, macros, history resends and link clicks without the render lock' do
      type(*keys)

      expect(sent.map(&:last)).to all(eq :lock_free)
      expect(sent.size).to eq 5
    end

    it 'forwards a dot-command to Lich without the render lock' do
      type(*'.script'.chars, enter)

      expect(sent).to eq [[:sent, ';script', :lock_free]]
    end

    it 'still sends immediately when called outside the lock' do
      app.instance_variable_set(:@server, server)

      app.execute_command('get sword')

      expect(sent).to eq [[:sent, 'get sword', :lock_free]]
    end

    it 'sends SET_FRONTEND_PID on connect without the render lock' do
      stub_const('HOST', '127.0.0.1')
      stub_const('PORT', 8000)
      allow(Socket).to receive(:tcp).and_return(server)

      app.send(:connect_server)

      expect(sent).to eq [[:sent, "SET_FRONTEND_PID #{Process.pid}", :lock_free]]
    end
  end

  describe 'from the server thread' do
    let(:wm) do
      Struct.new(:stream, :indicator, :progress, :countdown, :room,
                 :command_window, :command_window_layout).new({ 'main' => Object.new }, {}, {}, {}, {}, nil, nil)
    end
    let(:state) do
      Struct.new(:need_prompt, :prompt_text, :skip_server_time_offset,
                 :room_title, :blue_links, :room_window_only, :server_time_offset,
                 :remote_url, :log_gags) do
        def update_terminal_title = nil
      end.new(false, '>', true, '', false, false, 0.0, false, false)
    end
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
