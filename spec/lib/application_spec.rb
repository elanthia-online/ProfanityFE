# frozen_string_literal: true

# Tests Application's initialization, dot-command dispatch (.quit, .help,
# .links, .arrow, .layout, .key), macro engine (\\r, \\x, @), key action
# bindings, and countdown tick polling.

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
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../../lib/event_bus'
require_relative '../support/screen_line_window'

# Stub ColorManager for .fixcolor tests
module ColorManager
  def self.reinitialize_colors = nil
  def self.configure(**) = nil
end unless defined?(ColorManager)

RSpec.describe Application do
  # Stub MouseScroll to avoid Curses.mousemask calls
  before do
    allow(MouseScroll).to receive(:new).and_return(mock_mouse_scroll)
  end

  let(:mock_mouse_scroll) do
    obj = Object.new
    def obj.enable_click_events = nil
    def obj.disable_click_events = nil
    def obj.configuring? = false
    def obj.process(*) = nil
    def obj.start_configuration = nil
    obj
  end

  let(:cli_options) do
    {
      port: 8000, char: nil, config: nil, template: nil,
      default_color_id: 7, default_background_color_id: 0,
      use_default_colors: false, custom_colors: nil,
      settings_file: nil, no_status: true, links: false,
      speech_ts: false, room_window_only: false,
      remote_url: false, log_file: nil, log_dir: nil,
    }
  end

  # The settings file, game host and port handed to Application. Groups that
  # load settings or connect override them.
  let(:settings_path) { File.join(SPEC_HOME, 'settings.xml') }
  let(:host) { '127.0.0.1' }
  let(:port) { 8000 }
  let(:app) { new_app }

  # Build an Application with the given CLI options and the settings file,
  # host and port above.
  def new_app(options = cli_options)
    described_class.new(options, settings_file: settings_path, host: host, port: port)
  end

  # Mock window for recording calls
  let(:main_window) do
    obj = Object.new
    def obj.calls = @calls ||= []
    def obj.add_string(text, colors = []) = calls << { text: text, colors: colors }
    def obj.route_string(text, _colors, stream, **_opts) = calls << { text: text, stream: stream }
    def obj.respond_to?(m, *) = m == :buffer ? false : super
    obj
  end

  # Wire up the main window
  before do
    app.window_mgr.instance_variable_set(:@stream, { 'main' => main_window })
  end

  # ---- Initialization ----

  describe '#initialize' do
    it 'creates shared_state with defaults' do
      expect(app.shared_state).to be_a(SharedState)
      expect(app.shared_state.prompt_text).to eq '>'
    end

    it 'creates command_buffer' do
      expect(app.cmd_buffer).to be_a(CommandBuffer)
    end

    it 'creates window_mgr' do
      expect(app.window_mgr).to be_a(WindowManager)
    end

    it 'populates key_action hash with all expected actions' do
      expected_actions = %w[
        resize cursor_left cursor_right cursor_word_left cursor_word_right
        cursor_home cursor_end cursor_backspace cursor_delete
        cursor_backspace_word cursor_delete_word cursor_kill_forward
        cursor_kill_line cursor_yank switch_current_window next_tab prev_tab
        scroll_current_window_up_one scroll_current_window_down_one
        scroll_current_window_up_page scroll_current_window_down_page
        scroll_current_window_bottom previous_command next_command
        switch_arrow_mode send_command send_last_command
        send_second_last_command autocomplete
      ]
      expected_actions.each do |action|
        expect(app.key_action[action]).to be_a(Proc), "missing key_action '#{action}'"
      end
    end

    it 'populates tab switching actions 1-5' do
      (1..5).each do |n|
        expect(app.key_action["switch_tab_#{n}"]).to be_a(Proc)
      end
    end

    it 'aliases switch_tab to next_tab' do
      expect(app.key_action['switch_tab']).to equal(app.key_action['next_tab'])
    end

    it 'aliases switch_tab_reverse to prev_tab' do
      expect(app.key_action['switch_tab_reverse']).to equal(app.key_action['prev_tab'])
    end

    it 'sets blue_links from cli_options' do
      app_with_links = new_app(cli_options.merge(links: true))
      expect(app_with_links.shared_state.blue_links).to be true
    end
  end

  # ---- Dot-command dispatch ----

  describe '#execute_command' do
    it '.quit exits' do
      expect { app.execute_command('.quit') }.to raise_error(SystemExit)
    end

    it '.quit is case-insensitive' do
      expect { app.execute_command('.QUIT') }.to raise_error(SystemExit)
    end

    it '.fixcolor calls ColorManager.reinitialize_colors' do
      expect(ColorManager).to receive(:reinitialize_colors)
      app.execute_command('.fixcolor')
    end

    it '.resync resets skip_server_time_offset' do
      app.shared_state.skip_server_time_offset = true
      app.execute_command('.resync')
      expect(app.shared_state.skip_server_time_offset).to be false
    end

    it '.help displays help text to main window' do
      app.execute_command('.help')
      help_texts = main_window.calls.select { |c| c[:text]&.include?('.quit') }
      expect(help_texts).not_to be_empty
    end

    it '.links toggles blue_links state' do
      expect(app.shared_state.blue_links).to be false
      app.execute_command('.links')
      expect(app.shared_state.blue_links).to be true
      app.execute_command('.links')
      expect(app.shared_state.blue_links).to be false
    end

    it '.arrow cycles through modes' do
      # Set up initial arrow binding
      app.key_binding[Curses::KEY_UP] = app.key_action['previous_command']
      app.execute_command('.arrow')
      expect(app.key_binding[Curses::KEY_UP]).to eq app.key_action['scroll_current_window_up_page']
    end

    it 'forwards unknown dot-commands to server with . replaced by ;' do
      server = StringIO.new
      app.instance_variable_set(:@server, server)
      app.execute_command('.script start')
      expect(server.string).to eq ";script start\n"
    end

    it 'forwards non-dot commands to server' do
      server = StringIO.new
      app.instance_variable_set(:@server, server)
      app.execute_command('go north')
      # Non-dot commands don't match any dot-command, so they go to the
      # else branch which does server.puts cmd.sub(/^\./, ';')
      # But 'go north' doesn't start with '.', so sub is a no-op
      expect(server.string).to eq "go north\n"
    end

    # Adversarial
    it 'does not crash on empty command' do
      server = StringIO.new
      app.instance_variable_set(:@server, server)
      expect { app.execute_command('') }.not_to raise_error
    end

    it '.tab with no tabbed windows shows message' do
      app.execute_command('.tab')
      msg = main_window.calls.find { |c| c[:text]&.include?('No tabbed') }
      expect(msg).not_to be_nil
    end

    it '.layout with unknown layout does not crash' do
      expect { app.execute_command('.layout nonexistent') }.not_to raise_error
    end

    # ---- Whole-word matching ----
    #
    # BUG FOUND (fixed here): dot-commands matched by prefix, so a Lich
    # script whose name merely started with a dot-command name was
    # swallowed locally instead of being forwarded, and `.quitter` exited
    # the client. A dot-command now matches only when its name is followed
    # by whitespace or the end of the input.
    describe 'whole-word matching' do
      let(:server) { StringIO.new }

      before { app.instance_variable_set(:@server, server) }

      {
        '.quitter'         => ";quitter\n",
        '.arrows'          => ";arrows\n",
        '.arrows 5'        => ";arrows 5\n",
        '.linkstat'        => ";linkstat\n",
        '.help-me'         => ";help-me\n",
        '.keymaster'       => ";keymaster\n",
        '.tabulate'        => ";tabulate\n",
        '.tabulate skills' => ";tabulate skills\n",
        '.selectgem'       => ";selectgem\n",
        '.highlighter'     => ";highlighter\n",
        '.reloadall'       => ";reloadall\n",
        '.resizer'         => ";resizer\n",
        '.ARROWS'          => ";ARROWS\n",
      }.each do |typed, forwarded|
        it "forwards the look-alike script command #{typed.inspect} to the server as #{forwarded.chomp.inspect}" do
          expect { app.execute_command(typed) }.not_to raise_error
          expect(server.string).to eq forwarded
        end
      end

      it 'handles .arrow typed exactly as the local arrow-mode toggle' do
        expect(app).to receive(:handle_dot_arrow)
        app.execute_command('.arrow')
        expect(server.string).to be_empty
      end

      it 'handles .links typed exactly as the local link toggle, not the links script' do
        expect(app).to receive(:handle_dot_links)
        app.execute_command('.links')
        expect(server.string).to be_empty
      end

      it 'handles .help followed by trailing whitespace as the local help command' do
        expect(app).to receive(:handle_dot_help)
        app.execute_command('.help ')
        expect(server.string).to be_empty
      end

      it 'handles .layout default locally by loading the named layout' do
        expect(app.window_mgr).to receive(:load_layout).with('default')
        app.execute_command('.layout default')
        expect(server.string).to be_empty
      end

      it 'handles .tab thoughts locally by switching to the named tab' do
        expect(app).to receive(:handle_dot_tab).with('thoughts')
        app.execute_command('.tab thoughts')
        expect(server.string).to be_empty
      end

      it 'handles .highlight goblin locally by adding an inline highlight' do
        expect(app).to receive(:handle_dot_highlight).with('goblin')
        app.execute_command('.highlight goblin')
        expect(server.string).to be_empty
      end

      it 'handles .unhighlight goblin locally by removing an inline highlight' do
        expect(app).to receive(:handle_dot_unhighlight).with('goblin')
        app.execute_command('.unhighlight goblin')
        expect(server.string).to be_empty
      end

      it 'handles .LAYOUT default case-insensitively like every other dot-command' do
        expect(app.window_mgr).to receive(:load_layout).with('default')
        app.execute_command('.LAYOUT default')
        expect(server.string).to be_empty
      end

      it 'handles .TAB thoughts case-insensitively and keeps the argument as typed' do
        expect(app).to receive(:handle_dot_tab).with('thoughts')
        app.execute_command('.TAB thoughts')
        expect(server.string).to be_empty
      end

      it 'handles .Arrow case-insensitively as the local arrow-mode toggle' do
        expect(app).to receive(:handle_dot_arrow)
        app.execute_command('.Arrow')
        expect(server.string).to be_empty
      end
    end
  end

  # ---- Macro engine ----

  describe '#do_macro' do
    before do
      app.cmd_buffer.window = Curses::Window.new(1, 80, 0, 0)
    end

    it 'types characters into the command buffer' do
      app.do_macro('hello')
      expect(app.cmd_buffer.text).to eq 'hello'
    end

    it 'handles \\\\ as literal backslash' do
      app.do_macro('a\\\\b')
      expect(app.cmd_buffer.text).to eq 'a\\b'
    end

    it 'handles \\x to clear the buffer' do
      app.do_macro('hello\\xworld')
      expect(app.cmd_buffer.text).to eq 'world'
    end

    it 'handles \\@ as literal @' do
      app.do_macro('email\\@test')
      expect(app.cmd_buffer.text).to eq 'email@test'
    end

    it 'handles @ to mark cursor position' do
      app.do_macro('hello@world')
      # Cursor should be at position 5 (between 'hello' and 'world')
      expect(app.cmd_buffer.pos).to eq 5
      expect(app.cmd_buffer.text).to eq 'helloworld'
    end

    it 'handles \\r to send command' do
      server = StringIO.new
      app.instance_variable_set(:@server, server)
      app.do_macro('go north\\r')
      # The command should have been sent
      expect(server.string).to include('go north')
      # Buffer should be cleared after send
      expect(app.cmd_buffer.text).to eq ''
    end

    # Adversarial
    it 'handles empty macro' do
      expect { app.do_macro('') }.not_to raise_error
    end

    it 'handles macro with only escape sequences' do
      server = StringIO.new
      app.instance_variable_set(:@server, server)
      expect { app.do_macro('\\x\\r') }.not_to raise_error
    end

    it 'handles trailing backslash (incomplete escape)' do
      app.do_macro('hello\\')
      # Trailing backslash sets backslash=true but loop ends
      expect(app.cmd_buffer.text).to eq 'hello'
    end

    it 'handles multiple @ markers (last one wins)' do
      app.do_macro('a@b@c')
      # Second @ overwrites at_pos
      expect(app.cmd_buffer.pos).to eq 2
      expect(app.cmd_buffer.text).to eq 'abc'
    end
  end

  # ---- Key actions ----

  describe 'key actions' do
    before do
      app.cmd_buffer.window = Curses::Window.new(1, 80, 0, 0)
    end

    it 'send_command clears buffer, echoes prompt, and dispatches' do
      server = StringIO.new
      app.instance_variable_set(:@server, server)
      app.cmd_buffer.put_ch('g')
      app.cmd_buffer.put_ch('o')
      app.key_action['send_command'].call
      expect(server.string).to include('go')
      expect(app.cmd_buffer.text).to eq ''
    end

    it 'send_last_command resends from history' do
      server = StringIO.new
      app.instance_variable_set(:@server, server)
      app.cmd_buffer.add_to_history('look')
      app.key_action['send_last_command'].call
      expect(server.string).to include('look')
    end

    it 'scroll_current_window_bottom returns to the newest rows when scrolled back more rows than the buffer size' do
      # Keeps 2 lines, wrapped at 10 columns: 9 rows.
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout><window class='text' top='0' left='0' height='3' width='12' value='main' buffer-size='2'/></layout>
      XML
      app.window_mgr.load_layout('test')
      window = app.window_mgr.stream['main']
      ['one two three four five six seven', 'one two three four'].each { |line| window.add_string(line) }
      window.scroll_lines(-window.maxy)
      expect(window.buffer_pos).to be > window.max_buffer_size

      app.key_action['scroll_current_window_bottom'].call

      expect(window.rows).to eq ['one two', '  three', '  four']
      expect(window.buffer_pos).to eq 0
    end

    context 'with an unsent draft stashed by the up arrow' do
      let(:server) { StringIO.new }
      let(:screen) { ScreenLineWindow.new(20) }

      before do
        app.instance_variable_set(:@server, server)
        app.cmd_buffer.window = screen
      end

      def type_and_send(str)
        str.each_char { |ch| app.cmd_buffer.put_ch(ch) }
        app.key_action['send_command'].call
      end

      # Type "draft", press up (the line shows "look"), press enter to
      # resend "look", then send "exp1". The draft was never sent.
      before do
        type_and_send('look')
        'draft'.each_char { |ch| app.cmd_buffer.put_ch(ch) }
        app.key_action['previous_command'].call
        app.key_action['send_command'].call
        type_and_send('exp1')
        server.truncate(0)
        server.rewind
      end

      it 'send_second_last_command sends the second-last sent line, not the draft' do
        app.key_action['send_second_last_command'].call
        expect(server.string).to eq "look\n"
      end

      it 'send_last_command sends the last sent line' do
        app.key_action['send_last_command'].call
        expect(server.string).to eq "exp1\n"
      end

      it 'the up arrow recalls only sent lines' do
        recalled = Array.new(3) do
          app.key_action['previous_command'].call
          screen.visible
        end
        expect(recalled).to eq %w[exp1 look look]
      end
    end

    it 'autocomplete does not complete from an unsent draft' do
      screen = ScreenLineWindow.new(20)
      app.cmd_buffer.window = screen
      app.cmd_buffer.add_to_history('look')
      'draft'.each_char { |ch| app.cmd_buffer.put_ch(ch) }
      app.key_action['previous_command'].call
      app.key_action['next_command'].call
      app.cmd_buffer.kill_line
      'dr'.each_char { |ch| app.cmd_buffer.put_ch(ch) }
      app.key_action['autocomplete'].call
      expect(screen.visible).to eq 'dr'
    end

    it 'cursor actions delegate to cmd_buffer' do
      app.cmd_buffer.put_ch('a')
      app.cmd_buffer.put_ch('b')
      app.key_action['cursor_left'].call
      expect(app.cmd_buffer.pos).to eq 1
      app.key_action['cursor_home'].call
      expect(app.cmd_buffer.pos).to eq 0
      app.key_action['cursor_end'].call
      expect(app.cmd_buffer.pos).to eq 2
    end

    it 'switch_arrow_mode cycles through three modes' do
      app.key_binding[Curses::KEY_UP] = app.key_action['previous_command']

      app.key_action['switch_arrow_mode'].call
      expect(app.key_binding[Curses::KEY_UP]).to eq app.key_action['scroll_current_window_up_page']

      app.key_action['switch_arrow_mode'].call
      expect(app.key_binding[Curses::KEY_UP]).to eq app.key_action['scroll_current_window_up_one']

      app.key_action['switch_arrow_mode'].call
      expect(app.key_binding[Curses::KEY_UP]).to eq app.key_action['previous_command']
    end

    it 'autocomplete calls Autocomplete.complete' do
      expect(Autocomplete).to receive(:complete).with(app.cmd_buffer, main_window)
      app.key_action['autocomplete'].call
    end
  end

  # ---- Regression: editing key actions must flush the physical screen ----
  #
  # CommandBuffer edits only stage changes to the curses virtual screen
  # (via noutrefresh). Nothing appears on the terminal until doupdate is
  # called. Every key action that mutates the visible command line must
  # therefore end with CursesRenderer.doupdate, otherwise the edit stays
  # invisible until the next keystroke happens to trigger a flush.
  #
  # BUG FOUND (fixed here): cursor_backspace_word, cursor_delete_word, and
  # cursor_yank omitted the doupdate call, so word-delete and yank appeared
  # to "do nothing" until the user typed the next character.
  describe 'editing key actions flush with doupdate' do
    before do
      app.cmd_buffer.window = Curses::Window.new(1, 80, 0, 0)
    end

    # Every action listed here mutates the visible line and MUST repaint.
    editing_actions = %w[
      cursor_left cursor_right cursor_word_left cursor_word_right
      cursor_home cursor_end cursor_backspace cursor_delete
      cursor_backspace_word cursor_delete_word cursor_kill_forward
      cursor_kill_line cursor_yank
    ]

    editing_actions.each do |action|
      it "#{action} calls CursesRenderer.doupdate" do
        expect(CursesRenderer).to receive(:doupdate)
        app.key_action[action].call
      end
    end

    # ---- The three previously-broken actions, tested behaviorally ----

    it 'cursor_backspace_word deletes the previous word and repaints' do
      app.do_macro('hello world')
      expect(CursesRenderer).to receive(:doupdate)
      app.key_action['cursor_backspace_word'].call
      expect(app.cmd_buffer.text).to eq 'hello '
    end

    it 'cursor_delete_word deletes the next word and repaints' do
      app.do_macro('hello world')
      app.cmd_buffer.cursor_home
      expect(CursesRenderer).to receive(:doupdate)
      app.key_action['cursor_delete_word'].call
      expect(app.cmd_buffer.text).to eq ' world'
    end

    it 'cursor_yank restores killed text and repaints' do
      app.do_macro('hello')
      app.key_action['cursor_kill_line'].call # fills the kill ring, clears line
      expect(app.cmd_buffer.text).to eq ''
      expect(CursesRenderer).to receive(:doupdate)
      app.key_action['cursor_yank'].call
      expect(app.cmd_buffer.text).to eq 'hello'
    end

    # ---- Adversarial: no-op edits must still flush ----
    #
    # A word-delete on an empty buffer changes nothing, but the action must
    # not silently skip doupdate -- the invariant is "always repaint after an
    # edit action", regardless of whether the buffer actually changed.

    it 'cursor_backspace_word on an empty buffer still calls doupdate' do
      expect(app.cmd_buffer.text).to eq ''
      expect(CursesRenderer).to receive(:doupdate)
      app.key_action['cursor_backspace_word'].call
    end

    it 'cursor_yank with an empty kill ring still calls doupdate' do
      expect(app.cmd_buffer.text).to eq ''
      expect(CursesRenderer).to receive(:doupdate)
      app.key_action['cursor_yank'].call
      expect(app.cmd_buffer.text).to eq ''
    end
  end

  # ---- Adversarial: initialization edge cases ----

  describe 'adversarial initialization' do
    it 'handles nil char_name' do
      app_nil = new_app(cli_options.merge(char: nil))
      expect(app_nil.shared_state.char_name).to eq 'ProfanityFE'
    end

    it 'capitalizes char_name' do
      app_char = new_app(cli_options.merge(char: 'mahtra'))
      expect(app_char.shared_state.char_name).to eq 'Mahtra'
    end

    it 'key_action cursor procs are safe without window' do
      expect { app.key_action['cursor_left'].call }.not_to raise_error
    end
  end

  # ---- Countdown ticker ----

  describe '#tick_countdowns' do
    let(:countdown_window) do
      obj = Object.new
      def obj.updates = @updates ||= []

      def obj.tick
        updates << Time.now
        updates.length <= 3 # return true for first 3 calls
      end
      obj
    end

    before do
      app.window_mgr.instance_variable_set(:@countdown, { 'roundtime' => countdown_window })
      app.cmd_buffer.window = Curses::Window.new(1, 80, 0, 0)
    end

    it 'ticks every countdown window' do
      app.send(:tick_countdowns)
      expect(countdown_window.updates.length).to eq 1
    end

    it 'returns true when any countdown changed' do
      expect(app.send(:tick_countdowns)).to be true
    end

    it 'refreshes cmd_buffer window when countdown changed' do
      app.cmd_buffer.window.call_log.clear
      app.send(:tick_countdowns)
      expect(app.cmd_buffer.window.call_log.map(&:first)).to include(:noutrefresh)
    end

    it 'returns false when no countdowns are registered' do
      app.window_mgr.instance_variable_set(:@countdown, {})
      expect(app.send(:tick_countdowns)).to be false
    end

    it 'does not crash when cmd_buffer has no window' do
      app.cmd_buffer.window = nil
      expect { app.send(:tick_countdowns) }.not_to raise_error
    end

    it 'updates every countdown window and reports a change from any of them' do
      no_change = Object.new
      def no_change.tick = false
      stun_window = Object.new
      def stun_window.updates = @updates ||= 0
      def stun_window.tick = (@updates = updates + 1).positive?
      app.window_mgr.instance_variable_set(:@countdown, {
        'roundtime' => no_change,
        'stunned'   => stun_window,
      })
      expect(app.send(:tick_countdowns)).to be true
      expect(stun_window.updates).to eq 1
    end

    it 'returns false when all countdowns return false (no change)' do
      no_change = Object.new
      def no_change.tick = false
      app.window_mgr.instance_variable_set(:@countdown, { 'roundtime' => no_change })
      expect(app.send(:tick_countdowns)).to be false
    end

    it 'does not call noutrefresh when nothing changed' do
      no_change = Object.new
      def no_change.tick = false
      app.window_mgr.instance_variable_set(:@countdown, { 'roundtime' => no_change })
      app.cmd_buffer.window.call_log.clear
      app.send(:tick_countdowns)
      expect(app.cmd_buffer.window.call_log.map(&:first)).not_to include(:noutrefresh)
    end
  end

  # BUG FOUND (fixed here): input_loop puts the command window in nodelay
  # mode, and .key called getch on that same window, so getch returned nil
  # at once and .key printed "Detected keycode: " with no key.
  describe '.key' do
    # A command window that acts like curses: nodelay and timeout share one
    # delay setting. get_char returns nil in nodelay mode and the given key
    # (or the result of the block) when waiting is allowed.
    def key_window(key = nil, &on_wait)
      window = Object.new
      delays = []
      window.define_singleton_method(:delays) { delays }
      window.define_singleton_method(:nodelay=) { |on| delays << (on ? :nodelay : :blocking) }
      window.define_singleton_method(:timeout=) { |ms| delays << ms }
      window.define_singleton_method(:noutrefresh) { nil }
      window.define_singleton_method(:get_char) do
        next nil if delays.last == :nodelay

        on_wait ? on_wait.call : key
      end
      window.nodelay = true # as input_loop leaves it
      window
    end

    def feedback_texts = main_window.calls.map { |c| c[:text] }

    it 'waits for a key and prints its keycode' do
      app.cmd_buffer.window = key_window(Curses::KEY_UP)
      app.execute_command('.key')
      expect(feedback_texts).to include("* Detected keycode: #{Curses::KEY_UP}")
    end

    it 'bounds the wait with a timeout rather than blocking forever' do
      window = key_window(65)
      app.cmd_buffer.window = window
      app.execute_command('.key')
      expect(window.delays).to include(Application::DOT_KEY_TIMEOUT_MS)
    end

    it 'restores nodelay after reading the key' do
      window = key_window(65)
      app.cmd_buffer.window = window
      app.execute_command('.key')
      expect(window.delays.last(2)).to eq [Application::DOT_KEY_TIMEOUT_MS, :nodelay]
    end

    it 'reports that no key was pressed when the wait times out' do
      app.cmd_buffer.window = key_window(nil)
      app.execute_command('.key')
      expect(feedback_texts).to include(a_string_including('No key pressed'))
      expect(feedback_texts).not_to include(a_string_including('Detected keycode'))
    end

    it 'restores nodelay when the read raises' do
      window = key_window { raise IOError, 'terminal gone' }
      app.cmd_buffer.window = window
      expect { app.execute_command('.key') }.to raise_error(IOError)
      expect(window.delays.last).to eq :nodelay
    end
  end

  # BUG FOUND (fixed here): .reload cleared highlights and perc transforms
  # before parsing the file, so a typo in the settings file silently left
  # the user without them; the only trace was a line in the log.
  describe '.reload' do
    let(:settings_path) { File.join(@dir, 'settings.xml') }
    let(:settings) do
      <<~XML
        <settings>
          <highlight fg='ff0000'>goblin</highlight>
          <perc-transform pattern='Osrel Meraud' replace='OM'/>
          <key id='ctrl+x' action='previous_command'/>
          <layout id='default'>
            <window class='text' top='0' left='0' height='4' width='60' value='main'/>
            <window class='command' top='5' left='0' height='1' width='60'/>
          </layout>
        </settings>
      XML
    end
    let(:main) { app.window_mgr.stream['main'] }

    around do |example|
      Dir.mktmpdir { |dir| @dir = dir; example.run }
    end

    before do
      allow(ProfanityLog).to receive(:write)
      File.write(settings_path, settings)
      app.send(:load_settings_and_layout)
    end

    it 'keeps the settings and says why when the file is malformed' do
      File.write(settings_path, settings.sub('goblin</highlight>', 'kobold</hilight>'))

      app.execute_command('.reload')

      expect(HIGHLIGHT).to eq(/goblin/ => ['ff0000', nil, nil])
      expect(PERC_TRANSFORMS).to eq [[/Osrel Meraud/, 'OM']]
      expect(app.key_binding).to include(24 => app.key_action['previous_command'])
      expect(main.rows).to eq ['',
                               '',
                               '* Reload failed, settings unchanged: Missing end tag for',
                               "  'highlight' (got 'hilight') (line 2)"]
    end

    it 'shows the error in the feedback color' do
      File.write(settings_path, '<settings><gag>x</gags></settings>')
      allow(main).to receive(:add_string).and_call_original

      app.execute_command('.reload')

      msg = "* Reload failed, settings unchanged: Missing end tag for 'gag' (got 'gags') (line 1)"
      expect(main).to have_received(:add_string)
        .with(msg, [{ start: 0, end: msg.length, fg: FEEDBACK_COLOR, bg: nil, ul: nil }])
    end

    # BUG FOUND (fixed here): an empty file was reported as
    # "undefined method 'attributes' for nil".
    it 'keeps the settings and says the file is empty when it is empty' do
      File.write(settings_path, '')
      allow(main).to receive(:add_string).and_call_original

      app.execute_command('.reload')

      expect(HIGHLIGHT).to eq(/goblin/ => ['ff0000', nil, nil])
      expect(main).to have_received(:add_string)
        .with("* Reload failed, settings unchanged: Settings file is empty: #{settings_path}", anything)
    end

    it 'applies a good file without printing anything' do
      File.write(settings_path, settings.sub('goblin', 'kobold'))

      app.execute_command('.reload')

      expect(HIGHLIGHT).to eq(/kobold/ => ['ff0000', nil, nil])
      expect(main.rows).to eq ['', '', '', '']
    end

    it 'applies a changed history size to the command history' do
      File.write(settings_path, settings.sub('<settings>', '<settings><history-size>2</history-size>'))
      app.execute_command('.reload')
      %w[north south east].each { |c| app.cmd_buffer.add_to_history(c) }

      shown = Array.new(3) do
        app.key_action['previous_command'].call
        app.cmd_buffer.window.rows.first.rstrip
      end

      expect(shown).to eq %w[east south south]
    end

    # BUG FOUND (fixed here): .reload replaced the highlights with the
    # file's, so a .highlight added in the session stopped coloring text
    # while .highlight still listed it and .unhighlight claimed to remove it.
    context 'with an inline highlight' do
      let(:inline) { Application::INLINE_HIGHLIGHT_COLOR }
      # A distinct color pair per highlight color, so the screen shows which
      # color each character was drawn in.
      let(:pairs) { { inline => 1, 'ff0000' => 2 } }

      before do
        allow(IO).to receive(:select).and_return(nil)
        allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
      end

      # Feed lines through the real server thread, as the socket would, and
      # wait for it to finish.
      def receive_from_server(*lines)
        queue = lines.map { |line| "#{line}\r\n" }
        server = Object.new
        server.define_singleton_method(:gets) { queue.shift&.dup }
        app.instance_variable_set(:@server, server)
        app.send(:start_server_thread)
        app.instance_variable_get(:@session_end).pop
      end

      # The highlight color of +word+ on the newest main-window row showing
      # +line+: a color code, nil when uncolored, or an Array when mixed.
      def color_on_screen(line, word)
        y = main.rows.rindex { |row| row.include?(line) }
        x = main.row(y).index(word)
        colors = (x...(x + word.length)).map { |col| pairs.key(main.attrs_at(y, col) >> 8) }.uniq
        colors.size == 1 ? colors.first : colors
      end

      it 'keeps coloring text with it after a reload' do
        app.execute_command('.highlight goblin')
        File.write(settings_path, settings.sub('goblin', 'troll'))

        app.execute_command('.reload')
        receive_from_server('A goblin attacks a troll.')

        expect(color_on_screen('A goblin attacks a troll.', 'goblin')).to eq inline
        expect(color_on_screen('A goblin attacks a troll.', 'troll')).to eq 'ff0000'
      end

      it 'still lists it after a reload' do
        app.execute_command('.highlight goblin')
        app.execute_command('.reload')

        app.execute_command('.highlight')

        expect(main.rows.last(3)).to eq ['*', '*   goblin', '*']
      end

      it 'removes it with .unhighlight after a reload' do
        app.execute_command('.highlight goblin')
        File.write(settings_path, settings.sub('goblin', 'troll'))
        app.execute_command('.reload')
        receive_from_server('A goblin arrives.')
        expect(color_on_screen('A goblin arrives.', 'goblin')).to eq inline

        app.execute_command('.unhighlight goblin')
        receive_from_server('A goblin attacks a troll.')

        expect(main.rows).to include('* Highlight removed: goblin')
        expect(color_on_screen('A goblin attacks a troll.', 'goblin')).to be_nil
        expect(color_on_screen('A goblin attacks a troll.', 'troll')).to eq 'ff0000'
      end

      it 'colors a word the file also highlights the same after a reload as before it' do
        app.execute_command('.highlight goblin')
        receive_from_server('A goblin arrives.')
        before_reload = color_on_screen('A goblin arrives.', 'goblin')

        app.execute_command('.reload')
        receive_from_server('A goblin arrives.')

        expect(color_on_screen('A goblin arrives.', 'goblin')).to eq before_reload
        expect(HIGHLIGHT.to_a).to eq [[/goblin/, ['ff0000', nil, nil]], [/goblin/i, [inline, nil, nil]]]
      end

      # The server thread reads HIGHLIGHT under SETTINGS_LOCK, so it can only
      # see HIGHLIGHT as it is whenever the lock is released.
      it 'is in the highlights every time the reload releases the settings lock' do
        app.execute_command('.highlight goblin')
        File.write(settings_path, settings.sub('goblin', 'troll'))
        seen = []
        allow(SETTINGS_LOCK).to receive(:synchronize).and_wrap_original do |original, &block|
          original.call(&block).tap { seen << HIGHLIGHT.keys }
        end

        app.execute_command('.reload')

        expect(seen).not_to be_empty
        expect(seen).to all(include(/goblin/i))
        expect(seen.last).to eq [/troll/, /goblin/i]
      end

      it 'is unchanged by a reload that fails' do
        app.execute_command('.highlight goblin')
        File.write(settings_path, settings.sub('goblin</highlight>', 'troll</hilight>'))

        app.execute_command('.reload')
        receive_from_server('A goblin arrives.')

        expect(HIGHLIGHT.to_a).to eq [[/goblin/, ['ff0000', nil, nil]], [/goblin/i, [inline, nil, nil]]]
      end
    end
  end

  # BUG FOUND (fixed here): ncurses reports a terminal resize as KEY_RESIZE,
  # but only a settings file binding the resize key re-fitted the layout.
  # default.xml doesn't bind it, so the windows kept their old size until
  # the user typed .resize.
  describe 'terminal resize' do
    let(:settings_path) { File.join(@dir, 'settings.xml') }
    let(:settings) { File.read(File.expand_path('../../templates/default.xml', __dir__)) }
    let(:main) { TabbedTextWindow.list.first }
    let(:terminal) { { lines: 60, cols: 200 } }

    around do |example|
      Dir.mktmpdir { |dir| @dir = dir; example.run }
    end

    before do
      allow(ProfanityLog).to receive(:write)
      allow(Curses).to receive(:lines) { terminal[:lines] }
      allow(Curses).to receive(:cols) { terminal[:cols] }
      File.write(settings_path, settings)
      app.send(:load_settings_and_layout)
    end

    # Shrink the terminal and deliver the key ncurses sends for it.
    def resize_terminal
      terminal.merge!(lines: 40, cols: 150)
      app.send(:handle_key, Curses::KEY_RESIZE, nil)
    end

    it 'fits the layout to the new size when the settings file does not bind the resize key' do
      expect([main.maxy, main.maxx]).to eq [58, 131]

      resize_terminal

      expect([main.maxy, main.maxx]).to eq [38, 99]
    end

    it 'still fits the layout after a .reload' do
      app.execute_command('.reload')

      resize_terminal

      expect([main.maxy, main.maxx]).to eq [38, 99]
    end

    it 'fits the layout while a key combo is pending, and keeps the combo' do
      # A lone Escape starts the alt+N combos and stays pending until the next key.
      escape_combo = app.send(:handle_key, 27, nil)
      expect(escape_combo).to be_a(Hash)
      terminal.merge!(lines: 40, cols: 150)

      expect(app.send(:handle_key, Curses::KEY_RESIZE, escape_combo)).to be(escape_combo)
      expect([main.maxy, main.maxx]).to eq [38, 99]
    end

    context 'when the settings file binds the resize key' do
      let(:settings) { super().sub('</settings>', "<key id='resize' macro='look\\r'/></settings>") }
      let(:server) { StringIO.new }

      before { app.instance_variable_set(:@server, server) }

      it 'runs that binding instead' do
        resize_terminal

        expect(server.string).to eq "look\n"
        expect([main.maxy, main.maxx]).to eq [58, 131]
      end
    end
  end

  # .scrollcfg learns each wheel direction from the first mouse event seen
  # 20 times. Pointer motion and left clicks arrive in the same stream while
  # the user reaches for the wheel, and they are never the wheel.
  describe '.scrollcfg' do
    # The real MouseScroll, with no saved wheel buttons
    let(:app) do
      allow(MouseScroll).to receive(:new).and_call_original
      allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
      new_app
    end
    # The window the wheel scrolls; calibration messages go to main below it
    let(:window) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='3' width='12' value='thoughts'/>
          <window class='text' top='3' left='0' height='3' width='60' value='main'/>
        </layout>
      XML
      app.window_mgr.load_layout('test')
      app.window_mgr.stream['thoughts']
    end
    let(:saved_masks) { [] }

    before do
      stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
      allow(ProfanitySettings).to receive(:save_mouse_settings) { |up, down| saved_masks << [up, down] }
      %w[l1 l2 l3 l4 l5].each { |line| window.add_string(line) }
      window.scroll_lines(-1)
    end

    def mouse_event(bstate, times: 1)
      allow(Curses).to receive(:getmouse).and_return(Struct.new(:bstate, :y, :x).new(bstate, 1, 2))
      times.times { app.send(:handle_key, Curses::KEY_MOUSE, nil) }
    end

    def left_clicks(times)
      times.times do
        mouse_event(Curses::BUTTON1_PRESSED)
        mouse_event(Curses::BUTTON1_RELEASED)
      end
    end

    it 'learns the wheel past pointer motion and left clicks, so a left click does not scroll' do
      stub_const('MouseScroll::WHEEL_DOWN_IS_MOTION', false)
      wheel_up = 0x10000
      wheel_down = 0x200000
      app.execute_command('.scrollcfg')
      mouse_event(Curses::REPORT_MOUSE_POSITION, times: 20)
      left_clicks(20)
      mouse_event(wheel_up, times: 20)
      mouse_event(Curses::REPORT_MOUSE_POSITION, times: 20)
      left_clicks(20)
      mouse_event(wheel_down, times: 20)

      left_clicks(1)
      expect(window.rows).to eq %w[l2 l3 l4]

      mouse_event(wheel_up)
      expect(window.rows).to eq %w[l1 l2 l3]
      expect(saved_masks).to eq [[wheel_up, wheel_down]]
    end

    it 'learns a wheel-down that ncurses reports as pointer motion' do
      stub_const('MouseScroll::WHEEL_DOWN_IS_MOTION', true)
      wheel_up = 0x80000
      app.execute_command('.scrollcfg')
      mouse_event(Curses::REPORT_MOUSE_POSITION, times: 20)
      mouse_event(wheel_up, times: 20)
      mouse_event(Curses::REPORT_MOUSE_POSITION, times: 20)

      expect(saved_masks).to eq [[wheel_up, Curses::REPORT_MOUSE_POSITION]]
    end

    # Every event of the middle (2) and right (3) buttons.
    def middle_and_right_clicks(times)
      events = %w[2 3].flat_map do |button|
        %w[PRESSED RELEASED CLICKED DOUBLE_CLICKED TRIPLE_CLICKED].map { |event| Curses.const_get("BUTTON#{button}_#{event}") }
      end
      times.times { events.each { |bstate| mouse_event(bstate) } }
    end

    { 'a wheel button' => [false, 0x200000], 'pointer motion' => [true, Curses::REPORT_MOUSE_POSITION] }
      .each do |reported_as, (wheel_down_is_motion, wheel_down)|
      it "learns the wheel past middle and right clicks, so they do not scroll (wheel-down as #{reported_as})" do
        stub_const('MouseScroll::WHEEL_DOWN_IS_MOTION', wheel_down_is_motion)
        wheel_up = 0x10000
        app.execute_command('.scrollcfg')
        middle_and_right_clicks(20)
        mouse_event(wheel_up, times: 20)
        middle_and_right_clicks(20)
        mouse_event(wheel_down, times: 20)

        middle_and_right_clicks(1)
        expect(window.rows).to eq %w[l2 l3 l4]
        expect(saved_masks).to eq [[wheel_up, wheel_down]]
      end
    end
  end

  describe 'input loop' do
    # A command window whose get_char returns the given keys, then raises
    # Interrupt (Ctrl+C) to end the loop.
    def keyboard(*keys)
      window = Object.new
      window.define_singleton_method(:nodelay=) { |_| nil }
      window.define_singleton_method(:get_char) { keys.empty? ? raise(Interrupt) : keys.shift }
      window
    end

    it 'keeps handling keys after a key action raises' do
      handled = []
      app.key_binding[1] = proc { raise 'broken key action' }
      app.key_binding[2] = proc { handled << :second_key }
      # get_char returns ctrl+a and ctrl+b as one-character Strings
      app.cmd_buffer.window = keyboard("\x01", "\x02")
      allow(IO).to receive(:select).and_return(nil)
      allow(ProfanityLog).to receive(:write)

      app.send(:input_loop)

      expect(handled).to eq [:second_key]
      expect(ProfanityLog).to have_received(:write).with('main', a_string_including('broken key action'), backtrace: anything)
    end

    # Alt+1 arrives as ESC followed by "1"; get_char returns both as
    # Strings, and the settings file binds it as [27, '1'].
    it 'fires the alt+1 binding from the settings file when ESC then the digit arrive' do
      switched = []
      app.key_action['switch_tab_1'] = proc { switched << 1 }
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'settings.xml')
        File.write(path, "<settings><key id='alt+1' action='switch_tab_1'/></settings>")
        SettingsLoader.load(path, app.key_binding, app.key_action, proc {})
      end
      app.cmd_buffer.window = keyboard("\e", '1')
      allow(IO).to receive(:select).and_return(nil)

      app.send(:input_loop)

      expect(switched).to eq [1]
    end
  end

  # BUG FOUND (fixed here): the input loop read keys with getch, which
  # returns a non-ASCII character's UTF-8 bytes one Integer at a time, and
  # only Strings are typed into the command line, so "café" became "caf".
  describe 'typing non-ASCII characters' do
    let(:backspace) { 0x107 } # ncurses KEY_BACKSPACE; spec_helper's Curses stub lacks it

    let(:screen) { ScreenLineWindow.new(30) }
    let(:server) { StringIO.new }

    # Make the command line window also act as the keyboard: the user types
    # +keys+ (text, or Integer function-key codes), and each read returns what
    # curses returns for it. getch returns printable ASCII as a String and any
    # other byte, including each byte of a UTF-8 character, as an Integer;
    # get_char returns a whole character as a String and a function key as
    # its Integer code. Ctrl+C (Interrupt) ends the loop when keys run out.
    def type(*keys)
      chars = keys.flat_map { |k| k.is_a?(String) ? k.chars : [k] }
      bytes = []
      screen.define_singleton_method(:nodelay=) { |_| nil }
      screen.define_singleton_method(:timeout=) { |_| nil }
      screen.define_singleton_method(:get_char) { chars.empty? ? raise(Interrupt) : chars.shift }
      screen.define_singleton_method(:getch) do
        if bytes.empty?
          raise Interrupt if chars.empty?

          key = chars.shift
          next key if key.is_a?(Integer) || key.match?(/\A[ -~]\z/)

          bytes.concat(key.bytes)
        end
        bytes.shift
      end
      allow(IO).to receive(:select).and_return(nil)
      app.send(:input_loop)
    end

    before do
      app.cmd_buffer.window = screen
      app.instance_variable_set(:@server, server)
      app.key_binding[10] = app.key_action['send_command']
      app.key_binding[Curses::KEY_LEFT] = app.key_action['cursor_left']
      app.key_binding[backspace] = app.key_action['cursor_backspace']
      app.key_binding[21] = app.key_action['cursor_kill_line'] # ctrl+u
      app.key_binding[25] = app.key_action['cursor_yank'] # ctrl+y
    end

    it 'shows each typed character on the command line, with the cursor after it' do
      type('café')
      expect(screen.visible).to eq 'café'
      expect(screen.curx).to eq 4
    end

    it 'sends the typed text to the server' do
      type("café au lait\n")
      expect(server.string).to eq "café au lait\n"
    end

    it 'backspaces over a non-ASCII character as one character' do
      type('café', backspace, "e\n")
      expect(server.string).to eq "cafe\n"
    end

    it 'moves the cursor over a non-ASCII character as one character' do
      type('naïve', Curses::KEY_LEFT, Curses::KEY_LEFT, backspace, 'i')
      expect(screen.visible).to eq 'naive'
      expect(screen.curx).to eq 3
    end

    it 'kills and yanks text with non-ASCII characters' do
      type("ñoño\x15", "say \x19\n")
      expect(server.string).to eq "say ñoño\n"
    end

    it 'reports a non-ASCII key as the character typed for .key' do
      type(".key\n", 'é')
      expect(main_window.calls.map { |c| c[:text] }).to include('* Detected keycode: é')
    end

    it 'drops a key the locale cannot decode and keeps reading' do
      # Under the C locale, get_char raises RangeError for a non-ASCII key.
      reads = [-> { raise RangeError, 'invalid codepoint 0xC3 in US-ASCII' }, -> { 'a' }]
      screen.define_singleton_method(:nodelay=) { |_| nil }
      screen.define_singleton_method(:get_char) { reads.empty? ? raise(Interrupt) : reads.shift.call }
      allow(IO).to receive(:select).and_return(nil)

      app.send(:input_loop)

      expect(screen.visible).to eq 'a'
    end
  end

  describe 'prompt width changes' do
    # The prompt indicator grows from 1 to 11 columns, so WindowManager's
    # :prompt_changed handler shrinks the 20-column command window to 10.
    let(:prompt_window) do
      obj = Object.new
      def obj.layout = WindowLayout.new(height: '1', width: '1', top: '23', left: '0')
      def obj.resize(*) = nil
      def obj.label=(_text); end
      obj
    end
    let(:screen) { ScreenLineWindow.new(20) }

    before do
      stub_const('GameTextProcessor', Class.new { def initialize(**) = nil })
      allow(Thread).to receive(:new)
      app.window_mgr.instance_variable_set(:@indicator, { 'prompt' => prompt_window })
      app.window_mgr.install_command_window(WindowLayout.new(height: '1', width: '20', top: '23', left: '1')) { screen }
      app.cmd_buffer.window = screen
      'abcdefghijklmnopqr'.each_char { |ch| app.cmd_buffer.put_ch(ch) }
      app.send(:start_server_thread)
    end

    it 'refits the command line to the resized command window' do
      app.instance_variable_get(:@event_bus).emit(:prompt_changed, text: 'H 100 [RT]>')
      expect(screen.maxx).to eq 10
      expect(screen.errors).to be_empty
      expect(screen.line).to eq 'jklmnopqr '
      expect(screen.curx).to eq 9
    end
  end

  # Run a block with $stderr captured; returns what was written.
  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  # BUG FOUND (fixed here): a settings file that failed to parse on startup
  # showed only "No layouts found ... may be malformed"; why it failed (an
  # empty file, or where the XML broke) was only in the log.
  describe 'loading the settings file at startup' do
    let(:settings_path) { File.join(@dir, 'settings.xml') }

    around do |example|
      Dir.mktmpdir { |dir| @dir = dir; example.run }
    end

    before do
      allow(ProfanityLog).to receive(:write)
      allow(Curses).to receive(:close_screen)
    end

    # Start up with the given settings file content.
    #
    # @return [Array(String, Integer)] what was printed, and the exit status
    def start_with_settings(content)
      File.write(settings_path, content)
      status = nil
      output = capture_stderr do
        app.send(:load_settings_and_layout)
      rescue SystemExit => e
        status = e.status
      end
      [output, status]
    end

    it 'says the file is empty when it is' do
      output, status = start_with_settings('')

      expect(status).to eq 1
      expect(output.lines.map(&:chomp)).to eq ["ERROR: Could not load settings from #{settings_path}.",
                                               "Settings file is empty: #{settings_path}"]
    end

    it 'says where the XML broke when it is malformed' do
      output, status = start_with_settings("<settings>\n  <layout id='default'>\n  </layuot>\n</settings>\n")

      expect(status).to eq 1
      expect(output.lines.map(&:chomp)).to eq ["ERROR: Could not load settings from #{settings_path}.",
                                               "Missing end tag for 'layout' (got 'layuot') (line 3)"]
    end

    it 'still says no layouts were found when a well-formed file has none' do
      output, status = start_with_settings("<settings><preset id='speech' fg='00ff00'/></settings>\n")

      expect(status).to eq 1
      expect(output).to start_with("ERROR: No layouts found in #{settings_path}.")
    end
  end

  describe 'connecting to the game server' do
    let(:host) { '192.0.2.10' }
    let(:stderr_at_close) { [] }

    before do
      allow(Curses).to receive(:close_screen) { stderr_at_close << $stderr.string.dup }
    end

    # Make every way of opening the socket fail with the given error.
    def fail_connection_with(error)
      allow(Socket).to receive(:tcp).and_raise(error)
      allow(TCPSocket).to receive(:open).and_raise(error)
    end

    it 'connects with a timeout so an unreachable host cannot hang' do
      server = StringIO.new
      expect(Socket).to receive(:tcp)
        .with('192.0.2.10', 8000, connect_timeout: Application::CONNECT_TIMEOUT).and_return(server)

      app.send(:connect_server)

      expect(server.string).to start_with('SET_FRONTEND_PID ')
    end

    [
      Errno::EHOSTUNREACH, Errno::ETIMEDOUT, Errno::ENETUNREACH, Errno::EADDRNOTAVAIL,
      Errno::ECONNREFUSED, SocketError.new('getaddrinfo: nodename nor servname provided')
    ].each do |error|
      it "reports #{error.is_a?(Exception) ? error.class : error} with host and port, and exits 1" do
        fail_connection_with(error)
        exit_error = nil

        output = capture_stderr do
          app.send(:connect_server)
        rescue SystemExit => e
          exit_error = e
        end

        expect(exit_error&.status).to eq 1
        expect(output).to include('Failed to connect to game server at 192.0.2.10:8000')
      end
    end

    # BUG FOUND (fixed here): fatal errors were printed with Kernel#warn,
    # which prints nothing when warnings are off (ruby -W0, $VERBOSE nil),
    # so the client exited 1 without saying why.
    it 'still reports the failure with warnings turned off (ruby -W0)' do
      fail_connection_with(Errno::ECONNREFUSED)
      verbose = $VERBOSE
      $VERBOSE = nil

      output = capture_stderr do
        app.send(:connect_server)
      rescue SystemExit
        nil
      ensure
        $VERBOSE = verbose
      end

      expect(output.lines.map(&:chomp)).to eq [
        'Failed to connect to game server at 192.0.2.10:8000: Connection refused',
        'Is the game server running?'
      ]
    end

    it 'closes the curses screen before printing, so the error is not wiped with it' do
      fail_connection_with(Errno::ECONNREFUSED)

      output = capture_stderr do
        app.send(:connect_server)
      rescue SystemExit
        nil
      end

      expect(stderr_at_close).to eq ['']
      expect(output).to include('Connection refused')
    end
  end

  # Application used to read SETTINGS_FILENAME, HOST and PORT, constants only
  # profanity.rb defined, so lib/application.rb couldn't be used without the
  # entry script. It now uses the values it is constructed with.
  describe 'the settings file, host and port it is given' do
    let(:settings_path) { File.join(@dir, 'given.xml') }

    around do |example|
      Dir.mktmpdir { |dir| @dir = dir; example.run }
    end

    before do
      allow(ProfanityLog).to receive(:write)
      allow(Curses).to receive(:close_screen)
    end

    # A settings file with one highlight and a layout with a command window.
    def settings_highlighting(word)
      <<~XML
        <settings>
          <highlight fg='ff0000'>#{word}</highlight>
          <layout id='default'>
            <window class='text' value='main' top='0' left='0' height='5' width='60'/>
            <window class='command' top='5' left='0' height='1' width='60'/>
          </layout>
        </settings>
      XML
    end

    it 'loads that settings file at startup and again on .reload' do
      File.write(settings_path, settings_highlighting('goblin'))
      app.send(:load_settings_and_layout)
      expect(HIGHLIGHT.keys).to eq [/goblin/]

      File.write(settings_path, settings_highlighting('troll'))
      app.execute_command('.reload')

      expect(HIGHLIGHT.keys).to eq [/troll/]
    end

    it 'names that settings file when it has no layout' do
      File.write(settings_path, '<settings/>')

      output = capture_stderr do
        app.send(:load_settings_and_layout)
      rescue SystemExit
        nil
      end

      expect(output).to start_with("ERROR: No layouts found in #{settings_path}.\n")
    end

    context 'with a game server listening on an ephemeral port' do
      let(:listener) { TCPServer.new('127.0.0.1', 0) }
      let(:port) { listener.addr[1] }

      after do
        app.instance_variable_get(:@server)&.close
        listener.close
      end

      it 'connects to that host and port' do
        app.send(:connect_server)
        client = listener.accept

        expect(client.gets).to eq "SET_FRONTEND_PID #{Process.pid}\n"
      ensure
        client&.close
      end
    end

    context 'with nothing listening on the port' do
      # A port that was free a moment ago: bind, note it, and close.
      let(:port) { TCPServer.open('127.0.0.1', 0).then { |server| server.addr[1].tap { server.close } } }

      it 'names that host and port in the error and exits 1' do
        status = nil

        output = capture_stderr do
          app.send(:connect_server)
        rescue SystemExit => e
          status = e.status
        end

        expect(status).to eq 1
        expect(output).to start_with("Failed to connect to game server at 127.0.0.1:#{port}: ")
      end
    end
  end

  # The server thread reports how the connection ended; the input loop ends
  # the session on the main thread.
  describe 'end of session' do
    let(:screen) { [] }
    let(:main_thread_window) do
      screen = self.screen
      obj = Object.new
      obj.define_singleton_method(:add_string) { |text, *| screen << [Thread.current, text] }
      obj
    end

    before do
      app.window_mgr.instance_variable_set(:@stream, { 'main' => main_thread_window })
      allow(IO).to receive(:select) { sleep 0.005 }
      allow(ProfanityLog).to receive(:write)
      allow(Curses).to receive(:close_screen)
    end

    # A game server whose gets raises the error, or returns nil (EOF) when
    # the error is nil.
    def server_that_ends_with(error)
      server = Object.new
      server.define_singleton_method(:gets) { error ? raise(error) : nil }
      server.define_singleton_method(:close) { nil }
      server
    end

    # A command window that returns no key while polled (nodelay) and
    # +key+ once read blocking. Ends the loop with Interrupt if the session
    # has not ended after 5 seconds.
    def keyboard_with_key(key, screen)
      window = Object.new
      blocking = false
      deadline = Time.now + 5
      window.define_singleton_method(:nodelay=) { |value| blocking = !value }
      window.define_singleton_method(:noutrefresh) { nil }
      window.define_singleton_method(:getch) do
        raise Interrupt if Time.now > deadline

        screen << [Thread.current, blocking ? :blocking_getch : :polling_getch]
        blocking ? key : nil
      end
      window
    end

    # Run the server thread and the input loop until the session ends.
    # Returns the SystemExit raised, or nil if the loop ended without one.
    def run_session(server)
      app.cmd_buffer.window = keyboard_with_key('q', screen)
      app.instance_variable_set(:@server, server)
      app.send(:start_server_thread)
      app.send(:input_loop)
      nil
    rescue SystemExit => e
      e
    end

    def blocking_reads = screen.select { |_, event| event == :blocking_getch }

    [nil, IOError.new('stream closed'), Errno::ECONNRESET.new, Errno::EPIPE.new, Errno::ECONNABORTED.new].each do |error|
      it "on #{error ? error.class : 'EOF'}, shows the notice, waits for a key on the main thread, and exits 0" do
        exit_error = run_session(server_that_ends_with(error))

        expect(exit_error&.status).to eq 0
        texts = screen.map(&:last)
        expect(texts).to include('* Connection closed', '* Press any key to exit...')
        expect(texts.index(:blocking_getch)).to be > texts.index('* Press any key to exit...')
        expect(screen.map(&:first).uniq).to eq [Thread.current]
      end
    end

    it 'waits past terminal resizes and mouse events for a real key' do
      keys = [Curses::KEY_RESIZE, Curses::KEY_MOUSE, 'q', 'not read']
      nodelay = []
      window = Object.new
      window.define_singleton_method(:nodelay=) { |value| nodelay << value }
      window.define_singleton_method(:getch) { keys.shift }
      app.cmd_buffer.window = window

      app.send(:wait_for_exit_key)

      expect(nodelay).to eq [false]
      expect(keys).to eq ['not read']
    end

    it 'exits 1 without the disconnect notice when the server thread crashes' do
      exit_error = nil
      output = capture_stderr { exit_error = run_session(server_that_ends_with(RuntimeError.new('boom'))) }

      expect(exit_error&.status).to eq 1
      expect(screen.map(&:last)).not_to include('* Connection closed')
      expect(blocking_reads).to be_empty
      expect(output).to include('error reading from the game server')
    end
  end
end
