# frozen_string_literal: true

# Tests the named key actions as the user sees them: first built on their
# own from a CommandBuffer and a WindowManager layout on the virtual screen,
# then bound from a settings file and pressed through Application#handle_key.

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
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../../lib/key_action_registry'
require_relative '../../lib/application'

RSpec.describe KeyActionRegistry do
  # Text wraps at 10 columns in main and thoughts (the builder keeps a
  # scrollbar column) and at 20 in the tabbed window.
  let(:layout) do
    <<~XML
      <layout>
        <window class='text' top='0' left='0' height='3' width='12' value='main'/>
        <window class='text' top='0' left='20' height='3' width='12' value='thoughts'/>
        <window class='tabbed' top='4' left='0' height='3' width='22' tabs='chat,lnet,logons'/>
        <window class='command' top='8' left='0' height='1' width='30'/>
      </layout>
    XML
  end

  describe 'built on its own' do
    let(:window_mgr) { WindowManager.new }
    let(:cmd_buffer) { CommandBuffer.new }
    let(:key_binding) { {} }
    let(:calls) { [] }
    let(:registry) do
      calls = self.calls
      described_class.new(cmd_buffer: cmd_buffer, window_mgr: window_mgr, key_binding: key_binding,
                          send_command: -> { calls << [:send_command, cmd_buffer.text.dup] },
                          send_history_command: ->(index) { calls << [:send_history_command, index] })
    end
    let(:actions) { registry.actions }
    let(:main) { window_mgr.stream['main'] }
    let(:thoughts) { window_mgr.stream['thoughts'] }
    let(:tabbed) { window_mgr.stream['chat'] }
    let(:command_line) { cmd_buffer.window }

    before do
      LAYOUT['keys'] = REXML::Document.new(layout).root
      window_mgr.load_layout('keys')
      cmd_buffer.window = window_mgr.command_window
    end

    def press(name) = actions.fetch(name).call
    def type(text) = text.each_char { |ch| cmd_buffer.put_ch(ch) }
    def shown = command_line.rows.first.rstrip

    it 'offers every action a settings file can name, switch_tab and switch_tab_reverse as aliases' do
      expect(actions.keys).to eq %w[
        resize cursor_left cursor_right cursor_word_left cursor_word_right cursor_home cursor_end
        cursor_backspace cursor_delete cursor_backspace_word cursor_delete_word cursor_kill_forward
        cursor_kill_line cursor_yank switch_current_window next_tab switch_tab prev_tab switch_tab_reverse
        switch_tab_1 switch_tab_2 switch_tab_3 switch_tab_4 switch_tab_5
        scroll_current_window_up_one scroll_current_window_down_one scroll_current_window_up_page
        scroll_current_window_down_page scroll_current_window_bottom previous_command next_command
        switch_arrow_mode send_command send_last_command send_second_last_command autocomplete
      ]
      expect(actions.values).to all(be_a(Proc))
      expect(actions['switch_tab']).to equal actions['next_tab']
      expect(actions['switch_tab_reverse']).to equal actions['prev_tab']
    end

    describe 'editing the command line' do
      before { type('look at goblin') }

      it 'moves the cursor by character, word and line' do
        press('cursor_word_left')
        expect(command_line.curx).to eq 8
        press('cursor_left')
        expect(command_line.curx).to eq 7
        press('cursor_home')
        expect(command_line.curx).to eq 0
        press('cursor_word_right')
        expect(command_line.curx).to eq 5
        press('cursor_right')
        expect(command_line.curx).to eq 6
        press('cursor_end')
        expect(command_line.curx).to eq 14
        expect(shown).to eq 'look at goblin'
      end

      it 'deletes by character and word on both sides of the cursor' do
        press('cursor_backspace')
        expect(shown).to eq 'look at gobli'
        press('cursor_backspace_word')
        expect([shown, command_line.curx]).to eq ['look at', 8]
        press('cursor_home')
        press('cursor_delete')
        expect(shown).to eq 'ook at'
        press('cursor_delete_word')
        expect(shown).to eq ' at'
      end

      it 'kills to the end or the whole line and yanks the text back' do
        press('cursor_word_left')
        press('cursor_kill_forward')
        expect(shown).to eq 'look at'
        press('cursor_home')
        press('cursor_kill_line')
        expect(shown).to eq ''
        press('cursor_yank')
        expect(shown).to eq 'look at'
      end

      it 'flushes the screen after every edit, including one that changes nothing' do
        edits = %w[cursor_left cursor_right cursor_word_left cursor_word_right cursor_home cursor_end
                   cursor_backspace cursor_delete cursor_backspace_word cursor_delete_word
                   cursor_kill_forward cursor_kill_line cursor_yank previous_command next_command]
        flushes = 0
        allow(CursesRenderer).to receive(:doupdate) { flushes += 1 }

        edits.each { |name| press(name) }
        press('cursor_kill_line')
        press('cursor_backspace_word')

        expect(flushes).to eq edits.size + 2
      end
    end

    describe 'history' do
      before { %w[north south].each { |cmd| cmd_buffer.add_to_history(cmd) } }

      it 'recalls earlier commands with previous_command and later ones with next_command' do
        press('previous_command')
        expect(shown).to eq 'south'
        press('previous_command')
        expect(shown).to eq 'north'
        press('next_command')
        expect(shown).to eq 'south'
      end

      it 'completes the command line from the history' do
        cmd_buffer.add_to_history('sneak')
        type('so')

        press('autocomplete')

        expect(shown).to eq 'south'
      end
    end

    describe 'scrolling' do
      before { %w[l1 l2 l3 l4 l5 l6 l7].each { |line| main.add_string(line) } }

      it 'scrolls the current window by one line and by a page less one line' do
        press('scroll_current_window_up_one')
        expect(main.rows).to eq %w[l4 l5 l6]
        press('scroll_current_window_up_page')
        expect(main.rows).to eq %w[l2 l3 l4]
        press('scroll_current_window_down_page')
        expect(main.rows).to eq %w[l4 l5 l6]
        press('scroll_current_window_down_one')
        expect(main.rows).to eq %w[l5 l6 l7]
      end

      it 'returns to the newest lines with scroll_current_window_bottom' do
        3.times { press('scroll_current_window_up_one') }

        press('scroll_current_window_bottom')

        expect(main.rows).to eq %w[l5 l6 l7]
      end

      it 'scrolls the next window after switch_current_window' do
        %w[t1 t2 t3 t4].each { |line| thoughts.add_string(line) }

        press('switch_current_window')
        press('scroll_current_window_up_one')

        expect(thoughts.rows).to eq %w[t1 t2 t3]
        expect(main.rows).to eq %w[l5 l6 l7]
      end

      it 'scrolls the window the layout has now, not the one it had when the actions were built' do
        actions
        LAYOUT['other'] = REXML::Document.new(<<~XML).root
          <layout><window class='text' top='0' left='0' height='2' width='12' value='arrivals'/></layout>
        XML
        window_mgr.load_layout('other')
        arrivals = window_mgr.stream['arrivals']
        %w[n1 n2 n3].each { |line| arrivals.add_string(line) }

        press('scroll_current_window_up_one')

        expect(arrivals.rows).to eq %w[n1 n2]
      end
    end

    describe 'tabs' do
      before do
        %w[chat lnet logons].each { |tab| tabbed.add_string_to_tab(tab, "#{tab} text") }
      end

      def active = tabbed.active_tab

      it 'cycles forward and backward through the tabs, wrapping at the ends' do
        expect(active).to eq 'chat'
        press('next_tab')
        expect(active).to eq 'lnet'
        expect(tabbed.rows).to include('lnet text')
        press('switch_tab_reverse')
        press('prev_tab')
        expect(active).to eq 'logons'
        press('switch_tab')
        expect(active).to eq 'chat'
      end

      it 'selects a tab by number and ignores a number past the last tab' do
        press('switch_tab_3')
        expect(active).to eq 'logons'
        expect(tabbed.rows).to include('logons text')
        press('switch_tab_4')
        expect(active).to eq 'logons'
      end
    end

    describe 'switch_arrow_mode' do
      it 'cycles the arrows from history to page scroll to line scroll and back' do
        key_binding[Curses::KEY_UP] = actions['previous_command']
        modes = Array.new(3) do
          press('switch_arrow_mode')
          [key_binding[Curses::KEY_UP], key_binding[Curses::KEY_DOWN]]
        end

        expect(modes).to eq [
          [actions['scroll_current_window_up_page'], actions['scroll_current_window_down_page']],
          [actions['scroll_current_window_up_one'], actions['scroll_current_window_down_one']],
          [actions['previous_command'], actions['next_command']]
        ]
      end

      it 'starts with history recall when the up arrow is unbound' do
        press('switch_arrow_mode')

        expect(key_binding).to eq(Curses::KEY_UP => actions['previous_command'], Curses::KEY_DOWN => actions['next_command'])
      end
    end

    it 'sends through the callbacks it was given: the line, and history entries 1 and 2' do
      type('wave')

      press('send_command')
      press('send_last_command')
      press('send_second_last_command')

      expect(calls).to eq [[:send_command, 'wave'], [:send_history_command, 1], [:send_history_command, 2]]
    end

    it 'refits the layout and the command line to the terminal on resize' do
      terminal = { lines: 40, cols: 150 }
      allow(Curses).to receive(:lines) { terminal[:lines] }
      allow(Curses).to receive(:cols) { terminal[:cols] }
      LAYOUT['sized'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='lines-2' width='cols' value='main'/>
          <window class='command' top='lines-1' left='0' height='1' width='cols'/>
        </layout>
      XML
      window_mgr.load_layout('sized')
      cmd_buffer.window = window_mgr.command_window
      terminal.merge!(lines: 20, cols: 60)

      press('resize')

      expect([window_mgr.stream['main'].maxy, command_line.maxx, command_line.begy]).to eq [18, 60, 19]
    end
  end

  describe 'bound from a settings file and pressed through Application#handle_key' do
    let(:dir) { Dir.mktmpdir }
    let(:settings_path) { File.join(dir, 'settings.xml') }
    let(:server) { StringIO.new }
    let(:app) do
      allow(MouseScroll).to receive(:new).and_return(instance_double(MouseScroll, enable_click_events: nil))
      Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                      settings_file: settings_path, host: '127.0.0.1', port: 8000)
    end
    let(:main) { app.window_mgr.stream['main'] }
    let(:tabbed) { app.window_mgr.stream['chat'] }
    let(:command_line) { app.cmd_buffer.window }

    before do
      allow(ProfanityLog).to receive(:write)
      File.write(settings_path, <<~XML)
        <settings>
          <key id='enter' action='send_command'/>
          <key id='ctrl+a' action='cursor_home'/>
          <key id='ctrl+e' action='cursor_end'/>
          <key id='ctrl+w' action='cursor_backspace_word'/>
          <key id='ctrl+p' action='scroll_current_window_up_one'/>
          <key id='ctrl+n' action='scroll_current_window_down_one'/>
          <key id='ctrl+r' action='send_last_command'/>
          <key id='ctrl+t' action='next_tab'/>
          <key id='alt+2' action='switch_tab_2'/>
          #{layout.sub('<layout>', "<layout id='default'>")}
        </settings>
      XML
      app.send(:load_settings_and_layout)
      app.connection.attach(server)
    end

    after { FileUtils.remove_entry(dir) }

    # Press each key: a String is typed, an Integer is a key code, an Array
    # is a key sequence (alt+N is ESC then the digit).
    def press(*keys)
      combo = nil
      keys.flat_map { |key| key.is_a?(String) && key.length > 1 ? key.chars : [key] }.each do |key|
        Array(key).each { |ch| combo = app.send(:handle_key, ch, combo) }
      end
    end

    def shown = command_line.rows.first.rstrip

    it 'edits the command line with the bound keys and sends it with enter' do
      press('at goblin', 1, 'look ', 5, 23, 'troll', 10)

      expect(server.string).to eq "look at troll\n"
      expect(shown).to eq ''
      expect(main.rows.last(2)).to eq ['>look at', '  troll']
      expect(app.cmd_buffer.history.first).to eq 'look at troll'
    end

    it 'resends the last command with its key, echoing it first' do
      press('wave', 10, 18)

      expect(server.string).to eq "wave\nwave\n"
      expect(main.rows.last(2)).to eq %w[>wave >wave]
    end

    it 'scrolls the main window with the bound keys' do
      %w[l1 l2 l3 l4 l5].each { |line| main.add_string(line) }

      press(16, 16)
      expect(main.rows).to eq %w[l1 l2 l3]
      press(14)
      expect(main.rows).to eq %w[l2 l3 l4]
    end

    it 'switches tabs with the bound key and with alt+2' do
      press(20)
      expect(tabbed.active_tab).to eq 'lnet'
      press(20)
      expect(tabbed.active_tab).to eq 'logons'
      press([27, '2'])
      expect(tabbed.active_tab).to eq 'lnet'
    end
  end
end
