# frozen_string_literal: true

# Tests that a window whose place is off the screen when the layout loads
# is built once the terminal grows enough to show it, by a terminal resize
# or .resize, as it would have been had the layout loaded at that size:
# the streams, keys and tabs it serves, its place in the switch-window
# order, and the blank lines a text window starts with. Windows that still
# don't fit stay unbuilt, a window built this way behaves like one built
# at load when the terminal shrinks again, and switching layouts forgets
# the previous layout's unbuilt windows.
#
# Driven through the real Application (settings from the bundled
# templates, the startup layout sequence, .resize, .layout, a burst of
# KEY_RESIZE in the input loop) on the virtual screen, with real lines
# from Lich XML session logs fed through the real server loop.

require 'rexml/document'
require 'tmpdir'
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
require_relative '../../lib/application'
require_relative '../support/client_run'

RSpec.describe 'Windows off the screen when the layout loads' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:terminal) { { lines: 24, cols: 80 } }

  # GemStone (GSF-Tysong 2026-10-02_01-49-40, lines 12-21, the room
  # description cut after its first sentence): a room change, pushed on
  # the room stream and then shown inline on main.
  let(:gs_room) do
    [
      "<nav rm='4216017'/><streamWindow id='main' title='Story' subtitle=\" - Sanctum of Scales, Columns - 4216017\" " \
      "location='center' target='drop'/><streamWindow id='room' title='Room' subtitle=\" - Sanctum of Scales, Columns " \
      "- 4216017\" location='center' target='drop' ifClosed='' resident='true'/><clearStream id='room'/>" \
      "<pushStream id='room'/><compDef id='room desc'>A huge copper-paneled sandstone wall stretches from east to " \
      "west along the northern edge of the antechamber.</compDef><compDef id='room objs'></compDef>",
      "<compDef id='room players'></compDef>",
      "<compDef id='room exits'>Obvious exits: <d>north</d>, <d>east</d>, <d>west</d></compDef>",
      "<compDef id='sprite'></compDef><popStream id='room'/>",
      '<roommeta weather="0" bonfire="0" inside="1" water="0" sanctuary="0" realm="57" climate="12" terrain="1"/>',
      "<component id='room players'></component>",
      '<resource picture="0"/><style id="roomName" />[Sanctum of Scales, Columns] (4216017)',
      '<style id=""/><style id="roomDesc"/>A huge copper-paneled sandstone wall stretches from east to west along ' \
      'the northern edge of the antechamber.<style id=""/>',
      'Obvious exits: <a exist="-11223064" coord="2524,1864" noun="north">north</a>, <a exist="-11223064" ' \
      'coord="2524,1864" noun="east">east</a>, <a exist="-11223064" coord="2524,1864" noun="west">west</a>',
      '<compass><dir value="n"/><dir value="e"/><dir value="w"/></compass><prompt time="1790920180">&gt;</prompt>'
    ]
  end

  # GemStone speech (GSF-Tysong 2026-10-02_01-49-40, lines 16703-16704).
  let(:gs_speech) do
    [
      '<pushStream id="speech"/><preset id=\'speech\'>Speaking to <a exist="-11189869" noun="Butch">Butch</a>, ' \
      '<a exist="-11165808" noun="Nexushealbot">Nexushealbot</a> exclaims</preset>, "You are healed!"',
      '<popStream/>'
    ]
  end
  let(:gs_speech_text) { 'Speaking to Butch, Nexushealbot exclaims, "You are healed!"' }

  # GemStone thoughts (GSIV-Ilten 2026-10-02_08-14-14, lines 263-264).
  let(:gs_thought) do
    [
      '<pushStream id="thoughts"/>[General] <a exist="-11234735" noun="Pakkan">Pakkan</a> thinks, "Not the Affle Waffle."',
      '<popStream/><prompt time="1790943456">s&gt;</prompt>'
    ]
  end
  let(:gs_thought_text) { '[General] Pakkan thinks, "Not the Affle Waffle."' }

  # DragonRealms (Nelis, 2026-08-27 16:45:15, the diagnosis cut to its
  # first wound): a familiar's report on the familiar stream.
  let(:dr_familiar) do
    [
      '<pushStream id="familiar" /><pushStream id="familiar" ifClosedStyle="watching"/>',
      "Tenuk's injuries include...",
      'Wounds to the ABDOMEN:',
      '  Fresh External:  light scratches -- insignificant',
      '<popStream/><popStream/><prompt time="1787805915">&gt;</prompt>'
    ]
  end

  # DragonRealms (Quilsilgas, 2026-08-06 14:20:45): an LNet server message
  # on the thoughts stream.
  let(:dr_thought) { ['<pushStream id="thoughts"/>[server]: "no such channel or user"', '<popStream/>'] }

  # DragonRealms (2026-08-27 16:27:25): the health bar.
  let(:dr_health) do
    ["<dialogData id='minivitals'><skin id='healthSkin' name='healthBar' controls='health' left='0%' top='0%' " \
     "width='20%' height='100%'/><progressBar id='health' value='97' text='health 97%' left='0%' customText='t' " \
     "top='0%' width='20%' height='100%'/></dialogData>"]
  end

  def new_app
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end

  def template(name) = File.read(File.expand_path("../../templates/#{name}.xml", __dir__))

  # Start the client's display with +settings+ (XML) on a terminal of
  # +lines+ x +cols+: the settings and the default layout, as at startup.
  def start(settings, lines, cols)
    File.write(settings_path, settings)
    terminal.merge!(lines: lines, cols: cols)
    app.send(:load_settings_and_layout)
  end

  # The terminal becomes +lines+ x +cols+ and ncurses reports it.
  def terminal_resize(lines, cols)
    terminal.merge!(lines: lines, cols: cols)
    app.send(:handle_key, Curses::KEY_RESIZE, nil)
  end

  # The terminal becomes +lines+ x +cols+ and the user types .resize.
  def dot_resize(lines, cols)
    terminal.merge!(lines: lines, cols: cols)
    app.execute_command('.resize')
  end

  # Feed raw server lines through the real server loop into the app's
  # windows, as the server thread does (one processor per app). The loop
  # logs and skips a line that raises, so any error it logs fails the
  # example.
  def receive_from_server(*lines, game: 'GS')
    @processors ||= {}.compare_by_identity
    processor = @processors[app] ||= begin
      event_bus = EventBus.new
      wm.subscribe_to_events(event_bus)
      GameTextProcessor.new(
        window_mgr: wm, shared_state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
        cmd_buffer: app.cmd_buffer, event_bus: event_bus, game_rules: Games.rules_for(game),
        xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' }
      )
    end
    queue = lines.flatten.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    # The first prompt sends LOOK.
    server.define_singleton_method(:puts) { |_command| nil }
    server.define_singleton_method(:flush) { self }
    logged = []
    allow(ProfanityLog).to receive(:write) { |context, message, **| logged << message if context == 'game_text_processor' }
    processor.run(server)
    expect(logged).to be_empty, "the server loop logged #{logged.size}: #{logged.first}"
  end

  # Forget every window and setting, as between examples, and make a new
  # client, to compare against a client started another way.
  def restart_client
    CONFIG.reset!
    BaseWindow.window_classes.each { |klass| klass.list.clear }
    Curses::TerminalCursor.reset
    @app = new_app
  end

  # The client; {#restart_client} replaces it.
  def app = (@app ||= new_app)

  def wm = app.window_mgr

  def geometry(window) = [window.begy, window.begx, window.maxy, window.maxx]

  # What a user can see of a window and what decides where game data goes:
  # its class, place and size, what it shows, and its scrollbar.
  def describe(window)
    shown = [window.class.name, *geometry(window), window.rows]
    shown << window.scrollbar.rows if window.respond_to?(:scrollbar) && window.scrollbar
    shown
  end

  def place_of(window) = window.is_a?(SinkWindow) ? :sink : [window.class.name, *geometry(window)]

  # The switch-window (Tab) cycle, from its first window in screen order.
  def tab_cycle
    places = SCROLL_WINDOW.map { |window| place_of(window) }
    places.rotate(places.index(places.min) || 0)
  end

  # The order a resize draws the windows in (where windows overlap, the
  # one drawn last shows), which is also the order a click finds them in.
  def draw_order
    BaseWindow.window_classes_in_resize_order.flat_map { |klass| klass.list.map { |window| place_of(window) } }
  end

  # Everything the layout decides, for comparing two clients: every
  # window as shown and the order they are drawn in, which window each
  # stream and value goes to, the Tab cycle and the current window, and
  # the command line.
  def layout_state
    {
      windows: BaseWindow.all_windows.map { |window| describe(window) }.sort_by(&:inspect),
      draw_order: draw_order,
      keys: LayoutLoader::REGISTRIES.to_h do |registry|
        [registry, wm.public_send(registry).transform_values { |window| place_of(window) }]
      end,
      tab_cycle: tab_cycle,
      current: SCROLL_WINDOW[0] && place_of(SCROLL_WINDOW[0]),
      command: geometry(wm.command_window)
    }
  end

  def text_of(window) = window.rows.reject(&:empty?)

  def built?(window) = BaseWindow.all_windows.any? { |built| built.equal?(window) }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    allow(Curses).to receive(:lines) { terminal[:lines] }
    allow(Curses).to receive(:cols) { terminal[:cols] }
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    allow(IO).to receive(:select).and_return(nil)
  end

  # tysong.xml is tuned for a maximized ~234x55 terminal: the room and
  # speech windows sit at column 161, the lnet window at column 81.
  describe 'tysong.xml started at 24x80' do
    before { start(template('tysong'), 24, 80) }

    it 'builds no room, speech or lnet window at load' do
      expect(wm.room).to be_empty
      expect(wm.stream.keys).not_to include('speech', 'lnet', 'thoughts', 'voln')
      expect(RoomWindow.list).to be_empty
    end

    it 'builds them when the terminal grows to 55x234, where the layout puts them' do
      terminal_resize(55, 234)

      expect(geometry(wm.room['room'])).to eq [0, 161, 20, 72]
      # Text windows leave their layout's last column to the scrollbar.
      expect(geometry(wm.stream['speech'])).to eq [21, 161, 30, 72]
      expect(%w[lnet thoughts voln].map { |stream| geometry(wm.stream[stream]) }).to eq [[1, 81, 12, 79]] * 3
      expect(wm.stream['lnet']).to be wm.stream['thoughts']
    end

    it 'builds them on .resize too' do
      dot_resize(55, 234)

      expect(wm.room['room']).to be_a RoomWindow
      expect(wm.stream['speech']).to be_a TextWindow
      expect(wm.stream['lnet']).to be_a TextWindow
    end

    it 'shows the next room, speech and thoughts in them (real GS lines)' do
      terminal_resize(55, 234)

      receive_from_server(gs_room, gs_speech, gs_thought)

      expect(text_of(wm.room['room'])).to eq [
        '[Sanctum of Scales, Columns] (4216017)',
        'A huge copper-paneled sandstone wall stretches from east to west along',
        'the northern edge of the antechamber.',
        'Obvious exits: north, east, west'
      ]
      expect(text_of(wm.stream['speech'])).to eq [gs_speech_text]
      expect(text_of(wm.stream['thoughts'])).to eq [gs_thought_text]
      expect(text_of(wm.stream['main'])).not_to include(gs_speech_text, gs_thought_text)
    end

    it 'leaves the thoughts that came before the grow on main, where they went' do
      receive_from_server(gs_thought)

      terminal_resize(55, 234)
      receive_from_server(gs_thought)

      expect(text_of(wm.stream['main'])).to eq [gs_thought_text, 's>']
      expect(text_of(wm.stream['thoughts'])).to eq [gs_thought_text]
    end

    it 'ends up as the same layout as a client started at 55x234, with the same lines after it' do
      terminal_resize(55, 234)
      receive_from_server(gs_room, gs_speech, gs_thought)
      grown = layout_state

      restart_client
      start(template('tysong'), 55, 234)
      receive_from_server(gs_room, gs_speech, gs_thought)

      expect(grown).to eq layout_state
    end

    it 'puts the new text windows in the Tab cycle where the layout lists them, keeping the current window' do
      main = wm.stream['main']
      expect(tab_cycle.map(&:first)).to eq %w[TextWindow] * 4

      terminal_resize(55, 234)

      # tysong lists main, speech, familiar, lnet, death, logons.
      expect(SCROLL_WINDOW.map { |window| geometry(window) })
        .to eq [[14, 20, 37, 139], [21, 161, 30, 72], [1, 0, 12, 79], [1, 81, 12, 79], [14, 0, 7, 18], [22, 0, 8, 18]]
      expect(SCROLL_WINDOW[0]).to be main
      expect(main.active?).to be true
      expect(wm.stream['speech'].active?).to be_falsey
    end

    it 'keeps the Tab cycle in layout order after Tab moved the current window' do
      app.key_action.fetch('switch_current_window').call
      familiar = wm.stream['familiar']
      expect(SCROLL_WINDOW[0]).to be familiar

      terminal_resize(55, 234)

      expect(SCROLL_WINDOW[0]).to be familiar
      expect(SCROLL_WINDOW.map { |window| geometry(window).first(2) })
        .to eq [[1, 0], [1, 81], [14, 0], [22, 0], [14, 20], [21, 161]]
    end

    it 'builds only what fits at an in-between size, and the rest when the terminal grows again' do
      terminal_resize(30, 162)

      # Column 161 fits in 162 columns; the injury figure fits in 30 lines.
      expect(wm.room['room']).to be_a RoomWindow
      expect(wm.stream['lnet']).to be_a TextWindow

      restart_client
      start(template('tysong'), 24, 120)
      terminal_resize(24, 161)
      expect(wm.room).to be_empty
      expect(wm.stream['speech']).to be_nil
      expect(wm.stream['lnet']).to be_a TextWindow

      terminal_resize(24, 162)
      expect(wm.room['room']).to be_a RoomWindow
      expect(wm.stream['speech']).to be_a TextWindow
    end

    it 'builds each window once, however often the terminal grows' do
      terminal_resize(55, 234)
      windows = BaseWindow.all_windows.map(&:object_id)

      terminal_resize(60, 240)
      app.execute_command('.resize')

      expect(BaseWindow.all_windows.map(&:object_id)).to match_array windows
      expect(RoomWindow.list.size).to eq 1
    end

    it 'leaves a window built this way where it was when the terminal shrinks again, as one built at load' do
      terminal_resize(55, 234)
      speech = wm.stream['speech']
      room = wm.room['room']

      terminal_resize(24, 80)

      expect(wm.stream['speech']).to be speech
      expect(built?(speech)).to be true
      expect(geometry(speech)).to eq [21, 161, 30, 72]
      expect(geometry(room)).to eq [0, 161, 20, 72]

      terminal_resize(55, 234)
      receive_from_server(gs_speech)
      expect(wm.stream['speech']).to be speech
      expect(text_of(speech)).to eq [gs_speech_text]
    end

    it 'builds nothing while the terminal is too small to resize' do
      terminal_resize(2, 234)

      expect(wm.room).to be_empty
      expect(wm.stream['speech']).to be_nil
    end

    it 'forgets the windows it could not build when another layout loads' do
      LAYOUT['narrow'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='20' width='80' value='main'/>
          <window class='text' top='0' left='100' height='10' width='40' value='voln'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
      XML
      app.execute_command('.layout narrow')

      terminal_resize(55, 234)

      expect(wm.room).to be_empty
      expect(wm.stream.keys).to contain_exactly('main', 'voln')
      expect(geometry(wm.stream['voln'])).to eq [0, 100, 10, 39]
    end

    it 'builds the windows of the reloaded layout that did not fit (.layout default)' do
      app.execute_command('.layout default')
      expect(wm.room).to be_empty

      terminal_resize(55, 234)

      expect(wm.room['room']).to be_a RoomWindow
      expect(wm.stream['speech']).to be_a TextWindow
    end
  end

  describe 'tysong.xml started at 20x80' do
    before { start(template('tysong'), 20, 80) }

    # The injury figure's top rows sit at lines-23..lines-21, above the
    # top row on a 20-line terminal.
    it 'builds the injury indicators when the terminal gets taller, with their labels' do
      expect(wm.indicator.keys).not_to include('leftEye', 'head', 'chest')
      expect(wm.indicator['leftLeg'].rows).to eq [' /', 'o']

      terminal_resize(24, 80)

      expect(geometry(wm.indicator['leftEye'])).to eq [1, 1, 1, 1]
      expect(wm.indicator['head'].rows).to eq ['O']
      expect(wm.indicator['chest'].rows).to eq ['|']
    end
  end

  # tysong.xml's main and death windows start on row 14: on a 14-line
  # terminal familiar is the only text window, and the current one.
  describe 'tysong.xml started at 14x80' do
    before { start(template('tysong'), 14, 80) }

    it 'makes main the current window once it is built, as a client started large has it' do
      familiar = wm.stream['familiar']
      expect(wm.stream['main']).to be_nil
      expect(SCROLL_WINDOW).to eq [familiar]

      terminal_resize(55, 234)
      main = wm.stream['main']

      expect(SCROLL_WINDOW[0]).to be main
      expect([main.active?, familiar.active?]).to eq [true, false]
      expect(main.scrollbar.rows.first).to eq LineBuffered::ACTIVE_INDICATOR
      expect(familiar.scrollbar.rows).to eq [''] * 12
    end

    it 'keeps familiar current while only windows listed after it are built' do
      familiar = wm.stream['familiar']

      # lnet (column 81) is listed after familiar; main is still too low.
      terminal_resize(14, 161)
      expect(wm.stream['lnet']).to be_a TextWindow
      expect(SCROLL_WINDOW[0]).to be familiar

      terminal_resize(15, 161)
      expect(SCROLL_WINDOW[0]).to be wm.stream['main']
      expect(familiar.active?).to be false
    end

    it 'ends up as the same layout as a client started at 55x234, with the same lines after it' do
      terminal_resize(55, 234)
      receive_from_server(gs_room, gs_speech, gs_thought)
      grown = layout_state

      restart_client
      start(template('tysong'), 55, 234)
      receive_from_server(gs_room, gs_speech, gs_thought)

      expect(grown).to eq layout_state
    end

    # Tab with familiar alone in the cycle changes nothing on the screen.
    it 'keeps familiar current once Tab was pressed' do
      familiar = wm.stream['familiar']
      app.key_action.fetch('switch_current_window').call

      terminal_resize(15, 80)

      expect(SCROLL_WINDOW[0]).to be familiar
      expect(TextWindow.list.select(&:active?)).to eq [familiar]
    end

    it 'keeps familiar current after Tab and a .layout that keeps it current' do
      familiar = wm.stream['familiar']
      app.key_action.fetch('switch_current_window').call
      app.execute_command('.layout default')
      expect(wm.stream['familiar']).to be familiar

      terminal_resize(55, 234)

      expect(TextWindow.list.select(&:active?)).to eq [familiar]
    end

    it 'makes main current after a .layout with no Tab, as a client started large has it' do
      app.execute_command('.layout default')

      terminal_resize(55, 234)

      expect(SCROLL_WINDOW[0]).to be wm.stream['main']
      expect(TextWindow.list.select(&:active?)).to eq [wm.stream['main']]
    end
  end

  # mahtra.xml at 24x80: the conversation and familiar windows (rows 33
  # and 39), the room players indicator, the vitals bars (columns
  # 105-121) and the moon window (column 125) are off the screen.
  describe 'mahtra.xml started at 24x80' do
    # The conversation and familiar windows add [HH:MM] timestamps.
    let(:stamp) { ' [16:29]' }

    before do
      allow(Time).to receive(:now).and_return(Time.new(2026, 8, 27, 16, 29, 0))
      start(template('mahtra'), 24, 80)
    end

    it 'builds them when the terminal grows, and the next lines reach them (real DR lines)' do
      expect(wm.stream.keys).not_to include('familiar', 'thoughts', 'moonWindow')
      expect(wm.progress).to be_empty

      terminal_resize(60, 200)
      receive_from_server(dr_familiar, dr_thought, dr_health, game: 'DR')

      expect(text_of(wm.stream['familiar'])).to eq [
        "Tenuk's injuries include...#{stamp}", "Wounds to the ABDOMEN:#{stamp}",
        "  Fresh External:  light scratches -- insignificant#{stamp}"
      ]
      expect(text_of(wm.stream['thoughts'])).to eq [%([server]: "no such channel or user"#{stamp})]
      expect(wm.progress['health'].rows).to eq [' 97']
      expect(wm.progress.keys).to eq %w[health mana stamina concentration spirit]
      expect(geometry(wm.indicator['room players'])).to eq [58, 105, 1, 95]
    end

    it 'ends up as the same layout as a client started at 60x200, with the same lines after it' do
      terminal_resize(60, 200)
      receive_from_server(dr_familiar, dr_thought, dr_health, game: 'DR')
      grown = layout_state

      restart_client
      start(template('mahtra'), 60, 200)
      receive_from_server(dr_familiar, dr_thought, dr_health, game: 'DR')

      expect(grown).to eq layout_state
    end

    it 'keeps death the current window and lists the new windows in layout order' do
      death = wm.stream['death']
      expect(SCROLL_WINDOW[0]).to be death

      terminal_resize(60, 200)

      expect(SCROLL_WINDOW[0]).to be death
      expect(SCROLL_WINDOW.map { |window| geometry(window).first(2) }).to eq [[0, 133], [33, 133], [39, 133], [0, 0], [59, 125]]
    end
  end

  describe 'keys two windows of a layout share' do
    def start_with(windows)
      start("<settings><layout id='default'>#{windows}" \
            "<window class='command' top='23' left='0' height='1' width='80'/></layout></settings>", 24, 80)
    end

    it 'goes to the later window when the earlier one is built late, as at load' do
      start_with(<<~XML)
        <window class='text' top='0' left='100' height='5' width='40' value='thoughts,voln'/>
        <window class='text' top='5' left='0' height='5' width='40' value='thoughts'/>
      XML
      later = wm.stream['thoughts']

      terminal_resize(24, 160)

      earlier = TextWindow.list.find { |window| window.begx == 100 }
      expect(earlier).to be_a TextWindow
      expect(wm.stream['thoughts']).to be later
      expect(wm.stream['voln']).to be earlier
    end

    it 'goes to the window built late when it is the later one, as at load' do
      start_with(<<~XML)
        <window class='text' top='5' left='0' height='5' width='40' value='thoughts'/>
        <window class='tabbed' top='0' left='100' height='5' width='40' tabs='thoughts,voln'/>
      XML

      terminal_resize(24, 160)

      expect(wm.stream['thoughts']).to be_a TabbedTextWindow
      expect(wm.stream['voln']).to be wm.stream['thoughts']
    end

    it 'goes to the latest window built late when two late windows share it' do
      start_with(<<~XML)
        <window class='indicator' top='0' left='90' height='1' width='5' value='kneeling' label='A'/>
        <window class='indicator' top='0' left='100' height='1' width='5' value='kneeling' label='B'/>
      XML

      terminal_resize(24, 95)
      expect(wm.indicator['kneeling'].rows).to eq ['A']

      terminal_resize(24, 120)
      expect(wm.indicator['kneeling'].rows).to eq ['B']
    end

    it 'draws a window built late before the windows of its class the layout lists after it, as at load' do
      start_with(<<~XML)
        <window class='text' top='0' left='85' height='5' width='20' value='thoughts'/>
        <window class='text' top='0' left='0' height='5' width='100' value='main'/>
        <window class='text' top='6' left='90' height='5' width='20' value='voln'/>
      XML

      terminal_resize(24, 120)

      # main overlaps thoughts (columns 85-98) and is drawn after it, so it
      # shows there; a click there finds thoughts first, as at load.
      expect(TextWindow.list.map { |window| geometry(window).first(2) }).to eq [[0, 85], [0, 0], [6, 90]]
      expect(BaseWindow.find_window_at(2, 90)).to be wm.stream['thoughts']
    end

    it 'stays with a sink listed later' do
      start_with(<<~XML)
        <window class='text' top='0' left='100' height='5' width='40' value='atmospherics,voln'/>
        <window class='sink' value='atmospherics'/>
      XML

      terminal_resize(24, 160)

      expect(wm.stream['atmospherics']).to be_a SinkWindow
      expect(wm.stream['voln']).to be_a TextWindow
    end
  end

  # A layout whose first text window, speech, is off an 80-column
  # terminal: built late, it comes before every window in the Tab cycle.
  describe 'a text window built late that the layout lists before the whole Tab cycle' do
    let(:layout) do
      "<settings><layout id='default'>" \
        "<window class='text' top='0' left='100' height='5' width='30' value='speech'/>" \
        "<window class='text' top='0' left='0' height='5' width='40' value='main'/>" \
        "<window class='text' top='6' left='0' height='5' width='40' value='familiar'/>" \
        "<window class='text' top='12' left='0' height='5' width='40' value='thoughts'/>" \
        "<window class='command' top='lines-1' left='0' height='1' width='cols'/></layout></settings>"
    end

    def cycle = SCROLL_WINDOW.map { |window| wm.stream.key(window) }

    def press_tab(times) = times.times { app.key_action.fetch('switch_current_window').call }

    before { start(layout, 24, 80) }

    it 'goes first in the cycle and becomes the current window when Tab was never pressed, as at load' do
      expect(cycle).to eq %w[main familiar thoughts]

      terminal_resize(24, 200)

      expect(cycle).to eq %w[speech main familiar thoughts]
      expect(TextWindow.list.select(&:active?)).to eq [wm.stream['speech']]
    end

    it 'goes last in the cycle after Tab moved the current window, which stays current' do
      press_tab(1)

      terminal_resize(24, 200)

      # At load, the cycle is speech, main, familiar, thoughts.
      expect(cycle).to eq %w[familiar thoughts speech main]
      expect(TextWindow.list.select(&:active?)).to eq [wm.stream['familiar']]
    end

    it 'becomes the current window after a .layout closed the window Tab chose' do
      press_tab(1)
      LAYOUT['nofamiliar'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='100' height='5' width='30' value='speech'/>
          <window class='text' top='12' left='0' height='5' width='40' value='thoughts'/>
          <window class='text' top='0' left='0' height='5' width='40' value='main'/>
          <window class='command' top='lines-1' left='0' height='1' width='cols'/>
        </layout>
      XML
      app.execute_command('.layout nofamiliar')
      expect(cycle).to eq %w[thoughts main]

      terminal_resize(24, 200)

      expect(cycle).to eq %w[speech thoughts main]
      expect(TextWindow.list.select(&:active?)).to eq [wm.stream['speech']]
    end

    # A .layout keeps the reused windows in the order they had in the
    # cycle, so main, current before, stays current, as at load.
    it 'leaves the current window current after a .layout that lists another window first' do
      LAYOUT['thoughtsfirst'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='100' height='5' width='30' value='speech'/>
          <window class='text' top='12' left='0' height='5' width='40' value='thoughts'/>
          <window class='text' top='0' left='0' height='5' width='40' value='main'/>
          <window class='command' top='lines-1' left='0' height='1' width='cols'/>
        </layout>
      XML
      app.execute_command('.layout thoughtsfirst')
      expect(cycle).to eq %w[main thoughts]

      terminal_resize(24, 200)

      # speech comes after main, the window the layout lists last.
      expect(cycle).to eq %w[main speech thoughts]
      expect(TextWindow.list.select(&:active?)).to eq [wm.stream['main']]
    end

    it 'leaves main current when Tab went round the whole cycle back to it' do
      press_tab(3)
      expect(cycle).to eq %w[main familiar thoughts]

      terminal_resize(24, 200)

      expect(cycle).to eq %w[main familiar thoughts speech]
      expect(TextWindow.list.select(&:active?)).to eq [wm.stream['main']]
    end
  end

  describe 'sizes and positions that do not fit' do
    def start_with(windows, lines: 24, cols: 80)
      start("<settings><layout id='default'>#{windows}" \
            "<window class='command' top='lines-1' left='0' height='1' width='cols'/></layout></settings>", lines, cols)
    end

    it 'builds a window with no width at load once the terminal is wide enough' do
      start_with("<window class='progress' top='0' left='0' height='1' width='cols-100' value='health' label='HP'/>")
      expect(wm.progress).to be_empty

      terminal_resize(24, 100)
      expect(wm.progress).to be_empty

      terminal_resize(24, 120)
      expect(geometry(wm.progress['health'])).to eq [0, 0, 1, 20]
    end

    it 'builds a window whose top was above the screen once the terminal is tall enough' do
      start_with("<window class='countdown' top='lines-30' left='0' height='1' width='20' value='roundtime' label='RT'/>")
      expect(wm.countdown).to be_empty

      terminal_resize(30, 80)

      expect(geometry(wm.countdown['roundtime'])).to eq [0, 0, 1, 20]
      expect(wm.countdown['roundtime'].rows).to eq ["RT#{'0'.rjust(18)}"]
    end

    it 'builds a text window too narrow for its builder once it is wide enough' do
      start_with("<window class='text' top='0' left='0' height='5' width='cols-79' value='main'/>")
      expect(wm.stream).to be_empty

      terminal_resize(24, 120)

      expect(geometry(wm.stream['main'])).to eq [0, 0, 5, 40]
      expect(SCROLL_WINDOW).to eq [wm.stream['main']]
    end

    it 'makes the first text window built late the current window when the layout had none' do
      start_with(<<~XML)
        <window class='text' top='0' left='100' height='5' width='20' value='main'/>
        <window class='text' top='0' left='120' height='5' width='20' value='thoughts'/>
      XML
      expect(SCROLL_WINDOW).to be_empty

      terminal_resize(24, 140)

      expect(SCROLL_WINDOW).to eq [wm.stream['main'], wm.stream['thoughts']]
      expect(wm.stream['main'].active?).to be true
      expect(wm.stream['main'].scrollbar.rows.first).to eq LineBuffered::ACTIVE_INDICATOR
      expect(wm.stream['thoughts'].scrollbar.rows).to eq [''] * 5
    end

    it 'makes the first text window built late the current window even after Tab on the empty cycle' do
      start_with(<<~XML)
        <window class='text' top='0' left='100' height='5' width='20' value='main'/>
        <window class='text' top='0' left='120' height='5' width='20' value='thoughts'/>
      XML
      app.key_action.fetch('switch_current_window').call

      terminal_resize(24, 140)

      expect(SCROLL_WINDOW).to eq [wm.stream['main'], wm.stream['thoughts']]
      expect(TextWindow.list.select(&:active?)).to eq [wm.stream['main']]
    end

    it 'never builds a window whose place is always off the screen' do
      start_with("<window class='progress' top='lines' left='0' height='1' width='20' value='health'/>")

      terminal_resize(60, 240)

      expect(wm.progress).to be_empty
      expect(ProgressWindow.list).to be_empty
    end

    it 'starts a text window built late with blank lines, so its text starts on its bottom row' do
      start_with("<window class='text' top='0' left='100' height='4' width='20' value='main'/>")

      terminal_resize(24, 120)
      receive_from_server('You glance around.')

      expect(wm.stream['main'].rows).to eq ['', '', '', 'You glance around.']
    end
  end

  # The input loop fits the layout once per burst of resizes (#217).
  describe 'a burst of terminal resizes in the input loop' do
    let(:resized) { [] }

    before do
      File.write(settings_path, template('tysong'))
      allow(app.window_mgr).to receive(:resize).and_wrap_original do |original, *args|
        resized << [Curses.lines, Curses.cols]
        original.call(*args)
      end
    end

    def resize_to(lines, cols)
      press_after(Curses::KEY_RESIZE) { terminal.merge!(lines: lines, cols: cols) }
    end

    it 'builds the off-screen windows once, at the final size' do
      run_client(keyboard(resize_to(40, 120), resize_to(50, 200), resize_to(55, 234),
                          wait_until { resized.size == 2 }))

      expect(resized).to eq [[24, 80], [55, 234]]
      expect(geometry(wm.room['room'])).to eq [0, 161, 20, 72]
      expect(geometry(wm.stream['speech'])).to eq [21, 161, 30, 72]
      expect(RoomWindow.list.size).to eq 1
    end
  end

  # The input thread resizes between two server lines, so a grow can land
  # in the middle of a room change or of a stream push.
  describe 'a grow in the middle of what the game sends' do
    # DragonRealms (Catheroine 2026-09-26 14:45:47, lines 5608-5619, the
    # description cut after its first sentence): a room change, its
    # components and then the inline view on main.
    let(:dr_room) do
      desc = 'The oppressive darkness of the canopy yields slightly, allowing a glimpse of the night sky above.'
      [
        "<nav rm='4219304'/>",
        "<streamWindow id='main' title='Story' subtitle=\" - [Kaal Utewg, Clearing] (4219304)\" location='center' " \
        "target='drop'/>",
        "<streamWindow id='room' title='Room' subtitle=\" - [Kaal Utewg, Clearing] (4219304)\" location='center' " \
        "target='drop' ifClosed='' resident='true'/>",
        "<component id='room desc'>#{desc}</component>",
        "<component id='room objs'>You also see a steep trail leading uphill.</component>",
        "<component id='room players'></component>",
        "<component id='room exits'>Obvious paths: <d>southwest</d>, <d>west</d>, <d>northwest</d>.<compass></compass>" \
        '</component>',
        "<component id='room extra'></component>",
        '<resource picture="0"/><style id="roomName" />[Kaal Utewg, Clearing] (4219304)',
        "<style id=\"\"/><preset id='roomDesc'>#{desc}</preset>  You also see a steep trail leading uphill.",
        'Obvious paths: <d>southwest</d>, <d>west</d>, <d>northwest</d>.',
        '<prompt time="1790917547">&gt;</prompt>'
      ]
    end
    let(:dr_room_view) do
      [
        '[Kaal Utewg, Clearing] (4219304)',
        'The oppressive darkness of the canopy yields slightly, allowing a',
        'glimpse of the night sky above.',
        'You also see a steep trail leading uphill.',
        'Obvious paths: southwest, west, northwest.'
      ]
    end

    # mahtra.xml's room window starts on row 17: a 17-line terminal has no
    # room for it.
    it 'shows the next DR room whole, wherever in a room change the grow landed' do
      (0..dr_room.size).each do |cut|
        restart_client
        start(template('mahtra'), 17, 80)
        receive_from_server(dr_room.first(cut), game: 'DR')
        expect(wm.room).to be_empty

        terminal_resize(60, 200)
        receive_from_server(dr_room.drop(cut), dr_room, game: 'DR')

        expect([cut, text_of(wm.room['room'])]).to eq [cut, dr_room_view]
      end
    end

    it 'shows the next GS room whole, wherever in a room push the grow landed' do
      (0..gs_room.size).each do |cut|
        restart_client
        start(template('tysong'), 24, 80)
        receive_from_server(gs_room.first(cut))

        terminal_resize(55, 234)
        receive_from_server(gs_room.drop(cut), gs_room)

        expect([cut, text_of(wm.room['room'])]).to eq [cut, [
          '[Sanctum of Scales, Columns] (4216017)',
          'A huge copper-paneled sandstone wall stretches from east to west along',
          'the northern edge of the antechamber.',
          'Obvious exits: north, east, west'
        ]]
      end
    end

    # mahtra.xml's familiar window starts on row 39. Until it is built, the
    # familiar stream falls back to main.
    it 'splits a familiar push the grow landed in between main and the new window, losing and repeating nothing' do
      allow(Time).to receive(:now).and_return(Time.new(2026, 8, 27, 16, 29, 0))
      report = ["Tenuk's injuries include...", 'Wounds to the ABDOMEN:',
                '  Fresh External:  light scratches -- insignificant']
      (0..dr_familiar.size).each do |cut|
        restart_client
        start(template('mahtra'), 24, 80)
        receive_from_server(dr_familiar.first(cut), game: 'DR')

        terminal_resize(60, 200)
        receive_from_server(dr_familiar.drop(cut), game: 'DR')

        before_grow = report.first((cut - 1).clamp(0, 3))
        expect([cut, text_of(wm.stream['main']).drop(1), text_of(wm.stream['familiar'])])
          .to eq [cut, before_grow, (report - before_grow).map { |line| "#{line} [16:29]" }]
      end
    end
  end
end
