# frozen_string_literal: true

# Drives every dot-command through Application#execute_command on a real
# layout (virtual screen) and asserts what the user sees or what reaches
# the game: which input is handled locally, which goes to the server, what
# arguments the handlers get, and that .help lists exactly the commands
# that exist.

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

# Stub ColorManager for .fixcolor (the real one needs a terminal)
module ColorManager
  def self.reinitialize_colors = nil
  def self.configure(**) = nil
end unless defined?(ColorManager)

RSpec.describe 'Dot-commands typed on the command line' do
  # Every dot-command, with what it takes after its name
  commands = {
    'quit' => :none, 'key' => :none, 'fixcolor' => :none, 'resync' => :none,
    'reload' => :none, 'layout' => :required, 'resize' => :none, 'tab' => :optional,
    'arrow' => :none, 'links' => :none, 'select' => :none, 'draghl' => :none,
    'scrollcfg' => :none, 'unhighlight' => :required, 'highlight' => :optional,
    'help' => :none
  }.freeze

  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:server) { StringIO.new }
  let(:main) { app.window_mgr.stream['main'] }
  let(:tabbed) { TabbedTextWindow.list.first }
  let(:terminal) { { lines: 40, cols: 150 } }
  let(:settings_path) { File.join(@dir, 'settings.xml') }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    File.write(settings_path, '<settings><gag>x</gags></settings>')
    allow(ProfanityLog).to receive(:write)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    allow(ProfanitySettings).to receive(:load_setting).and_call_original
    allow(ProfanitySettings).to receive(:save_setting)
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    allow(Curses).to receive(:lines) { terminal[:lines] }
    allow(Curses).to receive(:cols) { terminal[:cols] }
    LAYOUT['dotcmd'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='lines-10' width='120' value='main'/>
        <window class='tabbed' top='0' left='121' height='5' width='28' tabs='thoughts,logons'/>
        <window class='command' top='lines-1' left='0' height='1' width='cols'/>
      </layout>
    XML
    app.window_mgr.load_layout('dotcmd')
    app.cmd_buffer.window = app.window_mgr.command_window
    app.instance_variable_set(:@server, server)
    HIGHLIGHT.clear
  end

  # Make the command window deliver +key+ when .key waits for one
  def press_key(key)
    window = app.cmd_buffer.window
    window.define_singleton_method(:timeout=) { |_ms| nil }
    window.define_singleton_method(:get_char) { key }
  end

  # The non-blank rows of the main window, oldest first
  def shown
    main.rows.reject { |row| row.strip.empty? }
  end

  # The lines .help prints, without the "*   " prefix and framing rows
  def help_lines
    app.execute_command('.help')
    shown.grep(/\A\*   /).map { |row| row.delete_prefix('*   ').rstrip }
  end

  describe 'each command' do
    it '.quit exits' do
      expect { app.execute_command('.quit') }.to raise_error(SystemExit)
      expect(server.string).to be_empty
    end

    it '.key shows the keycode of the next key' do
      press_key('q')

      app.execute_command('.key')

      expect(shown).to include('* Detected keycode: q')
    end

    it '.fixcolor reinitializes the colors' do
      expect(ColorManager).to receive(:reinitialize_colors)
      app.execute_command('.fixcolor')
      expect(server.string).to be_empty
    end

    it '.resync lets the server time offset be measured again' do
      app.shared_state.skip_server_time_offset = true
      app.execute_command('.resync')
      expect(app.shared_state.skip_server_time_offset).to be false
    end

    it '.reload reloads the settings file and says why it failed' do
      app.execute_command('.reload')

      expect(shown).to eq ['* Reload failed, settings unchanged: Missing end tag for \'gag\' (got \'gags\') (line 1)']
    end

    it '.layout <name> switches to that layout and moves the command line to its command window' do
      LAYOUT['second'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='lines-20' width='100' value='main'/>
          <window class='text' top='lines-19' left='0' height='5' width='100' value='extra'/>
          <window class='command' top='lines-2' left='0' height='1' width='cols'/>
        </layout>
      XML

      app.execute_command('.layout second')

      expect(app.window_mgr.stream.keys).to contain_exactly('main', 'extra')
      expect(app.cmd_buffer.window).to equal(app.window_mgr.command_window)
      expect(main.maxy).to eq 20
      expect(server.string).to be_empty
    end

    it '.resize fits the windows to the terminal' do
      terminal[:lines] = 30

      app.execute_command('.resize')

      expect(main.maxy).to eq 20
    end

    it '.tab lists the tabs, marking the active one' do
      app.execute_command('.tab')
      expect(shown.last).to eq '* Tabs: 1:thoughts* 2:logons'
    end

    it '.tab <N> switches to the tab with that number' do
      app.execute_command('.tab 2')
      expect(tabbed.active_tab).to eq 'logons'
    end

    it '.tab <name> switches to the tab with that name' do
      app.execute_command('.tab logons')
      expect(tabbed.active_tab).to eq 'logons'
    end

    it '.arrow cycles the arrow keys and says to what' do
      app.key_binding[Curses::KEY_UP] = app.key_action['previous_command']

      app.execute_command('.arrow')

      expect(app.key_binding[Curses::KEY_UP]).to equal(app.key_action['scroll_current_window_up_page'])
      expect(shown.last).to eq '* Arrow mode: page scroll'
    end

    it '.links turns link highlighting on' do
      app.execute_command('.links')
      expect(app.shared_state.blue_links).to be true
      expect(shown.last).to start_with('* Links: ON')
    end

    it '.select turns drag-to-select on' do
      app.execute_command('.select')
      expect(shown.last).to start_with('* Select: ON')
    end

    it '.draghl toggles the live drag highlight' do
      app.execute_command('.draghl')
      expect(app.mouse_scroll.drag_highlight).to be false
      expect(shown.last).to start_with('* Drag highlight: OFF')
    end

    it '.scrollcfg starts the scroll wheel calibration' do
      app.execute_command('.scrollcfg')
      expect(app.mouse_scroll.configuring?).to be true
      expect(shown.last).to eq '[PROFANITY] Scroll up with your mouse wheel or trackpad'
    end

    it '.highlight <text> adds an inline highlight' do
      app.execute_command('.highlight goblin')
      expect(HIGHLIGHT.keys.map(&:source)).to eq ['goblin']
      expect(shown.last).to eq '* Highlight added: goblin'
    end

    it '.highlight lists the inline highlights' do
      app.execute_command('.highlight goblin')
      app.execute_command('.highlight')
      expect(shown.last(3).map(&:rstrip)).to eq ['*', '*   goblin', '*']
    end

    it '.unhighlight <text> removes an inline highlight' do
      app.execute_command('.highlight goblin')

      app.execute_command('.unhighlight goblin')

      expect(HIGHLIGHT).to be_empty
      expect(shown.last).to eq '* Highlight removed: goblin'
    end

    it '.help lists the dot-commands' do
      expect(help_lines).to include('.help              Show this help')
      expect(server.string).to be_empty
    end
  end

  describe 'matching' do
    # A command's effect that doesn't end the process, for the table below
    def run_harmless(cmd)
      app.shared_state.skip_server_time_offset = true
      app.execute_command(cmd)
    end

    commands.each_key do |name|
      next if name == 'quit'

      input = commands[name] == :required ? "#{name} goblin" : name
      [input.upcase, input.capitalize, input.swapcase.sub(/\A./, &:downcase)].uniq.each do |typed|
        it "handles .#{typed} locally, whatever the case" do
          allow(ColorManager).to receive(:reinitialize_colors)
          press_key(nil)
          run_harmless(".#{typed}")
          expect(server.string).to be_empty
        end
      end
    end

    it 'handles .QUIT and .Quit locally by exiting' do
      expect { app.execute_command('.QUIT') }.to raise_error(SystemExit)
      expect { app.execute_command('.Quit now') }.to raise_error(SystemExit)
    end

    it 'runs the command a mixed-case name spells: .ReSyNc resyncs' do
      run_harmless('.ReSyNc')
      expect(app.shared_state.skip_server_time_offset).to be false
    end

    {
      '.quitter'   => ";quitter\n",
      '.arrows'    => ";arrows\n",
      '.help-me'   => ";help-me\n",
      '.tabulate'  => ";tabulate\n",
      '.tab-2'     => ";tab-2\n",
      '.layouts x' => ";layouts x\n",
      '.QUITTER'   => ";QUITTER\n",
      '. quit'     => "; quit\n",
      '..quit'     => ";.quit\n",
      ' .quit'     => " .quit\n",
      'quit'       => "quit\n",
      '.'          => ";\n"
    }.each do |typed, forwarded|
      it "sends #{typed.inspect} to the game as #{forwarded.chomp.inspect}, since it is not a whole command name" do
        app.execute_command(typed)
        expect(server.string).to eq forwarded
      end
    end

    commands.each_key do |name|
      %w[x s - 1 _].each do |suffix|
        it "sends .#{name}#{suffix} to the game as ;#{name}#{suffix}" do
          app.execute_command(".#{name}#{suffix}")
          expect(server.string).to eq ";#{name}#{suffix}\n"
        end
      end
    end

    it 'treats a tab after the name like a space' do
      app.execute_command(".tab\tlogons")
      expect(tabbed.active_tab).to eq 'logons'
    end

    # A settings macro with a newline (&#10;) sends input that spans lines,
    # and Lich reads each line as its own command. Only the start of the
    # input is a dot-command; a later line is not run by Profanity. (Whether
    # its leading '.' becomes ';' on the way to the game is left open here.)
    commands.each do |name, args|
      input = args == :required ? "#{name} goblin" : name
      it "does not run .#{input} from the second line of the input, and sends both lines to the game" do
        allow(ColorManager).to receive(:reinitialize_colors)
        press_key(nil)

        expect { run_harmless("look\n.#{input}") }.not_to raise_error

        expect(app.shared_state.skip_server_time_offset).to be true
        expect(server.string).to match(/\Alook\n[.;]#{Regexp.escape(input)}\n\z/)
      end
    end

    it 'does not add a highlight from the second line of the input' do
      app.execute_command("look\n.highlight goblin")
      expect(HIGHLIGHT).to be_empty
      expect(shown).to be_empty
    end

    it 'ignores what follows a command that takes no argument' do
      app.execute_command('.resync please')
      expect(app.shared_state.skip_server_time_offset).to be false
      expect(server.string).to be_empty
    end
  end

  describe 'arguments' do
    %w[layout unhighlight].each do |name|
      it ".#{name} without an argument goes to the game as ;#{name}" do
        app.execute_command(".#{name}")
        expect(server.string).to eq ";#{name}\n"
      end

      it ".#{name} followed by one space goes to the game unchanged" do
        app.execute_command(".#{name} ")
        expect(server.string).to eq ";#{name} \n"
      end

      it ".#{name.upcase} without an argument goes to the game as typed" do
        app.execute_command(".#{name.upcase}")
        expect(server.string).to eq ";#{name.upcase}\n"
      end
    end

    it '.layout passes the name after any run of whitespace' do
      LAYOUT['second'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='10' width='100' value='main'/>
          <window class='text' top='11' left='0' height='5' width='100' value='extra'/>
        </layout>
      XML

      app.execute_command(".layout \t second")

      expect(app.window_mgr.stream.keys).to contain_exactly('main', 'extra')
    end

    it '.unhighlight passes the text after any run of whitespace' do
      app.execute_command('.highlight goblin')
      app.execute_command(".unhighlight \t goblin")
      expect(HIGHLIGHT).to be_empty
    end

    it '.tab strips the name it is given' do
      app.execute_command('.tab   logons   ')
      expect(tabbed.active_tab).to eq 'logons'
    end

    it '.tab followed by only spaces lists the tabs' do
      app.execute_command('.tab    ')
      expect(shown.last).to eq '* Tabs: 1:thoughts* 2:logons'
    end

    it '.highlight strips the text it is given' do
      app.execute_command(".highlight   goblin \t ")
      expect(HIGHLIGHT.keys.map(&:source)).to eq ['goblin']
    end

    it '.highlight followed by only spaces lists the inline highlights' do
      app.execute_command('.highlight    ')
      expect(shown.last).to eq '* No inline highlights active'
      expect(HIGHLIGHT).to be_empty
    end

    it '.unhighlight removes a highlight whose text was typed with trailing spaces' do
      pending '.unhighlight does not strip its argument, unlike .highlight (found while building the dot-command registry)'
      app.execute_command('.highlight goblin')
      app.execute_command('.unhighlight goblin  ')
      expect(HIGHLIGHT).to be_empty
    end
  end

  describe '.help' do
    it 'names every dot-command, and only those' do
      named = help_lines.map { |line| line[/\A\.(\S+)/, 1] }.uniq
      expect(named).to match_array(commands.keys)
    end

    it 'shows an argument form for each command that takes one, and a bare form for each that runs without one' do
      forms = help_lines.map { |line| line[/\A\.\S+(?: <[^>]+>)?/] }.uniq
      expected = commands.flat_map do |name, args|
        case args
        when :none then [".#{name}"]
        when :optional then [".#{name}", ".#{name} <"]
        when :required then [".#{name} <"]
        end
      end
      expect(forms.map { |form| form.sub(/<[^>]+>\z/, '<') }).to match_array(expected)
    end

    it 'lists each command\'s lines together, in the order the commands are matched' do
      named = help_lines.map { |line| line[/\A\.(\S+)/, 1] }
      expect(named.chunk_while { |a, b| a == b }.map(&:first)).to eq Application::DOT_COMMANDS.map(&:name)
    end

    it 'lists the commands in this order, with these descriptions' do
      expect(help_lines).to eq [
        '.quit              Exit Profanity immediately',
        '.key               Show raw keycode of next key press',
        '.fixcolor          Reinitialize custom Curses colors',
        '.resync            Reset server time offset for timers',
        '.reload            Hot-reload settings XML file',
        '.layout <name>     Switch to a named window layout',
        '.resize            Recalculate window sizes for terminal',
        '.tab               List tabs (active marked with *)',
        '.tab <N|name>      Switch tab by number or name',
        '.arrow             Cycle arrow keys: history/page/line',
        '.links             Toggle in-game link highlighting',
        '.select            Toggle drag-to-select without links',
        '.draghl            Toggle live highlight while dragging',
        '.scrollcfg         Configure mouse scroll wheel',
        '.unhighlight <text> Remove an inline highlight',
        '.highlight <text>   Add cyan highlight for text (session only)',
        '.highlight          List active inline highlights',
        '.help              Show this help'
      ]
    end

    it 'frames the list with a blank feedback row above and below' do
      app.execute_command('.help')
      rows = main.rows.map(&:rstrip).reject(&:empty?)
      expect(rows.first).to eq '*'
      expect(rows.last).to eq '*'
      expect(rows.length).to eq 20
    end
  end
end
