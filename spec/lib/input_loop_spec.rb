# frozen_string_literal: true

# Tests the input loop of the real client (Application#run) on the
# virtual screen, fed by a scripted keyboard: key bindings and key combos,
# typing non-ASCII characters, terminal resizes, the countdowns it ticks
# on every poll, and how an error outside a key handler ends the client.

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

RSpec.describe 'The input loop' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:main) { app.window_mgr.stream['main'] }
  let(:tabbed) { app.window_mgr.stream['thoughts'] }
  let(:command_line) { app.cmd_buffer.window }

  # A settings file with the given key bindings (XML) and a layout with a
  # main window, a tabbed window and a command window.
  def settings_binding(keys)
    <<~XML
      <settings>
        #{keys}
        <layout id='default'>
          <window class='text' top='0' left='0' height='6' width='60' value='main'/>
          <window class='tabbed' top='0' left='61' height='6' width='18' tabs='thoughts,logons'/>
          <window class='command' top='7' left='0' height='1' width='30'/>
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
  end

  describe 'key bindings' do
    it 'keeps handling keys after a key action raises' do
      File.write(settings_path, settings_binding(<<~XML))
        <key id='tab' action='autocomplete'/>
        <key id='ctrl+l' macro='look\\r'/>
      XML
      allow(Autocomplete).to receive(:complete).and_raise('broken key action')
      tab = "\t"
      ctrl_l = "\x0c"

      status, = run_client(keyboard(tab, ctrl_l))

      expect(status).to be_nil
      expect(game_server.commands).to eq ['look']
      expect(ProfanityLog).to have_received(:write)
        .with('main', 'input handler failed: broken key action', backtrace: an_instance_of(Array))
    end

    # Alt+2 arrives as ESC followed by "2"; the settings file binds it as
    # the combo [27, '2'].
    it 'fires the alt+2 binding from the settings file when ESC then the digit arrive' do
      File.write(settings_path, settings_binding("<key id='alt+2' action='switch_tab_2'/>"))

      run_client(keyboard("\e", '2'))

      expect(tabbed.active_tab).to eq 'logons'
    end
  end

  # BUG FOUND (fixed here): the input loop read keys with getch, which
  # returns a non-ASCII character's UTF-8 bytes one Integer at a time, and
  # only Strings are typed into the command line, so "café" became "caf".
  describe 'typing non-ASCII characters' do
    before do
      File.write(settings_path, settings_binding(<<~XML))
        <key id='enter' action='send_command'/>
        <key id='left' action='cursor_left'/>
        <key id='backspace' action='cursor_backspace'/>
        <key id='ctrl+u' action='cursor_kill_line'/>
        <key id='ctrl+y' action='cursor_yank'/>
      XML
    end

    let(:backspace) { 0x107 } # ncurses KEY_BACKSPACE; spec_helper's Curses stub lacks it
    let(:kill_line) { "\x15" } # ctrl+u
    let(:yank) { "\x19" } # ctrl+y

    it 'shows each typed character on the command line, with the cursor after it' do
      run_client(keyboard('café'))

      expect(command_line.row(0)).to eq 'café'
      expect(command_line.curx).to eq 4
    end

    it 'sends the typed text to the server' do
      run_client(keyboard("café au lait\n"))

      expect(game_server.commands).to eq ['café au lait']
    end

    it 'backspaces over a non-ASCII character as one character' do
      run_client(keyboard('café', backspace, "e\n"))

      expect(game_server.commands).to eq ['cafe']
    end

    it 'moves the cursor over a non-ASCII character as one character' do
      run_client(keyboard('naïve', Curses::KEY_LEFT, Curses::KEY_LEFT, backspace, 'i'))

      expect(command_line.row(0)).to eq 'naive'
      expect(command_line.curx).to eq 3
    end

    it 'kills and yanks text with non-ASCII characters' do
      run_client(keyboard('ñoño', kill_line, 'say ', yank, "\n"))

      expect(game_server.commands).to eq ['say ñoño']
    end

    it 'reports a non-ASCII key as the character typed for .key' do
      run_client(keyboard(".key\n", 'é'))

      expect(main.rows).to include('* Detected keycode: é')
    end

    it 'drops a key the locale cannot decode and keeps reading' do
      # Under the C locale, get_char raises RangeError for a non-ASCII key.
      undecodable_key = -> { raise RangeError, 'invalid codepoint 0xC3 in US-ASCII' }

      run_client(keyboard(undecodable_key, 'a'))

      expect(command_line.row(0)).to eq 'a'
    end
  end

  # BUG FOUND (fixed here): ncurses reports a terminal resize as KEY_RESIZE,
  # but only a settings file binding the resize key re-fitted the layout.
  # default.xml doesn't bind it, so the windows kept their old size until
  # the user typed .resize.
  describe 'a terminal resize' do
    let(:settings) { File.read(File.expand_path('../../templates/default.xml', __dir__)) }
    # default.xml's main window is a tabbed window: main, combat, assess
    let(:main) { TabbedTextWindow.list.first }
    let(:terminal) { { lines: 60, cols: 200 } }
    let(:main_size_before_resize) { [] }

    before do
      allow(Curses).to receive(:lines) { terminal[:lines] }
      allow(Curses).to receive(:cols) { terminal[:cols] }
      File.write(settings_path, settings)
    end

    # Shrink the terminal to 40x150, then deliver the key ncurses sends for it
    def resize_terminal
      press_after(Curses::KEY_RESIZE) do
        main_size_before_resize.push(main.maxy, main.maxx)
        terminal.merge!(lines: 40, cols: 150)
      end
    end

    it 'fits the layout to the new size when the settings file does not bind the resize key' do
      run_client(keyboard(resize_terminal))

      expect(main_size_before_resize).to eq [58, 131]
      expect([main.maxy, main.maxx]).to eq [38, 99]
    end

    it 'still fits the layout after a .reload' do
      run_client(keyboard(".reload\n", resize_terminal))

      expect([main.maxy, main.maxx]).to eq [38, 99]
    end

    it 'fits the layout while a key combo is pending, and keeps the combo' do
      # A lone Escape starts the alt+N combos (alt+2: switch_tab_2)
      run_client(keyboard("\e", resize_terminal, '2'))

      expect([main.maxy, main.maxx]).to eq [38, 99]
      expect(main.active_tab).to eq 'combat'
    end

    context 'when the settings file binds the resize key' do
      let(:settings) { super().sub('</settings>', "<key id='resize' macro='look\\r'/></settings>") }

      it 'runs that binding instead' do
        run_client(keyboard(resize_terminal))

        expect(game_server.commands).to eq ['look']
        expect([main.maxy, main.maxx]).to eq [58, 131]
      end
    end
  end

  describe 'the command line when the game prompt grows' do
    before do
      File.write(settings_path, <<~XML)
        <settings>
          <layout id='default'>
            <window class='text' top='0' left='0' height='6' width='60' value='main'/>
            <window class='indicator' top='9' left='0' height='1' width='1' value='prompt' label='&gt;'/>
            <window class='command' top='9' left='1' height='1' width='20'/>
          </layout>
        </settings>
      XML
    end

    # The prompt indicator grows from 1 to 11 columns, so the window manager
    # shrinks the 20-column command window to 10.
    it 'refits the typed command to the narrower command window' do
      prompt = '<prompt time="1">H 100 [RT]&gt;</prompt>'

      run_client(keyboard('abcdefghijklmnopqr', -> { game_server.say(prompt) },
                          wait_until { command_line.maxx == 10 && command_line.row(0) == 'jklmnopqr' }))

      expect(command_line.maxx).to eq 10
      expect(command_line.row(0)).to eq 'jklmnopqr'
      expect(command_line.curx).to eq 9
    end
  end

  # The input loop ticks every countdown on each poll (~100ms) and flushes
  # the screen when one changed and no key was pressed.
  describe 'countdowns' do
    let(:roundtime) { app.window_mgr.countdown['roundtime'] }
    let(:stunned) { app.window_mgr.countdown['stunned'] }
    let(:flushes) { [] }

    before do
      File.write(settings_path, <<~XML)
        <settings>
          <layout id='default'>
            <window class='text' top='0' left='0' height='6' width='60' value='main'/>
            <window class='countdown' top='6' left='0' height='1' width='10' label='RT' value='roundtime'/>
            <window class='countdown' top='6' left='20' height='1' width='10' label='ST' value='stunned'/>
            <window class='command' top='7' left='0' height='1' width='60'/>
          </layout>
        </settings>
      XML
      allow(CursesRenderer).to receive(:doupdate) { flushes << :doupdate }
    end

    # A keyboard step: set the countdowns' end times, a whole number of
    # seconds from now (nil leaves one alone), and start counting flushes.
    def countdowns_ending_in(roundtime: nil, stunned: nil)
      lambda do
        self.roundtime.end_time = Time.now.to_f + roundtime if roundtime
        self.stunned.end_time = Time.now.to_f + stunned if stunned
        flushes.clear
      end
    end

    # A keyboard step: a poll with no key pressed.
    let(:no_key) { -> {} }

    it 'draws every countdown that changed on the same poll, then flushes the screen once' do
      shown_at_next_poll = nil
      next_poll = lambda do
        shown_at_next_poll = roundtime.rows + stunned.rows
      end

      run_client(keyboard(countdowns_ending_in(roundtime: 3, stunned: 5), next_poll))

      expect(shown_at_next_poll).to eq ['RT       3', 'ST       5']
      expect(flushes).to eq [:doupdate]
    end

    it 'flushes the screen when only the first countdown changed' do
      run_client(keyboard(countdowns_ending_in(roundtime: 3), no_key))

      expect(roundtime.rows).to eq ['RT       3']
      expect(flushes).to eq [:doupdate]
    end

    it 'does not flush the screen on a poll where no countdown changed and no key was pressed' do
      run_client(keyboard(countdowns_ending_in, no_key))

      expect(flushes).to be_empty
    end
  end

  # BUG FOUND (fixed here): an error in the input loop outside a key handler
  # (reading a key, ticking the countdowns) was logged and the client exited
  # 0 with no message. It now ends like a server thread crash: the screen is
  # closed, the error printed, and the client exits 1.
  describe 'an error outside a key handler' do
    let(:events) { [] }
    let(:read_fails) { -> { raise 'boom' } }

    before do
      File.write(settings_path, settings_binding(''))
      allow(Curses).to receive(:close_screen) { events << [:close_screen, $stderr.string.dup] }
    end

    it 'closes the screen, then prints the error, and exits 1' do
      status, stderr = run_client(keyboard(read_fails))

      expect(status).to eq 1
      expect(events.first).to eq [:close_screen, '']
      expect(stderr).to eq "ProfanityFE stopped: error in the input loop (RuntimeError: boom). See the log file for details.\n"
    end

    it 'still logs the error with its backtrace' do
      run_client(keyboard(read_fails))

      expect(ProfanityLog).to have_received(:write).with('main', 'boom', backtrace: an_instance_of(Array))
    end

    it 'prints the error with warnings turned off (ruby -W0)' do
      verbose = $VERBOSE
      $VERBOSE = nil

      _, stderr = run_client(keyboard(read_fails))

      expect(stderr).to include('RuntimeError: boom')
    ensure
      $VERBOSE = verbose
    end

    it 'still ends quietly on Ctrl+C' do
      status, stderr = run_client(keyboard)

      expect(status).to be_nil
      expect(stderr).to eq ''
      expect(events.map(&:first)).to eq [:close_screen]
    end

    context 'while the server thread is drawing game text' do
      let(:monitor) { Monitor.new }
      let(:sockets) { UNIXSocket.pair }
      let(:game_end) { sockets.last }
      let(:server_thread_ended_at_close) { [] }
      let(:lines_drawn_at_close) { [] }

      before do
        File.write(settings_path, <<~XML)
          <settings>
            <layout id='default'>
              <window class='text' top='0' left='0' height='6' width='60' value='main'/>
              <window class='countdown' top='6' left='0' height='1' width='10' value='roundtime'/>
              <window class='command' top='7' left='0' height='1' width='60'/>
            </layout>
          </settings>
        XML
        # Pause after closing the screen, as a thread switch there would: a
        # draw now reopens curses' alternate screen, and the error printed
        # next lands on it and is discarded at exit.
        allow(Curses).to receive(:close_screen) do
          events << [:close_screen, $stderr.string.dup]
          server_thread_ended_at_close << app.connection.ended?
          lines_drawn_at_close << lines_drawn
          sleep 0.05
        end
        # The real render lock, so the two threads really take turns.
        allow(CursesRenderer).to receive(:synchronize) { |&block| monitor.synchronize(&block) }
        allow(CursesRenderer).to receive(:render) { |&block| monitor.synchronize(&block) }
        @writer = Thread.new do
          loop { game_end.write("A goblin arrives.\n" * 50) }
        rescue IOError, SystemCallError
          nil
        end
      end

      after do
        game_end.close
        @writer.join(5)
      end

      # How many times text was written to the main window
      def lines_drawn = main.call_log.count { |name, _| name == :addstr }

      it 'stops the server thread before closing the screen, so nothing is drawn over the error' do
        status, stderr = run_client(keyboard(wait_until { lines_drawn > 20 }, read_fails), server: sockets.first)

        expect(status).to eq 1
        expect(stderr).to include('RuntimeError: boom')
        expect(server_thread_ended_at_close.first).to be true
        expect(lines_drawn).to eq lines_drawn_at_close.first
      end

      it 'exits 1 the same way when the error is raised with the render lock held' do
        roundtime_tick_fails = lambda do
          allow(app.window_mgr.countdown['roundtime']).to receive(:tick).and_raise(RuntimeError, 'tick failed')
        end

        status, stderr = run_client(keyboard(wait_until { lines_drawn > 20 }, roundtime_tick_fails, idle: true),
                                    server: sockets.first)

        expect(status).to eq 1
        expect(stderr).to include('RuntimeError: tick failed')
        expect(server_thread_ended_at_close.first).to be true
        expect(lines_drawn).to eq lines_drawn_at_close.first
      end
    end
  end
end
