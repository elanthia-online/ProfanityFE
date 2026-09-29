# frozen_string_literal: true

# The feedback lines Profanity writes itself (dot-command replies, the
# autocomplete list, the copy notice, the disconnect notice), driven
# through the real Application and WindowManager on the virtual screen.
#
# Each example records, in order, every screen flush (with the main
# window's rows at that moment), every redraw of the command line (which
# puts the cursor back on it) and every render-lock block, so it pins not
# only what is drawn but when it reaches the terminal and whether the
# cursor is returned to the command line.

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

RSpec.describe 'Feedback lines in the main window' do
  feedback = FEEDBACK_COLOR
  inline = Application::INLINE_HIGHLIGHT_COLOR
  suggestion = Autocomplete::HIGHLIGHT_COLOR

  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:server) { StringIO.new }
  let(:main) { app.window_mgr.stream['main'] }
  let(:settings_path) { File.join(@dir, 'settings.xml') }
  # Color pair number per foreground color, so a cell's color can be read
  # back from its attributes.
  let(:pairs) { { feedback => 1, inline => 2, suggestion => 3 } }
  let(:events) { [] }
  let(:main_attrs) { "value='main'" }
  let(:layout) do
    <<~XML
      <layout>
        <window class='text' top='0' left='0' height='30' width='120' #{main_attrs}/>
        <window class='tabbed' top='0' left='121' height='5' width='28' tabs='thoughts,logons'/>
        <window class='tabbed' top='6' left='121' height='5' width='28' tabs='speech,familiar'/>
        <window class='room' top='31' left='0' height='4' width='120'/>
        <window class='command' top='39' left='0' height='1' width='150'/>
      </layout>
    XML
  end

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
    allow(Curses).to receive(:lines).and_return(40)
    allow(Curses).to receive(:cols).and_return(150)
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    LAYOUT['feedback'] = REXML::Document.new(layout).root
    app.window_mgr.load_layout('feedback')
    app.cmd_buffer.window = app.window_mgr.command_window
    app.connection.attach(server)
    SelectionManager.clear_selection
    record_events
  end

  # Record flushes, command-line redraws and render-lock blocks in order.
  def record_events
    allow(CursesRenderer).to receive(:doupdate).and_wrap_original do |original|
      events << [:doupdate, shown]
      original.call
    end
    allow(Curses).to receive(:doupdate).and_wrap_original do |original|
      events << [:curses_doupdate, shown]
      original.call
    end
    %i[synchronize render].each do |name|
      allow(CursesRenderer).to receive(name).and_wrap_original do |original, &block|
        events << [:"#{name}_begin", shown]
        original.call(&block).tap { events << [:"#{name}_end", shown] }
      end
    end
    allow(app.cmd_buffer).to receive(:refresh).and_wrap_original do |original|
      events << :refresh_command_line
      original.call
    end
  end

  # Run +cmd+ as if typed, returning what it recorded.
  def run(cmd)
    events.clear
    app.execute_command(cmd)
    events
  end

  # The main window's non-blank rows, right-trimmed, oldest first.
  def shown(window = main)
    return [] unless window.respond_to?(:rows)

    window.rows.map(&:rstrip).reject(&:empty?)
  end

  # Each non-blank row of +window+ with the color its text was drawn in
  # (nil for uncolored, an Array when mixed).
  def screen(window = main)
    window.rows.each_with_index.filter_map do |row, y|
      text = row.rstrip
      next if text.empty?

      colors = (0...text.length).map { |x| pairs.key(window.attrs_at(y, x) >> 8) }.uniq
      [text, colors.size == 1 ? colors.first : colors]
    end
  end

  # Make the command window deliver +key+ when .key waits for one.
  def press_key(key)
    window = app.cmd_buffer.window
    window.define_singleton_method(:timeout=) { |_ms| nil }
    window.define_singleton_method(:get_char) { key }
  end

  def help_rows
    ['*', *Application::DOT_COMMANDS.flat_map(&:help).map { |line| "*   #{line}" }, '*']
  end

  describe 'with a main window' do
    it '.help frames the help lines with "*" rows in the feedback color and flushes once, leaving the command line alone' do
      expect(run('.help')).to eq [[:doupdate, help_rows]]
      expect(screen).to eq(help_rows.map { |row| [row, feedback] })
    end

    it '.tab lists each tabbed window\'s tabs in the feedback color and flushes once' do
      rows = ['* Tabs: 1:thoughts* 2:logons', '* Tabs: 1:speech* 2:familiar']
      expect(run('.tab')).to eq [[:doupdate, rows]]
      expect(screen).to eq(rows.map { |row| [row, feedback] })
    end

    context 'with no tabbed window' do
      let(:layout) do
        <<~XML
          <layout>
            <window class='text' top='0' left='0' height='30' width='120' value='main'/>
            <window class='command' top='39' left='0' height='1' width='150'/>
          </layout>
        XML
      end

      it '.tab says so in the feedback color and flushes once' do
        expect(run('.tab')).to eq [[:doupdate, ['* No tabbed windows configured']]]
        expect(screen).to eq [['* No tabbed windows configured', feedback]]
      end
    end

    it '.links says the new state in the feedback color and flushes once' do
      msg = '* Links: ON (clickable links + drag-to-select; Shift+drag for native selection)'
      expect(run('.links')).to eq [[:doupdate, [msg]]]
      expect(screen).to eq [[msg, feedback]]
    end

    it '.links, turned off again while .select is on, says drag-to-select stays on' do
      run('.select')
      run('.links')
      expect(run('.links')).to eq [[:doupdate, shown]]
      expect(shown.last).to eq '* Links: OFF (drag-to-select still on via .select)'
    end

    it '.arrow says the new arrow mode in the feedback color and flushes once' do
      app.key_binding[Curses::KEY_UP] = app.key_action['previous_command']
      expect(run('.arrow')).to eq [[:doupdate, ['* Arrow mode: page scroll']]]
      expect(run('.arrow').last).to eq [:doupdate, ['* Arrow mode: page scroll', '* Arrow mode: line scroll']]
      expect(run('.arrow').last.last.last).to eq '* Arrow mode: history'
      expect(screen.map(&:last).uniq).to eq [feedback]
    end

    it '.select says the new state, redraws the command line, then flushes' do
      msg = '* Select: ON (drag-to-select; Shift+drag for native selection)'
      expect(run('.select')).to eq [:refresh_command_line, [:doupdate, [msg]]]
      expect(screen).to eq [[msg, feedback]]
    end

    it '.draghl says the new state, redraws the command line, then flushes' do
      msg = '* Drag highlight: OFF (highlight appears when you release)'
      expect(run('.draghl')).to eq [:refresh_command_line, [:doupdate, [msg]]]
      expect(screen).to eq [[msg, feedback]]
    end

    it '.reload that fails says why, redraws the command line, then flushes' do
      msg = "* Reload failed, settings unchanged: Missing end tag for 'gag' (got 'gags') (line 1)"
      expect(run('.reload')).to eq [:refresh_command_line, [:doupdate, [msg]]]
      expect(screen).to eq [[msg, feedback]]
    end

    it '.reload that succeeds shows nothing and does not flush' do
      File.write(settings_path, '<settings></settings>')
      expect(run('.reload')).to eq []
      expect(shown).to be_empty
    end

    it '.highlight with none active says so in the feedback color and flushes once' do
      expect(run('.highlight')).to eq [[:doupdate, ['* No inline highlights active']]]
      expect(screen).to eq [['* No inline highlights active', feedback]]
    end

    it '.highlight <text> confirms in the highlight color and flushes once' do
      expect(run('.highlight goblin')).to eq [[:doupdate, ['* Highlight added: goblin']]]
      expect(screen).to eq [['* Highlight added: goblin', inline]]
    end

    it '.highlight lists the highlights in their color between feedback-colored "*" rows, with one flush' do
      run('.highlight goblin')
      run('.highlight "a troll"')

      expect(run('.highlight').last(1)).to eq [[:doupdate, shown]]
      expect(events.size).to eq 1
      expect(screen.last(4)).to eq [['*', feedback], ['*   goblin', inline], ['*   a\\ troll', inline], ['*', feedback]]
    end

    it '.unhighlight confirms in the feedback color and flushes once' do
      run('.highlight goblin')
      expect(run('.unhighlight goblin')).to eq [[:doupdate, ['* Highlight added: goblin', '* Highlight removed: goblin']]]
      expect(screen.last).to eq ['* Highlight removed: goblin', feedback]
    end

    it '.unhighlight of an unknown text says so in the feedback color and flushes once' do
      expect(run('.unhighlight troll')).to eq [[:doupdate, ['* No inline highlight found for: troll']]]
      expect(screen).to eq [['* No inline highlight found for: troll', feedback]]
    end

    it '.key asks for a key (redrawing the command line), then shows the code framed by "*" rows' do
      press_key('q')
      expect(run('.key')).to eq [:refresh_command_line,
                                 [:doupdate, ['*', '* Waiting for key press...']],
                                 [:doupdate, ['*', '* Waiting for key press...', '* Detected keycode: q', '*']]]
      expect(screen.map(&:last).uniq).to eq [feedback]
    end

    it '.key with no key pressed says so' do
      press_key(nil)
      run('.key')
      expect(shown.last(2)).to eq ['* No key pressed within 5 seconds', '*']
    end

    it '.scrollcfg shows its prompt in the feedback color, redraws the command line, then flushes' do
      msg = '[PROFANITY] Scroll up with your mouse wheel or trackpad'
      expect(run('.scrollcfg')).to eq [:refresh_command_line, [:doupdate, [msg]]]
      expect(screen).to eq [[msg, feedback]]
    end

    it 'a missing layout is only warned about on stderr, not shown in the main window' do
      main.add_string('before')
      expect { run('.layout nosuch') }
        .to output(/Warning: layout 'nosuch' not found in LAYOUT \(available: .*feedback/).to_stderr
      expect(shown).to eq ['before']
      expect(events.grep(Array).map(&:last).uniq).to eq [['before']]
    end

    it 'autocomplete completes the common prefix, then lists the matches in its color with one flush' do
      ['look at goblin', 'look at troll'].each { |cmd| app.cmd_buffer.add_to_history(cmd) }
      'lo'.each_char { |ch| app.cmd_buffer.put_ch(ch) }
      events.clear

      app.key_action['autocomplete'].call

      listed = ['[autocomplete:2]', '[0] look at troll', '[1] look at goblin']
      expect(events).to eq [:refresh_command_line, [:doupdate, []], [:doupdate, listed]]
      expect(screen).to eq(listed.map { |row| [row, suggestion] })
      expect(app.cmd_buffer.text).to eq 'look at '
    end

    it 'autocomplete with no match says so in its color and flushes once' do
      'zz'.each_char { |ch| app.cmd_buffer.put_ch(ch) }
      events.clear

      app.key_action['autocomplete'].call

      expect(events).to eq [[:doupdate, ['[autocomplete] no suggestions']]]
      expect(screen).to eq [['[autocomplete] no suggestions', suggestion]]
    end

    context 'when copying a drag selection' do
      def mouse(bstate, y, x)
        allow(Curses).to receive(:getmouse).and_return(Struct.new(:bstate, :y, :x).new(bstate, y, x))
        app.send(:handle_key, Curses::KEY_MOUSE, nil)
      end

      before do
        allow(SelectionManager).to receive(:copy_to_clipboard)
        main.add_string('You see a goblin here.')
      end

      it 'says how much was copied in the feedback color, and the last flush shows it with the command line redrawn' do
        y = main.rows.index { |row| row.start_with?('You see') }
        mouse(Curses::BUTTON1_PRESSED, y, 0)
        events.clear
        mouse(Curses::BUTTON1_RELEASED, y, 7)

        expect(events).to include(:refresh_command_line)
        after_refresh = events.drop(events.index(:refresh_command_line) + 1)
        expect(after_refresh).to all(eq([:doupdate, ['You see a goblin here.', '* [copied 7 chars]']]))
        expect(after_refresh).not_to be_empty
        expect(screen.last).to eq ['* [copied 7 chars]', feedback]
      end
    end

    it 'the disconnect notice is drawn inside the render lock, framed by "*" rows in the feedback color' do
      allow(IO).to receive(:select).and_return(nil)
      queue = []
      eof_server = Object.new
      eof_server.define_singleton_method(:gets) { queue.shift }
      eof_server.define_singleton_method(:close) { nil }
      app.connection.attach(eof_server)
      app.send(:start_server_thread).join
      app.cmd_buffer.window.define_singleton_method(:getch) { 'q' }
      events.clear

      expect { app.send(:input_loop) }.to raise_error(SystemExit)

      notice = ['*', '* Connection closed', '* Press any key to exit...', '*']
      expect(events).to eq [[:render_begin, []], [:render_end, notice]]
      expect(screen).to eq(notice.map { |row| [row, feedback] })
    end

    context 'when the main window has timestamps' do
      let(:main_attrs) { "value='main' timestamp='true'" }

      before { allow(Time).to receive(:now).and_return(Time.new(2026, 9, 29, 7, 5, 0)) }

      it 'stamps every feedback line, coloring only the text before the stamp' do
        run('.help')
        run('.highlight goblin')
        run('.select')

        rows = screen
        expect(rows.first).to eq ['*  [07:05]', [feedback, nil]]
        expect(rows).to include(['* Highlight added: goblin [07:05]', [inline, nil]],
                                ['* Select: ON (drag-to-select; Shift+drag for native selection) [07:05]', [feedback, nil]])
        expect(rows.map(&:first)).to all(end_with(' [07:05]'))
      end

      it 'stamps the autocomplete list' do
        ['look at goblin', 'look at troll'].each { |cmd| app.cmd_buffer.add_to_history(cmd) }
        'lo'.each_char { |ch| app.cmd_buffer.put_ch(ch) }

        app.key_action['autocomplete'].call

        expect(screen.first).to eq ['[autocomplete:2] [07:05]', [suggestion, nil]]
      end
    end
  end

  describe 'without a main window' do
    let(:main_attrs) { "value='other'" }
    let(:other) { app.window_mgr.stream['other'] }

    it 'has no main window' do
      expect(app.window_mgr.stream).not_to have_key('main')
    end

    %w[.help .tab .links .arrow .select .draghl .reload .highlight .scrollcfg].each do |cmd|
      it "#{cmd} draws nothing, flushes nothing and leaves the command line alone" do
        expect(run(cmd)).to eq []
        expect(shown(other)).to be_empty
      end
    end

    it '.highlight <text> adds no highlight and draws nothing' do
      expect(run('.highlight goblin')).to eq []
      expect(HIGHLIGHT).to be_empty
      expect(shown(other)).to be_empty
    end

    it '.unhighlight draws nothing' do
      expect(run('.unhighlight goblin')).to eq []
    end

    it '.key does not wait for a key' do
      window = app.cmd_buffer.window
      window.define_singleton_method(:get_char) { raise 'read a key' }
      expect(run('.key')).to eq []
    end

    it 'autocomplete still completes the command line but lists nothing' do
      ['look at goblin', 'look at troll'].each { |cmd| app.cmd_buffer.add_to_history(cmd) }
      'lo'.each_char { |ch| app.cmd_buffer.put_ch(ch) }
      events.clear

      app.key_action['autocomplete'].call

      expect(events).to eq [:refresh_command_line, [:doupdate, []]]
      expect(app.cmd_buffer.text).to eq 'look at '
      expect(shown(other)).to be_empty
    end

    it 'copying a drag selection flushes once and says nothing' do
      allow(SelectionManager).to receive(:copy_to_clipboard)
      other.add_string('You see a goblin here.')
      y = other.rows.index { |row| row.start_with?('You see') }
      [[Curses::BUTTON1_PRESSED, 0], [Curses::BUTTON1_RELEASED, 7]].each do |bstate, x|
        events.clear
        allow(Curses).to receive(:getmouse).and_return(Struct.new(:bstate, :y, :x).new(bstate, y, x))
        app.send(:handle_key, Curses::KEY_MOUSE, nil)
      end

      expect(SelectionManager).to have_received(:copy_to_clipboard).with('You see')
      expect(events).to eq [[:doupdate, []]]
      expect(shown(other)).to eq ['You see a goblin here.']
    end
  end

  describe 'with main sent to a sink' do
    let(:layout) do
      <<~XML
        <layout>
          <window class='sink' value='main'/>
          <window class='text' top='0' left='0' height='30' width='120' value='other'/>
          <window class='command' top='39' left='0' height='1' width='150'/>
        </layout>
      XML
    end
    let(:other) { app.window_mgr.stream['other'] }

    it 'still flushes (and redraws the command line) as if the lines were shown' do
      expect(run('.help')).to eq [[:doupdate, []]]
      expect(run('.select')).to eq [:refresh_command_line, [:doupdate, []]]
      expect(run('.tab')).to eq [[:doupdate, []]]
      expect(shown(other)).to be_empty
    end
  end
end
