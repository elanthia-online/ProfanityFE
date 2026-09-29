# frozen_string_literal: true

# Tests MouseController with KEY_MOUSE events on the virtual screen: link
# clicks, drag-to-select and copy, double clicks, the drag auto-scroll tick
# and the wheel. First on its own, then through Application#handle_key.

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
require_relative '../../lib/key_action_registry'
require_relative '../../lib/mouse_controller'
require_relative '../../lib/application'

RSpec.describe MouseController do
  # Mouse wheel buttons as .scrollcfg saves them.
  let(:wheel_up) { 0x10000 }
  let(:wheel_down) { 0x200000 }
  let(:copied) { [] }

  # Text wraps at 40 columns in main and 20 in thoughts (the builders keep
  # the last column for the scrollbar).
  let(:layout) do
    <<~XML
      <layout>
        <window class='text' top='0' left='0' height='4' width='42' value='main'/>
        <window class='text' top='5' left='0' height='3' width='22' value='thoughts'/>
        <window class='command' top='9' left='0' height='1' width='42'/>
      </layout>
    XML
  end

  before do
    allow(ProfanitySettings).to receive(:load_mouse_settings)
      .and_return('BUTTON4_PRESSED_MASK' => wheel_up, 'BUTTON5_PRESSED_MASK' => wheel_down)
    allow(SelectionManager).to receive(:copy_to_clipboard) { |text| copied << text }
    SelectionManager.clear_selection
    LAYOUT['mouse'] = REXML::Document.new(layout).root
  end

  after { SelectionManager.clear_selection }

  # Deliver one mouse event (button state and screen position) with #deliver.
  def mouse(bstate, y, x)
    allow(Curses).to receive(:getmouse).and_return(Struct.new(:bstate, :y, :x).new(bstate, y, x))
    deliver
  end

  def click(y, x)
    mouse(Curses::BUTTON1_PRESSED, y, x)
    mouse(Curses::BUTTON1_RELEASED, y, x)
  end

  def drag(from, to)
    mouse(Curses::BUTTON1_PRESSED, *from)
    mouse(Curses::BUTTON1_RELEASED, *to)
  end

  def reversed_columns(window, y)
    (0...window.maxx).select { |x| window.attrs_at(y, x).anybits?(Curses::A_REVERSE) }
  end

  describe 'on its own' do
    let(:window_mgr) { WindowManager.new }
    let(:shared_state) { SharedState.new.tap { |state| state.blue_links = true } }
    let(:cmd_buffer) { CommandBuffer.new }
    let(:sent) { [] }
    let(:key_action) do
      KeyActionRegistry.new(cmd_buffer: cmd_buffer, window_mgr: window_mgr, key_binding: {},
                            send_command: -> {}, send_history_command: ->(_) {}).actions
    end
    # Shows feedback in main and says whether it could, as Application does.
    let(:write_to_client) do
      wm = window_mgr
      ->(*lines) { Feedback.write(wm.stream['main'], *lines, fg: FEEDBACK_COLOR, banner: false) }
    end
    let(:controller) do
      sent = self.sent
      described_class.new(key_action: key_action, window_mgr: window_mgr, shared_state: shared_state,
                          cmd_buffer: cmd_buffer, write_to_client: write_to_client,
                          send_to_server: ->(line) { sent << line }, links: true)
    end
    let(:main) { window_mgr.stream['main'] }
    let(:thoughts) { window_mgr.stream['thoughts'] }

    def deliver = controller.handle_event

    before do
      window_mgr.load_layout('mouse')
      cmd_buffer.window = window_mgr.command_window
    end

    describe 'clicking a link' do
      before { main.add_string('go north', [{ start: 3, end: 8, cmd: 'north' }]) }

      it 'echoes the command after the prompt, adds it to the history and sends it' do
        click(0, 4)

        expect(sent).to eq ['north']
        expect(main.rows).to eq ['go north', '>north', '', '']
        expect(cmd_buffer.history.first).to eq 'north'
        expect(SelectionManager.selecting).to be_falsey
      end

      it 'sends it for a click that ncurses resolved into BUTTON1_CLICKED' do
        mouse(Curses::BUTTON1_CLICKED, 0, 5)

        expect(sent).to eq ['north']
      end

      it 'sends nothing once links are off, even for a line drawn with them on' do
        shared_state.blue_links = false

        click(0, 4)
        mouse(Curses::BUTTON1_CLICKED, 0, 4)

        expect(sent).to be_empty
        expect(main.rows).to eq ['go north', '', '', '']
        expect(cmd_buffer.history).to be_empty
      end

      it 'sends nothing for a click beside the link' do
        click(0, 1)

        expect(sent).to be_empty
      end

      # A release up to 3 columns from the press on the same row is still
      # a click; the link is the one under the press.
      describe 'with the release a few columns from the press' do
        # A second apart: no click counts as a double click
        before do
          now = 100.0
          allow(SelectionManager).to receive(:monotonic_now) { now += 1 }
        end

        it 'sends the link under the press for a release 1 to 3 columns off it' do
          (1..3).each { |dx| drag([0, 7], [0, 7 + dx]) }

          expect(sent).to eq %w[north north north]
        end

        it 'sends nothing for a press beside the link released on it' do
          drag([0, 1], [0, 3])
          drag([0, 2], [0, 5])

          expect(sent).to be_empty
        end
      end

      it 'sends nothing while .scrollcfg is learning the wheel' do
        stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
        allow(ProfanitySettings).to receive(:save_mouse_settings)
        controller.mouse_scroll.start_configuration

        click(0, 4)

        expect(sent).to be_empty
      end
    end

    describe 'selecting' do
      before { %w[alpha bravo charlie delta].each { |line| main.add_string(line) } }

      it 'copies a drag and shows how many characters were copied' do
        drag([1, 0], [2, 3])

        expect(copied).to eq ["bravo\ncha"]
        expect(main.rows).to eq ['bravo', 'charlie', 'delta', '* [copied 9 chars]']
      end

      it 'copies the word under a double click' do
        2.times { click(2, 1) }

        expect(copied).to eq ['charlie']
        expect(main.rows.last).to eq '* [copied 7 chars]'
      end

      it 'highlights the text under the pointer while button 1 is held' do
        mouse(Curses::BUTTON1_PRESSED, 1, 0)
        mouse(Curses::REPORT_MOUSE_POSITION, 1, 3)

        expect(reversed_columns(main, 1)).to eq [0, 1, 2]
        expect(copied).to be_empty
      end

      # Row 3 is the last line, 'delta'. No copy notice is shown, so the
      # rows stay as they were.
      it 'selects and copies nothing for a double click right of the text' do
        2.times { click(3, 20) }

        expect(reversed_columns(main, 3)).to be_empty
        expect(copied).to be_empty
        expect(main.rows).to eq %w[alpha bravo charlie delta]
      end

      it 'selects and copies nothing for a double click just past the last character' do
        2.times { click(3, 5) }

        expect(reversed_columns(main, 3)).to be_empty
        expect(copied).to be_empty
      end

      it 'selects and copies nothing for a double click between two words' do
        main.add_string('get the pack')

        2.times { click(3, 3) }

        expect(reversed_columns(main, 3)).to be_empty
        expect(copied).to be_empty
      end
    end

    # A double or triple click whose first click followed a link neither
    # selects nor copies, and sends nothing more. The memory of that link
    # lasts only while the presses repeat: in the same window and row, a
    # column apart at most, each within SelectionManager::MULTI_CLICK_INTERVAL
    # of the last.
    describe 'clicking again right after a click followed a link' do
      let(:clock) { [100.0] }

      before do
        allow(SelectionManager).to receive(:monotonic_now) { clock[0] }
        main.add_string('go north now', [{ start: 3, end: 12, cmd: 'north' }])
        thoughts.add_string('alpha bravo')
      end

      def later(seconds = 0.1)
        clock[0] += seconds
      end

      def reversed_text_cells
        [main, thoughts].sum { |window| (0...window.maxy).sum { |y| reversed_columns(window, y).size } }
      end

      it 'sends the link once for a double click, selecting and copying nothing' do
        click(0, 4)
        later
        click(0, 4)

        expect(sent).to eq ['north']
        expect(reversed_text_cells).to eq 0
        expect(copied).to be_empty
        expect(main.rows).to eq ['go north now', '>north', '', '']
      end

      it 'sends the link once for a triple click, selecting and copying nothing' do
        3.times do
          click(0, 5)
          later
        end

        expect(sent).to eq ['north']
        expect(reversed_text_cells).to eq 0
        expect(copied).to be_empty
      end

      it 'sends the link once for a double click on the space inside it' do
        click(0, 8)
        later
        click(0, 8)

        expect(sent).to eq ['north']
      end

      it 'sends the link again for a second click after the double-click interval' do
        click(0, 4)
        later(SelectionManager::MULTI_CLICK_INTERVAL + 0.1)
        click(0, 4)

        expect(sent).to eq %w[north north]
      end

      it 'sends the link again for a second click two columns away' do
        click(0, 4)
        later
        click(0, 6)

        expect(sent).to eq %w[north north]
      end

      it 'still copies the word under a double click on plain text right after' do
        click(0, 4)
        later
        2.times do
          click(0, 1)
          later
        end

        expect(sent).to eq ['north']
        expect(copied).to eq ['go']
      end

      it 'still copies the word under a double click in another window right after' do
        click(0, 4)
        later
        2.times do
          click(5, 8)
          later
        end

        expect(copied).to eq ['bravo']
      end

      it 'still copies the word under a double click on plain text' do
        2.times do
          click(5, 1)
          later
        end

        expect(copied).to eq ['alpha']
      end

      it 'still copies a drag that starts with a second press on the link' do
        click(0, 4)
        later
        drag([0, 4], [0, 11])

        expect(sent).to eq ['north']
        expect(copied).to eq ['orth no']
      end
    end

    # The terminal sends a press, then a release: ncurses decodes each one
    # when it's read, the release after the press was handled. Measured in
    # a PTY (ncurses 6.0 on macOS and 6.6 on Linux, X10 and SGR reports):
    # every mousemask call forgets the pressed button, so a release read
    # after one comes back as pointer motion, or not at all when the mask
    # has no motion bit.
    describe 'as ncurses reports a press and a release' do
      let(:ncurses) do
        Class.new do
          def initialize
            @mask = 0
            @held = false
          end

          def mousemask(mask)
            @mask = mask
            @held = false
          end

          # @return [Struct, nil] the event getmouse returns for a report,
          #   or nil when the mask drops it
          def read(kind, y, x)
            bstate = if kind == :press
                       @held = true
                       Curses::BUTTON1_PRESSED
                     elsif @held
                       @held = false
                       Curses::BUTTON1_RELEASED
                     else
                       Curses::REPORT_MOUSE_POSITION
                     end
            Struct.new(:bstate, :y, :x).new(bstate, y, x) if bstate.anybits?(@mask)
          end
        end.new
      end
      let(:now) { [100.0] }

      before do
        allow(Curses).to receive(:mousemask) { |mask| ncurses.mousemask(mask) }
        # A second apart: no click counts as a double click
        allow(SelectionManager).to receive(:monotonic_now) { now[0] += 1 }
        controller # turns click events on, as at startup
      end

      def deliver_reports(*reports)
        reports.each do |kind, y, x|
          next unless (event = ncurses.read(kind, y, x))

          allow(Curses).to receive(:getmouse).and_return(event)
          controller.handle_event
        end
      end

      # In thoughts (screen row 5), so the echoes in main don't move it
      it 'follows a link from a click on any of its cells' do
        thoughts.add_string('go north', [{ start: 3, end: 8, fg: '5555ff', cmd: 'north' }])

        (3...8).each { |x| deliver_reports([:press, 5, x], [:release, 5, x]) }

        expect(sent).to eq %w[north north north north north]
      end

      it 'copies a drag' do
        %w[alpha bravo charlie delta].each { |line| main.add_string(line) }

        deliver_reports([:press, 1, 0], [:release, 2, 3])

        expect(copied).to eq ["bravo\ncha"]
      end
    end

    # Main wraps 'one two three four five six seven eight nine ten' at 40
    # columns, so 'nine ten' goes on an indented continuation row. Rows 2
    # and 3 are empty.
    describe 'double clicking where a row shows no text' do
      before { main.add_string('one two three four five six seven eight nine ten') }

      it 'shows the wrapped line on two rows with two empty rows below' do
        expect(main.rows).to eq ['one two three four five six seven eight', '  nine ten', '', '']
      end

      it 'selects nothing right of the continuation row' do
        2.times { click(1, 15) }

        expect(reversed_columns(main, 1)).to be_empty
        expect(copied).to be_empty
      end

      it 'selects nothing on an empty row below the text, under a word of the last row' do
        2.times { click(2, 3) }

        expect((0...main.maxy).flat_map { |y| reversed_columns(main, y) }).to be_empty
        expect(copied).to be_empty
        expect(main.rows).to eq ['one two three four five six seven eight', '  nine ten', '', '']
      end

      it 'still copies the word under a double click on the continuation row' do
        2.times { click(1, 3) }

        expect(reversed_columns(main, 1)).to eq [2, 3, 4, 5]
        expect(copied).to eq ['nine']
      end
    end

    # A tabbed window 4 rows high: the tab bar on row 0, text below.
    context 'in a tabbed window' do
      let(:layout) do
        <<~XML
          <layout>
            <window class='tabbed' top='0' left='0' height='4' width='22' tabs='main,thoughts'/>
            <window class='command' top='9' left='0' height='1' width='22'/>
          </layout>
        XML
      end

      before { main.add_string('hello world') }

      # @return [Array<Integer>] reversed columns on every text row (the
      #   tab bar marks the active tab in reverse video)
      def reversed_text_columns
        (TabbedTextWindow::TAB_BAR_HEIGHT...main.maxy).flat_map { |y| reversed_columns(main, y) }
      end

      it 'copies the word under a double click' do
        2.times { click(1, 8) }

        expect(reversed_columns(main, 1)).to eq [6, 7, 8, 9, 10]
        expect(copied).to eq ['world']
      end

      it 'selects nothing right of the text' do
        2.times { click(1, 15) }

        expect(reversed_text_columns).to be_empty
        expect(copied).to be_empty
      end

      it 'selects nothing on an empty row below the text' do
        2.times { click(2, 3) }

        expect(reversed_text_columns).to be_empty
        expect(copied).to be_empty
      end

      it 'selects nothing on the tab bar' do
        2.times { click(0, 8) }

        expect(reversed_text_columns).to be_empty
        expect(copied).to be_empty
      end

      # Each tab fills the three text rows; the selection's line IDs name
      # rows of the tab it started in.
      describe 'switching tabs with a key' do
        before do
          %w[alpha1 alpha2 alpha3].each { |line| main.route_string(line, [], 'main') }
          %w[bravo1 bravo2 bravo3].each { |line| main.route_string(line, [], 'thoughts') }
        end

        it 'copies a drag within one tab' do
          drag([1, 0], [2, 3])

          expect(copied).to eq ["alpha1\nalp"]
        end

        it 'cancels a drag in progress: the release copies nothing and neither tab shows a highlight' do
          mouse(Curses::BUTTON1_PRESSED, 1, 0)
          mouse(Curses::REPORT_MOUSE_POSITION, 3, 3)
          key_action['next_tab'].call
          expect(main.rows.drop(1)).to eq %w[bravo1 bravo2 bravo3]

          mouse(Curses::REPORT_MOUSE_POSITION, 3, 5)
          mouse(Curses::BUTTON1_RELEASED, 3, 6)

          expect(copied).to be_empty
          expect(SelectionManager.selecting).to be_falsey
          expect(main.rows.drop(1)).to eq %w[bravo1 bravo2 bravo3]
          expect(reversed_text_columns).to be_empty

          key_action['prev_tab'].call
          expect(main.rows.drop(1)).to eq %w[alpha1 alpha2 alpha3]
          expect(reversed_text_columns).to be_empty
        end

        it 'copies nothing for a release right after the switch' do
          mouse(Curses::BUTTON1_PRESSED, 1, 0)
          key_action['next_tab'].call
          mouse(Curses::BUTTON1_RELEASED, 3, 6)

          expect(copied).to be_empty
          expect(reversed_text_columns).to be_empty
        end

        # The copy notice scrolls alpha1 off, leaving 'alp' of alpha2 lit.
        it 'drops a finished highlight, which stays gone on switching back' do
          drag([1, 0], [2, 3])
          expect(main.rows.drop(1)).to eq %w[alpha2 alpha3] + ['* [copied 10 chars]']
          expect(reversed_text_columns).to eq [0, 1, 2]

          key_action['next_tab'].call
          expect(reversed_text_columns).to be_empty
          key_action['prev_tab'].call

          expect(main.rows.drop(1)).to eq %w[alpha2 alpha3] + ['* [copied 10 chars]']
          expect(reversed_text_columns).to be_empty
        end

        it 'copies a drag started in the tab switched to' do
          mouse(Curses::BUTTON1_PRESSED, 1, 0)
          key_action['next_tab'].call
          drag([2, 0], [3, 3])

          expect(copied).to eq ["bravo2\nbra"]
        end
      end
    end

    # A room window 3 rows high below the command line, showing a room that
    # needs 4 rows (description 3, exits 1).
    context 'in a room window too short for the room' do
      let(:layout) do
        <<~XML
          <layout>
            <window class='text' top='0' left='0' height='4' width='42' value='main'/>
            <window class='command' top='9' left='0' height='1' width='42'/>
            <window class='room' top='10' left='0' height='3' width='10'/>
          </layout>
        XML
      end
      let(:window_mgr) { WindowManager.new(shared_state: shared_state) }
      let(:room) { window_mgr.room['room'] }

      before do
        room.update_desc('abcdefghij klmnopqrst e', links: [{ start: 22, end: 23, cmd: 'look e' }])
        room.update_exits('Go: north.', links: [{ start: 4, end: 9, cmd: 'north' }])
      end

      it 'sends, for a click on each cell of the bottom row, the link shown there' do
        # A second apart: no click counts as a double click
        now = 100.0
        allow(SelectionManager).to receive(:monotonic_now) { now += 1 }
        cells = (0...10).map do |x|
          sent.clear
          click(12, x)
          [room.rows[2][x] || ' ', sent.dup]
        end

        expect(cells).to eq [['G', []], ['o', []], [':', []], [' ', []]] +
                            'north'.chars.map { |c| [c, ['north']] } + [['.', []]]
      end

      it 'sends a link once for a double click' do
        now = 100.0
        allow(SelectionManager).to receive(:monotonic_now) { now += 0.1 }

        2.times { click(12, 6) }

        expect(sent).to eq ['north']
      end

      it 'sends the link under the press, not the one under the release' do
        now = 100.0
        allow(SelectionManager).to receive(:monotonic_now) { now += 1 }

        drag([12, 8], [12, 9])
        expect(sent).to eq ['north']

        sent.clear
        drag([12, 2], [12, 4])
        expect(sent).to be_empty
      end
    end

    describe 'pressing outside every window' do
      before { %w[alpha bravo charlie delta].each { |line| main.add_string(line) } }

      it 'drops the selection at a press outside every window' do
        mouse(Curses::BUTTON1_PRESSED, 1, 0)
        mouse(Curses::BUTTON1_PRESSED, 20, 60)
        mouse(Curses::BUTTON1_RELEASED, 20, 60)

        expect(SelectionManager.selecting).to be_falsey
        expect(copied).to be_empty
      end
    end

    describe 'the drag auto-scroll tick' do
      before { (1..8).each { |n| thoughts.add_string("t#{n}") } }

      # The selection runs from the press (t7, column 0) to the pointer on
      # the top row (column 1), which ends on t4 after two ticks.
      it 'scrolls up a line per tick while the drag is held on the top row, and extends the selection' do
        mouse(Curses::BUTTON1_PRESSED, 6, 0)
        mouse(Curses::REPORT_MOUSE_POSITION, 5, 1)
        expect(thoughts.rows).to eq %w[t6 t7 t8]

        expect(controller.tick_drag_auto_scroll).to be true
        expect(thoughts.rows).to eq %w[t5 t6 t7]
        expect(controller.tick_drag_auto_scroll).to be true
        expect(thoughts.rows).to eq %w[t4 t5 t6]
        expect(reversed_columns(thoughts, 0)).to eq [1]

        mouse(Curses::BUTTON1_RELEASED, 5, 1)
        expect(copied).to eq ["4\nt5\nt6\n"]
      end

      it 'does nothing without a drag in progress' do
        expect(controller.tick_drag_auto_scroll).to be false
        expect(thoughts.rows).to eq %w[t6 t7 t8]
      end
    end

    it 'scrolls the current window a line per wheel step, wherever the pointer is' do
      %w[l1 l2 l3 l4 l5 l6].each { |line| main.add_string(line) }

      mouse(wheel_up, 6, 3)
      mouse(wheel_up, 0, 0)
      expect(main.rows).to eq %w[l1 l2 l3 l4]

      mouse(wheel_down, 30, 70)
      expect(main.rows).to eq %w[l2 l3 l4 l5]
    end

    it 'ignores a KEY_MOUSE with no event to read' do
      allow(Curses).to receive(:getmouse).and_return(nil)

      expect { controller.handle_event }.not_to(change { [main.rows, sent, SelectionManager.selecting] })
    end
  end

  describe 'through Application#handle_key' do
    let(:server) { StringIO.new }
    let(:app) do
      Application.new({ char: nil, no_status: true, links: true, room_window_only: false },
                      settings_file: File.join(SPEC_HOME, 'settings.xml'), host: '127.0.0.1', port: 8000)
    end
    let(:main) { app.window_mgr.stream['main'] }

    def deliver = app.send(:handle_key, Curses::KEY_MOUSE, nil)

    before do
      app.window_mgr.load_layout('mouse')
      app.cmd_buffer.window = app.window_mgr.command_window
      app.connection.attach(server)
      main.add_string('go north', [{ start: 3, end: 8, cmd: 'north' }])
    end

    it 'sends a clicked link to the game server with --links' do
      click(0, 4)

      expect(server.string).to eq "north\n"
      expect(main.rows).to eq ['go north', '>north', '', '']
    end

    it 'stops sending links after .links turns them off' do
      app.execute_command('.links')
      click(0, 4)

      expect(server.string).to eq ''
    end

    it 'keeps a pending key combo across a mouse event' do
      allow(Curses).to receive(:getmouse).and_return(Struct.new(:bstate, :y, :x).new(Curses::BUTTON1_CLICKED, 0, 4))
      combo = { '1' => proc {} }

      expect(app.send(:handle_key, Curses::KEY_MOUSE, combo)).to be combo
      expect(server.string).to eq "north\n"
    end

    it 'copies a drag and shows the notice in main' do
      main.add_string('alpha bravo')

      drag([1, 0], [1, 5])

      expect(copied).to eq ['alpha']
      expect(main.rows).to eq ['go north', 'alpha bravo', '* [copied 5 chars]', '']
    end

    # .layout closes the windows the new layout drops; any curses call on
    # a closed window raises "already closed window". A selection left
    # pointing at one broke the drag auto-scroll tick, and the next
    # press's clear_selection.
    describe 'after a .layout that drops the window of a selection' do
      let(:thoughts) { app.window_mgr.stream['thoughts'] }

      before do
        LAYOUT['main only'] = REXML::Document.new(<<~XML).root
          <layout>
            <window class='text' top='0' left='0' height='4' width='42' value='main'/>
            <window class='command' top='9' left='0' height='1' width='42'/>
          </layout>
        XML
        (1..8).each { |n| thoughts.add_string("t#{n}") }
      end

      # How many times the input loop read a key from the command window.
      let(:key_reads) { [0] }

      # Runs the real input loop for two ticks with no key pressed (the
      # command window reads no key), then ends it as Ctrl+C would. An
      # error raised in the loop is logged and ends it (and the client) at
      # once, before the second read.
      def run_input_loop_for_two_ticks
        allow(IO).to receive(:select).and_return(nil)
        reads = key_reads
        app.cmd_buffer.window.define_singleton_method(:get_char) do
          reads[0] += 1
          reads[0] == 1 ? nil : raise(Interrupt)
        end
        app.send(:input_loop)
      end

      it 'ends a drag held at the edge of that window, and the input loop keeps running' do
        logged = []
        allow(ProfanityLog).to receive(:write) { |source, message, **| logged << [source, message] }
        mouse(Curses::BUTTON1_PRESSED, 6, 0)
        mouse(Curses::REPORT_MOUSE_POSITION, 5, 1)

        app.execute_command('.layout main only')
        run_input_loop_for_two_ticks

        expect(logged.select { |source, _| source == 'main' }).to eq []
        expect(key_reads.first).to eq 2
        expect(SelectionManager.selecting).to be false
      end

      it 'forgets the selection kept there, so a drag in another window still copies' do
        drag([6, 0], [7, 1])
        expect(copied).to eq ["t7\nt"]

        app.execute_command('.layout main only')
        drag([0, 0], [0, 5])

        expect(copied).to eq ["t7\nt", 'go no']
      end
    end
  end
end
