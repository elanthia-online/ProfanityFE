# frozen_string_literal: true

# Tests Application's initialization, dot-command dispatch (.quit, .help,
# .links, .arrow, .layout), macro engine (\\r, \\x, @), key action
# bindings, and countdown tick polling.

require_relative '../../lib/shared_state'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../../lib/window_manager'
require_relative '../../lib/mouse_scroll'
require_relative '../../lib/autocomplete'
require_relative '../../lib/application'

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

  let(:app) { described_class.new(cli_options) }

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
      app_with_links = described_class.new(cli_options.merge(links: true))
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

  # ---- Feedback colors ----

  describe 'feedback_colors' do
    it 'returns a color region spanning the full text' do
      colors = app.send(:feedback_colors, 'hello')
      expect(colors).to eq [{ start: 0, end: 5, fg: FEEDBACK_COLOR, bg: nil, ul: nil }]
    end

    it 'handles empty string' do
      colors = app.send(:feedback_colors, '')
      expect(colors.first[:end]).to eq 0
    end
  end

  # ---- Adversarial: initialization edge cases ----

  describe 'adversarial initialization' do
    it 'handles nil char_name' do
      app_nil = described_class.new(cli_options.merge(char: nil))
      expect(app_nil.shared_state.char_name).to eq 'ProfanityFE'
    end

    it 'capitalizes char_name' do
      app_char = described_class.new(cli_options.merge(char: 'mahtra'))
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

      def obj.update
        updates << Time.now
        updates.length <= 3 # return true for first 3 calls
      end
      obj
    end

    before do
      app.window_mgr.instance_variable_set(:@countdown, { 'roundtime' => countdown_window })
      app.cmd_buffer.window = Curses::Window.new(1, 80, 0, 0)
    end

    it 'calls update on all countdown windows' do
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

    it 'handles multiple countdown windows' do
      stun_window = Object.new
      def stun_window.update = true
      app.window_mgr.instance_variable_set(:@countdown, {
        'roundtime' => countdown_window,
        'stunned'   => stun_window,
      })
      expect(app.send(:tick_countdowns)).to be true
      expect(countdown_window.updates.length).to eq 1
    end

    it 'returns false when all countdowns return false (no change)' do
      no_change = Object.new
      def no_change.update = false
      app.window_mgr.instance_variable_set(:@countdown, { 'roundtime' => no_change })
      expect(app.send(:tick_countdowns)).to be false
    end

    it 'does not call noutrefresh when nothing changed' do
      no_change = Object.new
      def no_change.update = false
      app.window_mgr.instance_variable_set(:@countdown, { 'roundtime' => no_change })
      app.cmd_buffer.window.call_log.clear
      app.send(:tick_countdowns)
      expect(app.cmd_buffer.window.call_log.map(&:first)).not_to include(:noutrefresh)
    end
  end
end
