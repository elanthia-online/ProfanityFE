# frozen_string_literal: true

# Tests key macros as the user sees them on the command line
# (spec/support/screen_line_window.rb): what each escape types, where the
# cursor ends up, and what is sent. First with MacroInterpreter on its own,
# then through Application#do_macro, which SettingsLoader binds macro keys to.

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
require_relative '../../lib/macro_interpreter'
require_relative '../../lib/application'
require_relative '../support/screen_line_window'

RSpec.describe MacroInterpreter do
  let(:screen) { ScreenLineWindow.new(20) }

  describe 'on its own' do
    let(:cmd_buffer) { CommandBuffer.new.tap { |buffer| buffer.window = screen } }
    # Each \r sends: record the line as it was, then clear it as
    # Application#send_command does.
    let(:sent) { [] }
    let(:macro) do
      sent = self.sent
      buffer = cmd_buffer
      described_class.new(cmd_buffer: buffer, send_command: -> { sent << buffer.clear_and_get })
    end

    it 'types plain text and leaves the cursor after it' do
      macro.call('look')

      expect([screen.visible, screen.curx, sent]).to eq ['look', 4, []]
    end

    it 'types a non-ASCII character as one character' do
      macro.call('say café')

      expect([screen.visible, screen.curx]).to eq ['say café', 8]
    end

    it 'types \\\\ as a backslash and \\@ as an at sign' do
      macro.call('a\\\\b\\@c')

      expect(screen.visible).to eq 'a\\b@c'
    end

    it 'clears the command line with \\x, including text typed before the macro' do
      cmd_buffer.put_ch('q')

      macro.call('abc\\xdef')

      expect([screen.visible, screen.curx]).to eq ['def', 3]
    end

    it 'sends the line at each \\r and keeps typing after it' do
      macro.call('look\\rnorth\\rsay hi')

      expect(sent).to eq %w[look north]
      expect([screen.visible, screen.curx]).to eq ['say hi', 6]
    end

    it 'sends text typed before the macro along with the macro text' do
      'get '.each_char { |ch| cmd_buffer.put_ch(ch) }

      macro.call('sword\\r')

      expect(sent).to eq ['get sword']
      expect(screen.visible).to eq ''
    end

    it 'puts the cursor where the bare @ was' do
      macro.call('say @ to you')

      expect([screen.visible, screen.curx]).to eq ['say  to you', 4]
    end

    it 'puts the cursor at the last of several @ marks' do
      macro.call('a@b@c')

      expect([screen.visible, screen.curx]).to eq ['abc', 2]
    end

    it 'forgets an @ mark once the line is sent with \\r' do
      macro.call('a@b\\rcd')

      expect(sent).to eq ['ab']
      expect([screen.visible, screen.curx]).to eq ['cd', 2]
    end

    it 'keeps an @ mark that comes after the last \\r' do
      macro.call('go\\rsay @!')

      expect([screen.visible, screen.curx]).to eq ['say !', 4]
    end

    # Characterization: \? has always put the screen cursor at the index of
    # the ? in the macro, minus 3, without moving the command line's own
    # position. The refactor keeps it as it was.
    it 'moves the screen cursor to the ? index minus 3 with \\?, leaving the edit position alone' do
      macro.call('abcde\\?')

      expect([screen.visible, screen.curx, cmd_buffer.pos]).to eq ['abcde', 3, 5]
    end

    it 'drops an unknown escape and a trailing backslash' do
      macro.call('a\\qb\\')

      expect([screen.visible, sent]).to eq ['ab', []]
    end

    it 'does nothing visible for an empty macro' do
      macro.call('')

      expect([screen.visible, screen.curx, sent]).to eq ['', 0, []]
    end

    it 'flushes the screen once, after the whole macro' do
      flushes = []
      allow(CursesRenderer).to receive(:doupdate) { flushes << screen.visible }

      macro.call('abc@d')

      expect(flushes).to eq ['abcd']
    end
  end

  describe 'through Application#do_macro' do
    let(:server) { StringIO.new }
    let(:main) { app.window_mgr.stream['main'] }
    let(:app) do
      allow(MouseScroll).to receive(:new).and_return(instance_double(MouseScroll, enable_click_events: nil))
      Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                      settings_file: File.join(SPEC_HOME, 'settings.xml'), host: '127.0.0.1', port: 8000)
    end

    before do
      LAYOUT['macro'] = REXML::Document.new(<<~XML).root
        <layout><window class='text' top='0' left='0' height='4' width='102' value='main'/></layout>
      XML
      app.window_mgr.load_layout('macro')
      app.cmd_buffer.window = screen
      app.connection.attach(server)
    end

    it 'echoes and sends each \\r line, adds it to the history and runs dot-commands' do
      app.do_macro('look\\r.links\\rsay @ there')

      expect(server.string).to eq "look\n"
      expect(main.rows).to eq ['>look', '>.links',
                               '* Links: ON (clickable links + drag-to-select; Shift+drag for native selection)', '']
      expect(app.shared_state.blue_links).to be true
      expect(app.cmd_buffer.history.first).to eq '.links'
      expect([screen.visible, screen.curx]).to eq ['say  there', 4]
    end

    it 'runs a macro bound to a key in the settings file' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'settings.xml')
        File.write(path, "<settings><key id='ctrl+l' macro='\\xlook\\r'/></settings>")
        SettingsLoader.load(path, app.key_binding, app.key_action, app.method(:do_macro))
      end
      'draft'.each_char { |ch| app.cmd_buffer.put_ch(ch) }

      app.key_binding[12].call

      expect(server.string).to eq "look\n"
      expect(screen.visible).to eq ''
    end
  end
end
