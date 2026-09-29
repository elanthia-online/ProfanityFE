# frozen_string_literal: true

# Tests Application on a layout on the virtual screen, outside the input
# loop: the state it starts with from the command-line options, what it
# sends for a command that is not a dot-command, sending and resending
# commands with the key actions, the key actions with no command window,
# and .key.
#
# Elsewhere: dot-command dispatch in dot_commands_spec.rb, .reload in
# reload_command_spec.rb, .scrollcfg in scroll_calibration_spec.rb,
# startup and connecting in application_startup_spec.rb, the input loop
# in input_loop_spec.rb and the end of a session in session_end_spec.rb.

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

RSpec.describe Application do
  let(:links) { false }
  let(:app) { new_app(links: links) }
  let(:server) { StringIO.new }
  let(:main) { app.window_mgr.stream['main'] }
  let(:command_line) { app.cmd_buffer.window }
  # A main window of 4 rows and a command line of 20 columns
  let(:layout) do
    <<~XML
      <layout>
        <window class='text' top='0' left='0' height='4' width='60' value='main'/>
        <window class='command' top='5' left='0' height='1' width='20'/>
      </layout>
    XML
  end

  # An Application with these command-line options
  def new_app(char: nil, links: false)
    described_class.new({ char: char, no_status: true, links: links, room_window_only: false },
                        settings_file: File.join(SPEC_HOME, 'settings.xml'), host: '127.0.0.1', port: 8000)
  end

  before do
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    LAYOUT['app'] = REXML::Document.new(layout).root
    app.execute_command('.layout app')
    app.connection.attach(server)
  end

  def type(text) = text.each_char { |ch| app.cmd_buffer.put_ch(ch) }

  def press(action) = app.key_action.fetch(action).call

  describe 'the command-line options' do
    it 'names the session after --char, capitalized' do
      expect(new_app(char: 'mahtra').shared_state.char_name).to eq 'Mahtra'
    end

    it 'names the session ProfanityFE without --char' do
      expect(new_app(char: nil).shared_state.char_name).to eq 'ProfanityFE'
    end

    context 'with --links' do
      let(:links) { true }

      it 'starts with links on, so .links turns them off' do
        app.execute_command('.links')

        expect(main.rows.last).to eq '* Links: OFF (native terminal selection)'
      end
    end
  end

  describe 'a command that is not a dot-command' do
    it 'sends an empty command to the game as an empty line' do
      app.execute_command('')

      expect(server.string).to eq "\n"
    end

    it 'sends a macro of only \\x\\r as an empty line, clearing what was typed' do
      type('draft')

      app.do_macro('\\x\\r')

      expect(server.string).to eq "\n"
      expect(command_line.row(0)).to eq ''
      expect(main.rows.last).to eq '>'
    end
  end

  describe 'sending commands' do
    it 'send_command sends the command line, clears it, and echoes it in main after the > prompt' do
      type('go')

      press('send_command')

      expect(server.string).to eq "go\n"
      expect(command_line.row(0)).to eq ''
      expect(main.rows.last).to eq '>go'
    end

    context 'with an unsent draft stashed by the up arrow' do
      def type_and_send(text)
        type(text)
        press('send_command')
      end

      # Type "draft", press up (the line shows "look"), press enter to
      # resend "look", then send "exp1". The draft was never sent.
      before do
        type_and_send('look')
        type('draft')
        press('previous_command')
        press('send_command')
        type_and_send('exp1')
        server.truncate(0)
        server.rewind
      end

      it 'send_second_last_command sends the second-last sent line, not the draft' do
        press('send_second_last_command')

        expect(server.string).to eq "look\n"
      end

      it 'send_last_command sends the last sent line' do
        press('send_last_command')

        expect(server.string).to eq "exp1\n"
      end

      it 'the up arrow recalls only sent lines' do
        recalled = Array.new(3) do
          press('previous_command')
          command_line.row(0)
        end

        expect(recalled).to eq %w[exp1 look look]
      end
    end

    # The resend keys send only lines that were sent: an edit of a recalled
    # entry and a line saved by the down arrow stay out of them.
    context 'with lines that were never sent' do
      # What the command line shows after each of +count+ up-arrow presses
      def up_arrow_lines(count)
        Array.new(count) do
          press('previous_command')
          command_line.row(0)
        end
      end

      # What the game receives when the key action is pressed
      def resent_by(action)
        server.truncate(0)
        server.rewind
        press(action)
        server.string
      end

      before do
        type('look')
        press('send_command')
      end

      it 'send_last_command sends the recalled line, not the edit left in it' do
        press('previous_command') # recall "look"
        press('cursor_backspace') # edit it to "loo", not sent
        press('next_command') # back down to the empty line

        expect(resent_by('send_last_command')).to eq "look\n"
      end

      it 'send_second_last_command skips an edit left in an older entry' do
        type('north')
        press('send_command')
        2.times { press('previous_command') } # recall "look"
        type(' me')
        2.times { press('next_command') }

        expect(resent_by('send_second_last_command')).to eq "look\n"
      end

      it 'send_last_command sends the last sent line, not a line saved by the down arrow' do
        type('draft')
        press('next_command') # clears the line and keeps "draft" for the up arrow

        expect(resent_by('send_last_command')).to eq "look\n"
      end

      it 'send_second_last_command skips a line saved by the down arrow' do
        type('north')
        press('send_command')
        type('draft')
        press('next_command')

        expect(resent_by('send_second_last_command')).to eq "look\n"
      end

      it 'the up arrow still shows the edit and the line saved by the down arrow' do
        press('previous_command')
        press('cursor_backspace')
        press('next_command')
        type('draft')
        press('next_command')

        expect(up_arrow_lines(3)).to eq %w[draft loo loo]
      end

      it 'a resend key does nothing when fewer lines were sent' do
        type('draft')
        press('next_command')

        expect(resent_by('send_second_last_command')).to eq ''
      end
    end

    it 'autocomplete does not complete from an unsent draft' do
      app.cmd_buffer.add_to_history('look')
      type('draft')
      press('previous_command')
      press('next_command')
      press('cursor_kill_line')
      type('dr')

      press('autocomplete')

      expect(command_line.row(0)).to eq 'dr'
    end
  end

  context 'with a main window that keeps 2 lines' do
    # 2 lines wrapped at 10 columns fill 9 rows of 3
    let(:layout) do
      <<~XML
        <layout>
          <window class='text' top='0' left='0' height='3' width='12' value='main' buffer-size='2'/>
          <window class='command' top='5' left='0' height='1' width='20'/>
        </layout>
      XML
    end

    it 'scroll_current_window_bottom returns to the newest rows when scrolled back more rows than the buffer size' do
      ['one two three four five six seven', 'one two three four'].each { |line| main.add_string(line) }
      main.scroll_lines(-main.maxy)
      expect(main.buffer_pos).to be > main.max_buffer_size

      press('scroll_current_window_bottom')

      expect(main.rows).to eq ['one two', '  three', '  four']
    end
  end

  describe 'the key actions with no command window' do
    it 'leave the command line as it was' do
      type('ab')
      app.cmd_buffer.window = nil

      press('cursor_left')

      expect([app.cmd_buffer.text, app.cmd_buffer.pos]).to eq ['ab', 2]
    end
  end

  # BUG FOUND (fixed here): input_loop puts the command window in nodelay
  # mode, and .key called getch on that same window, so getch returned nil
  # at once and .key printed "Detected keycode: " with no key.
  describe '.key' do
    # Make the command window read keys as curses does: nothing at once in
    # nodelay mode (as the input loop leaves it), and +key+ (or what the
    # block returns) when the read may wait (after timeout=).
    def key_waiting(key = nil, &on_wait)
      command_line.nodelay = true
      command_line.define_singleton_method(:get_char) do
        delay = call_log.reverse.find { |name, _| %i[timeout= nodelay=].include?(name) }
        next nil if delay == [:nodelay=, [true]]

        on_wait ? on_wait.call : key
      end
    end

    # The delay settings of the command window, oldest first
    def delays = command_line.call_log.select { |name, _| %i[timeout= nodelay=].include?(name) }

    it 'waits for a key and shows its keycode' do
      key_waiting(Curses::KEY_UP)

      app.execute_command('.key')

      expect(main.rows).to eq ['*', '* Waiting for key press...', "* Detected keycode: #{Curses::KEY_UP}", '*']
    end

    it 'bounds the wait with a 5 second timeout rather than blocking forever' do
      key_waiting('a')

      app.execute_command('.key')

      expect(delays).to include([:timeout=, [5000]])
    end

    it 'puts the command window back in nodelay mode after reading the key' do
      key_waiting('a')

      app.execute_command('.key')

      expect(delays.last(2)).to eq [[:timeout=, [5000]], [:nodelay=, [true]]]
    end

    it 'says no key was pressed when the wait times out' do
      key_waiting(nil)

      app.execute_command('.key')

      expect(main.rows.last(2)).to eq ['* No key pressed within 5 seconds', '*']
    end

    it 'puts the command window back in nodelay mode when the read raises' do
      key_waiting { raise IOError, 'terminal gone' }

      expect { app.execute_command('.key') }.to raise_error(IOError, 'terminal gone')
      expect(delays.last).to eq [:nodelay=, [true]]
    end
  end
end
