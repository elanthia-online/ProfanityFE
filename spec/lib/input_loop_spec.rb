# frozen_string_literal: true

# Tests the input loop of the real client (Application#run) on the
# virtual screen, fed by a scripted keyboard: key bindings and key combos,
# typing non-ASCII characters, keys curses already holds, terminal
# resizes, the countdowns it ticks on every poll, and how an error outside
# a key handler ends the client.

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

  # The waits for a key (their timeouts, in seconds) from the first key the
  # keyboard handed the input loop to the last; a zero timeout only looks
  # whether stdin has input and is not counted.
  def waits_between_keys
    first = input_log.index { |kind, _| kind == :key }
    last = input_log.rindex { |kind, _| kind == :key }
    input_log[first..last].filter_map { |kind, seconds| seconds if kind == :wait && seconds.positive? }
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

  # BUG FOUND (fixed here): after each key the input loop waited up to 0.1 s
  # for input on stdin before reading the next, even when curses already
  # held that key, so each such key came 0.1 s late. Curses reads an
  # alt+N's Escape and digit together (to tell it from a lone Escape) and
  # keeps the digit: every alt+N took 0.1 s (measured in a PTY: 100-105 ms
  # per alt+N on 42c9bce, 0.1 ms with the fix). Keys still on stdin take
  # one pass of the loop each, as before.
  describe 'keys curses already holds' do
    before do
      File.write(settings_path, settings_binding(<<~XML))
        <key id='enter' action='send_command'/>
        <key id='alt+2' action='switch_tab_2'/>
      XML
    end

    it 'handles them in order without waiting for input before each' do
      run_client(keyboard("look\n"))

      expect(game_server.commands).to eq ['look']
      expect(waits_between_keys).to eq []
    end

    it 'fires alt+2 without waiting for input between the Escape and the digit' do
      run_client(keyboard("\e", '2'))

      expect(tabbed.active_tab).to eq 'logons'
      expect(waits_between_keys).to eq []
    end

    it 'polls stdin before each key, as before, while stdin has input waiting' do
      run_client(keyboard("look\n"), stdin_ready: true)

      expect(game_server.commands).to eq ['look']
      expect(waits_between_keys).to eq [Application::INPUT_POLL_SECONDS] * 4
    end

    it 'ends the session, as before, without handling the keys after the game hung up' do
      hang_up = lambda do
        game_server.hang_up
        deadline = Time.now + ClientRun::DEADLINE
        sleep 0.001 until app.connection.ended? || Time.now > deadline
      end

      status, = run_client(keyboard(press_after('a', &hang_up), "b\n"))

      expect(status).to eq 0
      expect(main.rows).to include('* Connection closed')
      expect(command_line.row(0)).to eq 'a'
      expect(game_server.commands).to eq []
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
    # default.xml sizes main lines-2 high and (cols/3)*2 wide, less the
    # column its scrollbar takes: [maxy, maxx] at 60x200 and at 40x150
    let(:main_size_at_60x200) { [58, 131] }
    let(:main_size_at_40x150) { [38, 99] }

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

    # A keyboard step: no key until the main window has the size it has at
    # 40x150 (the layout waits for the terminal to stop resizing first).
    def until_fitted = wait_until { [main.maxy, main.maxx] == main_size_at_40x150 }

    it 'fits the layout to the new size when the settings file does not bind the resize key' do
      run_client(keyboard(resize_terminal, until_fitted))

      expect(main_size_before_resize).to eq main_size_at_60x200
      expect([main.maxy, main.maxx]).to eq main_size_at_40x150
    end

    it 'still fits the layout after a .reload' do
      run_client(keyboard(".reload\n", resize_terminal, until_fitted))

      expect([main.maxy, main.maxx]).to eq main_size_at_40x150
    end

    it 'fits the layout while a key combo is pending, and keeps the combo' do
      # A lone Escape starts the alt+N combos (alt+2: switch_tab_2)
      run_client(keyboard("\e", resize_terminal, '2'))

      expect([main.maxy, main.maxx]).to eq main_size_at_40x150
      expect(main.active_tab).to eq 'combat'
    end

    context 'when the settings file binds the resize key' do
      let(:settings) { super().sub('</settings>', "<key id='resize' macro='look\\r'/></settings>") }

      it 'runs that binding instead' do
        run_client(keyboard(resize_terminal, wait_until { game_server.commands.any? }))

        expect(game_server.commands).to eq ['look']
        expect([main.maxy, main.maxx]).to eq main_size_at_60x200
      end
    end

    # .key reads the next key itself, holding the render lock. A resize in
    # its wait is not the key: it is fitted once .key is done.
    describe 'while .key waits for a key' do
      it 'shows the key pressed after the resize, not the resize, then fits the layout' do
        run_client(keyboard(".key\n", resize_terminal, 'q', until_fitted))

        expect(main.rows).to include('* Detected keycode: q')
        expect(main.rows.grep(/keycode: #{Curses::KEY_RESIZE}/)).to be_empty
        expect([main.maxy, main.maxx]).to eq main_size_at_40x150
      end

      it 'says no key was pressed when no key follows the resize, then fits the layout' do
        run_client(keyboard(".key\n", resize_terminal, until_fitted))

        expect(main.rows).to include('* No key pressed within 5 seconds')
        expect([main.maxy, main.maxx]).to eq main_size_at_40x150
      end

      context 'when the settings file binds the resize key' do
        let(:settings) { super().sub('</settings>', "<key id='resize' macro='look\\r'/></settings>") }

        it 'runs that binding once .key has its key' do
          run_client(keyboard(".key\n", resize_terminal, 'q', wait_until { game_server.commands.any? }))

          expect(main.rows).to include('* Detected keycode: q')
          expect(game_server.commands).to eq ['look']
        end
      end
    end

    # A terminal drag sends a burst of resizes. The layout (and every text
    # window's re-wrap of its lines) waits until no resize has come for
    # 0.1 s, then fits once, at the final size. Time is the input loop's
    # monotonic clock, moved only by the keyboard steps below.
    describe 'a burst of resizes (a terminal drag)' do
      let(:clock) { [100.0] }
      # The main window's [maxy, maxx] at each step that records it
      let(:layout_seen) { [] }
      # The terminal's [lines, cols] each time the layout was fitted to it,
      # first when the client started
      let(:fitted_at) { [] }
      let(:main_size_at_50x180) { [48, 119] }
      let(:main_size_at_45x165) { [43, 109] }
      # The clock each time the layout was fitted
      let(:fitted_when) { [] }

      before do
        allow(Process).to receive(:clock_gettime).and_call_original
        allow(Process).to receive(:clock_gettime).with(Process::CLOCK_MONOTONIC) { clock[0] }
        allow(app.window_mgr).to receive(:resize).and_wrap_original do |resize, *args|
          fitted_at << [Curses.lines, Curses.cols]
          fitted_when << clock[0].round(3)
          resize.call(*args)
        end
      end

      # A keyboard step: record the main window's size, then resize the
      # terminal and deliver the key ncurses sends for it.
      def resize_to(lines, cols)
        press_after(Curses::KEY_RESIZE) do
          layout_seen << [main.maxy, main.maxx]
          terminal.merge!(lines: lines, cols: cols)
        end
      end

      # A keyboard step: +seconds+ pass with no key pressed; then record
      # the main window's size.
      def pause(seconds)
        lambda do
          clock[0] += seconds
          layout_seen << [main.maxy, main.maxx]
        end
      end

      # A keyboard step: from here on, each wait for a key lasts its whole
      # timeout on the clock, as the real wait does when no key comes (and,
      # like it, refuses a negative timeout).
      def waits_take_their_time
        lambda do
          allow(IO).to receive(:select) do |readers, _writers, _errors, timeout|
            next nil unless readers == [$stdin]
            raise ArgumentError, 'time interval must not be negative' if timeout.negative?

            clock[0] += timeout
            sleep 0.0002
            nil
          end
        end
      end

      describe 'while .key waits for a key' do
        # A keyboard step: +seconds+ pass, then the terminal is resized
        # (as in resize_to).
        def resize_after(seconds, lines, cols)
          press_after(Curses::KEY_RESIZE) do
            clock[0] += seconds
            terminal.merge!(lines: lines, cols: cols)
          end
        end

        # How long each read of the command window may wait, in ms
        def key_waits = command_line.call_log.select { |name, _| name == :timeout= }.map { |_, (ms)| ms }

        it "waits for what is left of .key's 5 seconds after each resize, then fits the layout once" do
          run_client(keyboard(".key\n", resize_after(1, 50, 180), resize_after(1.5, 40, 150), 'q',
                              pause(0.2), pause(0)))

          expect(key_waits).to eq [5000, 4000, 2500]
          expect(main.rows).to include('* Detected keycode: q')
          expect(fitted_at).to eq [[60, 200], [40, 150]]
        end

        it 'ends the wait when a resize comes as the 5 seconds run out, then fits the layout' do
          run_client(keyboard(".key\n", resize_after(5, 40, 150), pause(0.2), pause(0)))

          expect(key_waits).to eq [5000]
          expect(main.rows).to include('* No key pressed within 5 seconds')
          expect(fitted_at).to eq [[60, 200], [40, 150]]
        end
      end

      it 'fits the layout once, at the final size, after resizes less than 0.1 s apart' do
        run_client(keyboard(resize_to(50, 180), pause(0.09), resize_to(45, 165), pause(0.09),
                            resize_to(40, 150), pause(0.09), pause(0.02), pause(0)))

        expect(layout_seen).to eq [main_size_at_60x200] * 7 + [main_size_at_40x150]
        expect(fitted_at).to eq [[60, 200], [40, 150]]
      end

      it 'fits the layout 0.1 s after a single resize' do
        run_client(keyboard(resize_to(40, 150), pause(0.09), pause(0.02), pause(0)))

        expect(layout_seen).to eq [main_size_at_60x200] * 3 + [main_size_at_40x150]
        expect(fitted_at).to eq [[60, 200], [40, 150]]
      end

      it 'fits the layout once for resizes already queued when it reads them' do
        run_client(keyboard(resize_to(50, 180), resize_to(45, 165), resize_to(40, 150), pause(0.2), pause(0)))

        expect(layout_seen).to eq [main_size_at_60x200] * 4 + [main_size_at_40x150]
        expect(fitted_at).to eq [[60, 200], [40, 150]]
      end

      it 'fits resizes already queued 0.1 s after it reads them all, not 0.1 s per resize' do
        # The next wait ends at 100.1, when all three resizes are read
        run_client(keyboard(waits_take_their_time, resize_to(50, 180), resize_to(45, 165), resize_to(40, 150),
                            wait_until { fitted_at.size == 2 }))

        expect(fitted_at).to eq [[60, 200], [40, 150]]
        expect(fitted_when).to eq [100.0, 100.2]
      end

      it 'fits a single resize 0.1 s after it is read, waiting only for what is left of that' do
        # The resize is read at 100.1, then 0.03 s go by
        run_client(keyboard(waits_take_their_time, resize_to(40, 150), pause(0.03),
                            wait_until { fitted_at.size == 2 }))

        expect(fitted_at).to eq [[60, 200], [40, 150]]
        expect(fitted_when).to eq [100.0, 100.2]
      end

      it 'fits the layout before a key typed in the burst, then handles the keys in order' do
        command_line_seen = []
        see_command_line = -> { command_line_seen << command_line.row(0) }

        run_client(keyboard(resize_to(50, 180), resize_to(45, 165), 'a', see_command_line,
                            resize_to(40, 150), 'b', see_command_line, pause(0.2)))

        # fitted at 45x165 before "a", at 40x150 before "b"
        expect(layout_seen).to eq [main_size_at_60x200, main_size_at_60x200, main_size_at_45x165,
                                   main_size_at_40x150]
        expect(command_line_seen).to eq %w[a ab]
        expect(fitted_at).to eq [[60, 200], [45, 165], [40, 150]]
      end

      it 'fits the layout before a key curses holds behind a resize, without waiting for input first' do
        seen_after_b = []
        see_after_b = -> { seen_after_b << [command_line.row(0), main.maxy, main.maxx] }

        run_client(keyboard('a', resize_to(40, 150), 'b', see_after_b, pause(0.2), pause(0)))

        expect(seen_after_b).to eq [['ab', *main_size_at_40x150]]
        expect(fitted_at).to eq [[60, 200], [40, 150]]
        expect(waits_between_keys).to eq []
      end

      it 'fits the layout when the game hangs up before the burst is over' do
        status, = run_client(keyboard(resize_to(40, 150), -> { game_server.hang_up }, idle: true))

        expect(status).to eq 0
        expect(fitted_at).to eq [[60, 200], [40, 150]]
        expect([main.maxy, main.maxx]).to eq main_size_at_40x150
      end

      context 'when the settings file binds the resize key' do
        let(:settings) { super().sub('</settings>', "<key id='resize' macro='look\\r'/></settings>") }

        it 'runs that binding once for the burst' do
          run_client(keyboard(resize_to(50, 180), pause(0.05), resize_to(45, 165), pause(0.05),
                              resize_to(40, 150), pause(0.2)))

          expect(game_server.commands).to eq ['look']
        end

        it 'runs that binding once for the rest of a burst that follows a lone Escape' do
          # The pending combo takes the first resize, as it takes any key it
          # does not list
          run_client(keyboard("\e", resize_to(50, 180), resize_to(45, 165), resize_to(40, 150), pause(0.2)))

          expect(game_server.commands).to eq ['look']
        end
      end

      # original.xml and tysong.xml bind the resize key to the resize action,
      # and Escape starts their alt combos, like default.xml's alt+N
      context 'when the settings file binds the resize key to the resize action' do
        let(:settings) { super().sub('</settings>', "<key id='resize' action='resize'/></settings>") }

        it 'fits the layout once, at the final size, for a burst that follows a lone Escape' do
          run_client(keyboard("\e", resize_to(50, 180), resize_to(45, 165), resize_to(40, 150),
                              pause(0.2), pause(0)))

          expect(fitted_at).to eq [[60, 200], [40, 150]]
          expect([main.maxy, main.maxx]).to eq main_size_at_40x150
        end

        it 'does not fit a single resize that follows a lone Escape: the pending combo takes it' do
          run_client(keyboard("\e", resize_to(40, 150), pause(0.2), pause(0)))

          expect(fitted_at).to eq [[60, 200]]
          expect([main.maxy, main.maxx]).to eq main_size_at_60x200
        end
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
