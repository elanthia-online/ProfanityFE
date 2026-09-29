# frozen_string_literal: true

# Where the terminal cursor ends up after the input path flushes the
# screen. ncurses leaves it wherever the window refreshed last put it
# (modelled by Curses::TerminalCursor), so a flush that refreshes another
# window after the command window leaves the cursor in that window until
# the next key. Every flush from the input path (keys, dot-commands,
# macros, autocomplete, the mouse and the input loop's tick) must leave it
# on the command line, at the edit position.
#
# Driven through the real Application, WindowManager and CommandBuffer on
# the virtual screen.

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

RSpec.describe 'The terminal cursor after an input-path flush' do
  let(:server) { StringIO.new }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: true, room_window_only: false },
                    settings_file: File.join(SPEC_HOME, 'settings.xml'), host: '127.0.0.1', port: 8000)
  end
  let(:main) { app.window_mgr.stream['main'] }
  let(:thoughts) { app.window_mgr.stream['thoughts'] }
  let(:cmd_window) { app.cmd_buffer.window }
  let(:buffer) { app.cmd_buffer }

  # The command line starts one column in (after the prompt indicator) on
  # the bottom row, so a cursor left in any other window is off it.
  let(:layout) do
    <<~XML
      <layout>
        <window class='text' top='0' left='0' height='6' width='42' value='main'/>
        <window class='tabbed' top='0' left='43' height='6' width='30' tabs='thoughts,logons'/>
        <window class='indicator' top='9' left='0' height='1' width='1' value='prompt' label='&gt;'/>
        <window class='command' top='9' left='1' height='1' width='20'/>
      </layout>
    XML
  end

  before do
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    allow(ProfanitySettings).to receive(:save_setting)
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    allow(SelectionManager).to receive(:copy_to_clipboard)
    SelectionManager.clear_selection
    LAYOUT['cursor'] = REXML::Document.new(layout).root
    app.window_mgr.load_layout('cursor')
    app.cmd_buffer.window = app.window_mgr.command_window
    app.connection.attach(server)
    main.add_string('go north', [{ start: 3, end: 8, cmd: 'north' }])
    # Start with the terminal cursor in main, where a flush that doesn't
    # refresh the command window last would leave it.
    main.noutrefresh
    Curses.doupdate
  end

  after { SelectionManager.clear_selection }

  # The terminal cursor's screen position.
  def cursor = Curses::TerminalCursor.position

  # The screen position of the command line's edit position.
  def edit_position = [cmd_window.begy, cmd_window.begx + buffer.pos - buffer.offset]

  def type(text) = text.each_char { |ch| app.send(:handle_key, ch, nil) }

  def enter(cmd)
    type(cmd)
    app.key_action['send_command'].call
  end

  def mouse(bstate, y, x)
    allow(Curses).to receive(:getmouse).and_return(Struct.new(:bstate, :y, :x).new(bstate, y, x))
    app.send(:handle_key, Curses::KEY_MOUSE, nil)
  end

  # Run the real input loop for one tick with no key pressed (the command
  # window reads no key), then end it as Ctrl+C would.
  def run_input_loop_for_one_tick
    allow(IO).to receive(:select).and_return(nil)
    keys = [nil]
    cmd_window.define_singleton_method(:get_char) { keys.empty? ? raise(Interrupt) : keys.shift }
    app.send(:input_loop)
  end

  it 'starts in main, off the command line' do
    expect(cursor).to eq [main.cury, main.curx]
    expect(cursor.first).not_to eq cmd_window.begy
  end

  describe 'after a dot-command reply in main' do
    ['.tab', '.arrow', '.links', '.help', '.highlight', '.highlight goblin', '.unhighlight troll',
     '.select', '.draghl', '.tab 2', '.tab logons'].each do |cmd|
      it "is on the command line after #{cmd}" do
        enter(cmd)

        expect(cursor).to eq [cmd_window.begy, cmd_window.begx]
      end
    end

    it 'is on the command line after .key shows the key pressed' do
      cmd_window.define_singleton_method(:timeout=) { |_ms| nil }
      cmd_window.define_singleton_method(:get_char) { 'q' }

      enter('.key')

      expect(main.rows).to include('* Detected keycode: q')
      expect(cursor).to eq [cmd_window.begy, cmd_window.begx]
    end
  end

  describe 'after clicking a link' do
    it 'is at the edit position of a command line scrolled right' do
      type('x' * 30)
      3.times { app.key_action['cursor_left'].call }
      main.noutrefresh
      Curses.doupdate

      mouse(Curses::BUTTON1_CLICKED, 0, 4)

      expect(server.string).to eq "north\n"
      expect(buffer.offset).to be_positive
      expect(cursor).to eq edit_position
      expect(cursor).to eq [9, 1 + 16]
    end
  end

  describe 'after autocomplete' do
    before { %w[look loot].each { |cmd| buffer.add_to_history(cmd) } }

    it 'is at the end of the completed prefix when it lists several matches' do
      type('l')
      app.key_action['autocomplete'].call

      expect(main.rows).to include('[autocomplete:2]')
      expect(buffer.text).to eq 'loo'
      expect(cursor).to eq [9, 1 + 3]
    end

    it 'is at the edit position when there are no suggestions' do
      type('xyz')
      app.key_action['autocomplete'].call

      expect(main.rows).to include('[autocomplete] no suggestions')
      expect(cursor).to eq [9, 1 + 3]
    end
  end

  describe 'after a mouse event that redraws a selection' do
    before { (1..8).each { |n| thoughts.add_string("t#{n}") } }

    # On 'go', not the link: a double click on a link selects nothing
    it 'is on the command line after a double click selects a word' do
      type('ab')
      mouse(Curses::BUTTON1_PRESSED, 0, 1)
      mouse(Curses::BUTTON1_RELEASED, 0, 1)
      mouse(Curses::BUTTON1_PRESSED, 0, 1)

      expect(SelectionManager.multi_click_selected?).to be true
      expect(cursor).to eq [9, 1 + 2]
    end

    it 'is on the command line after a drag moves the highlight' do
      redrawn = []
      allow(SelectionManager).to receive(:drag_update).and_wrap_original do |original, *args|
        redrawn << original.call(*args)
      end
      mouse(Curses::BUTTON1_PRESSED, 1, 44)
      mouse(Curses::REPORT_MOUSE_POSITION, 3, 46)

      expect(redrawn).to eq [true]
      expect(cursor).to eq [9, 1]
    end

    it 'is on the command line after the input loop scrolls a drag held at the top edge' do
      mouse(Curses::BUTTON1_PRESSED, 4, 44)
      mouse(Curses::REPORT_MOUSE_POSITION, 0, 45)
      main.noutrefresh
      Curses.doupdate

      expect { run_input_loop_for_one_tick }.to(change { thoughts.rows })
      expect(cursor).to eq [9, 1]
    end
  end

  # The input loop's tick flushes when a countdown changes (and when a
  # drag held at an edge scrolls, above). This one already refreshed the
  # command line on main; the refresh moved into the shared flush.
  context 'with a roundtime countdown' do
    let(:layout) do
      <<~XML
        <layout>
          <window class='text' top='0' left='0' height='6' width='42' value='main'/>
          <window class='countdown' top='7' left='0' height='1' width='10' value='roundtime' label='RT'/>
          <window class='indicator' top='9' left='0' height='1' width='1' value='prompt' label='&gt;'/>
          <window class='command' top='9' left='1' height='1' width='20'/>
        </layout>
      XML
    end
    let(:countdown) { app.window_mgr.countdown['roundtime'] }
    let(:now) { Time.at(1_000_000) }

    before { allow(Time).to receive(:now).and_return(now) }

    it 'is on the command line after the input loop redraws a countdown' do
      countdown.end_time = now.to_f + 5
      type('ab')
      main.noutrefresh
      Curses.doupdate

      run_input_loop_for_one_tick

      expect(countdown.rows).to eq ["RT#{'5'.rjust(8)}"]
      expect(cursor).to eq [9, 1 + 2]
    end
  end

  describe 'after a key action' do
    # An action that changes nothing (Delete at the end of the line) still
    # flushes, and must not leave the cursor where the last flush put it.
    # switch_arrow_mode only rebinds the arrow keys; it draws nothing and
    # does not flush.
    (KeyActionRegistry.new(cmd_buffer: CommandBuffer.new, window_mgr: WindowManager.new, key_binding: {},
                           send_command: -> {}, send_history_command: ->(_) {}).actions.keys -
     %w[switch_arrow_mode]).each do |action|
      it "is at the edit position after #{action}" do
        %w[glance look].each { |cmd| buffer.add_to_history(cmd) }
        type('say hello there friend')
        main.noutrefresh
        Curses.doupdate

        app.key_action[action].call

        expect(cursor).to eq edit_position
      end
    end
  end

  it 'is at the edit position after a macro' do
    app.do_macro('say @ to you')

    expect(cursor).to eq [9, 1 + 4]
  end

  # \? moves the screen cursor, not the edit position (see
  # MacroInterpreter); that is the one place it is left elsewhere. On main
  # it showed there too, from the next input-loop poll: getch refreshes a
  # window whose cursor moved since its last refresh.
  it 'is at the \\? column after a macro with \\?, not at the edit position' do
    app.do_macro('abcde\\?')

    expect([cursor, buffer.pos]).to eq [[9, 1 + 3], 5]
  end
end
