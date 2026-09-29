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
        expect(cmd_buffer.history[1]).to eq 'north'
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
        expect(cmd_buffer.history[1]).to be_nil
      end

      it 'sends nothing for a click beside the link' do
        click(0, 1)

        expect(sent).to be_empty
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
  end
end
