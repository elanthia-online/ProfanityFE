# frozen_string_literal: true

# Tests LayoutLoader, which turns a layout into windows, through
# WindowManager#load_layout on the virtual screen (24x80): which elements
# become windows and where, which windows a second layout reuses, that
# every window it drops is closed, and what an unknown layout does.
# Switching with the .layout command is driven through the real
# Application at the end, as is starting the client with (and switching
# to) a layout that has a text window with no value.

require 'rexml/document'
require 'socket'
require_relative '../../lib/event_bus'
require_relative '../../lib/window_manager'
require_relative '../../lib/windows/sink_window' # real SinkWindow
require_relative '../../lib/shared_state'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../../lib/mouse_scroll'
require_relative '../../lib/autocomplete'
require_relative '../../lib/selection_manager'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../../lib/application'

RSpec.describe LayoutLoader do
  subject(:wm) { WindowManager.new }

  let(:first_layout) do
    <<~XML
      <window class='text' top='0' left='0' height='10' width='40' value='main,death'/>
      <window class='tabbed' top='0' left='40' height='10' width='40' tabs='thoughts,logons'/>
      <window class='room' top='10' left='40' height='5' width='40'/>
      <window class='progress' top='16' left='0' height='1' width='20' value='health' label='HP'/>
      <window class='countdown' top='17' left='0' height='1' width='20' value='roundtime' label='RT'/>
      <window class='indicator' top='18' left='0' height='1' width='5' value='kneeling' label='K'/>
      <window class='indicator' top='23' left='0' height='1' width='1' value='prompt' label='&gt;'/>
      <window class='command' top='23' left='1' height='1' width='79'/>
    XML
  end

  # Keeps main, health, roundtime and prompt at new places; drops the
  # tabbed and room windows and the kneeling indicator.
  let(:second_layout) do
    <<~XML
      <window class='text' top='2' left='0' height='12' width='60' value='main'/>
      <window class='progress' top='20' left='0' height='1' width='30' value='health' label='HP'/>
      <window class='countdown' top='21' left='0' height='1' width='30' value='roundtime' label='RT'/>
      <window class='indicator' top='22' left='0' height='1' width='1' value='prompt' label='&gt;'/>
      <window class='command' top='22' left='1' height='1' width='79'/>
    XML
  end

  def define(windows_xml, id)
    LAYOUT[id] = REXML::Document.new("<layout>#{windows_xml}</layout>").root
  end

  def load(windows_xml, id: 'test')
    define(windows_xml, id)
    wm.load_layout(id)
  end

  def closed?(curses_window)
    curses_window.call_log.any? { |(meth, _args)| meth == :close }
  end

  def geometry(window)
    [window.begy, window.begx, window.maxy, window.maxx]
  end

  describe 'building a layout' do
    it 'builds each window where its element puts it and keeps the element layout on it' do
      load(first_layout)

      expect(geometry(wm.stream['main'])).to eq [0, 0, 10, 39] # one column for the scrollbar
      expect(geometry(wm.progress['health'])).to eq [16, 0, 1, 20]
      expect(wm.progress['health'].layout).to eq WindowLayout.new(height: '1', width: '20', top: '16', left: '0')
      expect(wm.stream['death']).to be wm.stream['main']
      expect(wm.stream['logons']).to be wm.stream['thoughts']
      expect(wm.room['room']).to be_a RoomWindow
      expect(wm.command_window_layout).to eq WindowLayout.new(height: '1', width: '79', top: '23', left: '1')
    end

    {
      'zero height'            => "height='0' width='10' top='0' left='0'",
      'zero width'             => "height='1' width='0' top='0' left='0'",
      'a negative top'         => "height='1' width='10' top='-1' left='0'",
      'a negative left'        => "height='1' width='10' top='0' left='-1'",
      'a top below the screen' => "height='1' width='10' top='lines' left='0'",
      'a left past the screen' => "height='1' width='10' top='0' left='cols'"
    }.each do |what, geometry|
      it "builds no window for an element with #{what}" do
        load("<window class='indicator' value='kneeling' #{geometry}/>")

        expect(wm.indicator).to be_empty
        expect(IndicatorWindow.list).to be_empty
      end
    end

    it 'builds a window at the last row and column the screen has' do
      load("<window class='indicator' value='kneeling' height='1' width='1' top='lines-1' left='cols-1'/>")

      expect(geometry(wm.indicator['kneeling'])).to eq [23, 79, 1, 1]
    end

    it 'skips elements that are not windows and window classes nothing builds' do
      expect do
        load(<<~XML)
          <note class='text' top='0' left='0' height='5' width='20' value='main'/>
          <window class='hologram' top='0' left='0' height='5' width='20' value='main'/>
          <window top='0' left='0' height='5' width='20' value='main'/>
        XML
      end.not_to raise_error

      expect(wm.stream).to be_empty
      expect(BaseWindow.all_windows).to be_empty
    end

    it 'sends every stream a sink lists, spaces trimmed, to one window that shows nothing' do
      load("#{second_layout}<window class='sink' value='atmospherics, combat ,logons'/>")

      sink = wm.stream['atmospherics']
      expect(sink).to be_a SinkWindow
      expect([wm.stream['combat'], wm.stream['logons']]).to all(be sink)
      expect(wm.stream.keys).not_to include(' combat ')
      expect { sink.route_string('You swing.', [], 'combat') }.not_to raise_error
    end
  end

  describe 'switching to another layout' do
    before { load(first_layout) }

    it 'keeps the text window of a stream the new layout still shows, with its lines' do
      main = wm.stream['main']
      main.add_string('You wave.')
      shown = main.rows

      load(second_layout, id: 'second')

      expect(wm.stream['main']).to be main
      expect(main.rows).to eq shown
      expect(main.layout).to eq WindowLayout.new(height: '12', width: '60', top: '2', left: '0')
      expect(closed?(main)).to be false
    end

    it 'keeps progress, countdown and indicator windows by value, with what they show' do
      kept = [wm.progress['health'], wm.countdown['roundtime'], wm.indicator['prompt']]
      wm.progress['health'].update(40, 100)

      load(second_layout, id: 'second')

      expect([wm.progress['health'], wm.countdown['roundtime'], wm.indicator['prompt']]).to eq kept
      expect(kept.map { |window| closed?(window) }).to all(be false)
      expect(wm.progress['health'].rows).to eq ["HP#{'40'.rjust(28)}"] # the new width, 30
    end

    it 'draws a kept indicator at its new place and width, with all of its new label' do
      kneeling = wm.indicator['kneeling']

      load("<window class='indicator' top='20' left='0' height='1' width='10' value='kneeling' label='Kneeling'/>",
           id: 'kneeling')

      expect(wm.indicator['kneeling']).to be kneeling
      expect(kneeling.rows).to eq ['Kneeling']
      expect(geometry(kneeling)).to eq [20, 0, 1, 10]
    end

    it 'draws a kept countdown at its new place and width, with its new label and current value' do
      roundtime = wm.countdown['roundtime']

      load("<window class='countdown' top='21' left='0' height='1' width='30' value='roundtime' label='Roundtime'/>",
           id: 'roundtime')

      expect(wm.countdown['roundtime']).to be roundtime
      expect(roundtime.rows).to eq ["Roundtime#{'0'.rjust(21)}"]
      expect(geometry(roundtime)).to eq [21, 0, 1, 30]
    end

    it 'keeps the command window and takes the new layout for it' do
      command = wm.command_window

      load(second_layout, id: 'second')

      expect(wm.command_window).to be command
      expect(wm.command_window_layout).to eq WindowLayout.new(height: '1', width: '79', top: '22', left: '1')
    end

    it 'closes every window the new layout drops, and forgets its streams' do
      dropped = [wm.stream['thoughts'], wm.room['room'], wm.indicator['kneeling']]
      scrollbar = wm.stream['thoughts'].scrollbar

      load(second_layout, id: 'second')

      expect(dropped.map { |window| closed?(window) }).to all(be true)
      expect(closed?(scrollbar)).to be true
      expect(wm.stream.keys).to eq ['main']
      expect(wm.room).to be_empty
      expect(wm.indicator.keys).to eq ['prompt']
      expect([TabbedTextWindow.list, RoomWindow.list]).to eq [[], []]
      expect(SCROLL_WINDOW).to eq [wm.stream['main']]
      expect(BaseWindow.find_window_at(2, 50)).to be_nil
    end

    it 'closes a window whose key the new layout places off screen instead of reusing it' do
      health = wm.progress['health']

      load("<window class='progress' top='lines' left='0' height='1' width='20' value='health'/>", id: 'offscreen')

      expect(closed?(health)).to be true
      expect(wm.progress).to be_empty
      expect(ProgressWindow.list).to be_empty
    end

    it 'does not reuse a window for a different value' do
      kneeling = wm.indicator['kneeling']

      load("<window class='indicator' top='18' left='0' height='1' width='5' value='sitting'/>", id: 'sitting')

      expect(wm.indicator['sitting']).not_to be kneeling
      expect(closed?(kneeling)).to be true
    end

    it 'makes the first scrollable window of the new layout the active one' do
      load("<window class='tabbed' top='0' left='0' height='10' width='40' tabs='logons'/>", id: 'tabs')

      expect(SCROLL_WINDOW).to eq [wm.stream['logons']]
      expect(wm.stream['logons']).to be_active
    end

    it 'keeps the windows it reuses and rebuilds the rest when the same layout loads again' do
      reused = [wm.stream['main'], wm.progress['health'], wm.countdown['roundtime'],
                wm.indicator['kneeling'], wm.indicator['prompt']]
      rebuilt = [wm.stream['thoughts'], wm.room['room']]

      load(first_layout)

      expect(BaseWindow.all_windows.size).to eq reused.size + rebuilt.size
      expect(BaseWindow.all_windows).to include(*reused)
      expect(reused.map { |window| closed?(window) }).to all(be false)
      expect(rebuilt.map { |window| closed?(window) }).to all(be true)
      expect([wm.stream['thoughts'], wm.room['room']]).to all(be_a(BaseWindow))
      expect(BaseWindow.all_windows).not_to include(*rebuilt)
    end
  end

  describe 'switching from a bar too narrow for its label and value' do
    it 'draws the kept bar at its new place and width, with its new label and current value' do
      load("<window class='progress' top='16' left='0' height='1' width='3' value='health'/>", id: 'narrow')
      health = wm.progress['health']
      health.update(75, 100)

      load("<window class='progress' top='20' left='0' height='1' width='20' value='health' label='hp'/>", id: 'wide')

      expect(wm.progress['health']).to be health
      expect(health.rows).to eq ["hp#{'75'.rjust(18)}"]
      expect(geometry(health)).to eq [20, 0, 1, 20]
    end
  end

  describe 'what builders see' do
    let(:seen) { [] }

    before do
      recorder = seen
      BaseWindow.register_type('probe') do |_height, _width, _top, _left, _element, manager|
        recorder << { streams: manager.previous_stream.keys, indicators: manager.previous_indicator.keys,
                      progress: manager.previous_progress.keys, countdowns: manager.previous_countdown.keys,
                      old: manager.old_windows.size, current: manager.stream.keys }
        nil
      end
    end

    after { BaseWindow.type_registry.delete('probe') }

    it 'gives builders the previous layout while it loads and forgets it afterwards' do
      load(first_layout)
      old_count = BaseWindow.all_windows.size

      load("<window class='text' top='0' left='0' height='5' width='40' value='main'/><window class='probe' top='6' left='0' height='1' width='1'/>",
           id: 'probe')

      expect(seen).to eq [{ streams: %w[thoughts logons], indicators: %w[kneeling prompt],
                            progress: ['health'], countdowns: ['roundtime'], old: old_count - 1, current: ['main'] }]
      expect([wm.previous_stream, wm.previous_indicator, wm.previous_progress, wm.previous_countdown]).to all(be_empty)
      expect(wm.old_windows).to be_empty
    end

    it 'shows builders an empty previous layout on the first load' do
      load("<window class='probe' top='0' left='0' height='1' width='1'/>")

      expect(seen).to eq [{ streams: [], indicators: [], progress: [], countdowns: [], old: 0, current: [] }]
    end
  end

  describe 'an unknown layout' do
    before { load(first_layout) }

    it 'warns with the layouts there are and changes nothing' do
      windows = BaseWindow.all_windows
      registries = [wm.stream, wm.indicator, wm.progress, wm.countdown, wm.room]
      LAYOUT.delete('nope')

      expect { wm.load_layout('nope') }.to output(/layout 'nope' not found in LAYOUT \(available: .*test/).to_stderr

      expect([wm.stream, wm.indicator, wm.progress, wm.countdown, wm.room]).to eq registries
      expect(registries.zip([wm.stream, wm.indicator, wm.progress, wm.countdown, wm.room]).map { |a, b| a.equal?(b) }).to all(be true)
      expect(BaseWindow.all_windows).to eq windows
      expect(windows.map { |window| closed?(window) }).to all(be false)
    end
  end

  describe 'the .layout command' do
    let(:app) do
      Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                      settings_file: File.join(@dir, 'settings.xml'), host: '127.0.0.1', port: 8000)
    end

    around do |example|
      Dir.mktmpdir { |dir| @dir = dir; example.run }
    end

    before do
      File.write(File.join(@dir, 'settings.xml'), '<settings/>')
      allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
      stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
      define(first_layout, 'first')
      define(second_layout, 'second')
      app.window_mgr.load_layout('first')
      app.cmd_buffer.window = app.window_mgr.command_window
    end

    it 'switches layouts: kept windows stay, dropped ones close, the command line follows' do
      main = app.window_mgr.stream['main']
      tabbed = app.window_mgr.stream['thoughts']

      app.execute_command('.layout second')

      expect(app.window_mgr.stream['main']).to be main
      expect(closed?(tabbed)).to be true
      expect(app.window_mgr.stream.keys).to eq ['main']
      expect(app.cmd_buffer.window).to be app.window_mgr.command_window
      # .layout resizes afterwards, which places the kept main window at
      # its new layout.
      expect(geometry(main)).to eq [2, 0, 12, 59]
    end

    it 'shows a kept progress bar\'s new label and current value at its new width' do
      define("<window class='progress' top='20' left='0' height='1' width='30' value='health' label='hp'/>", 'hp')
      app.window_mgr.progress['health'].update(75, 100)

      app.execute_command('.layout hp')

      expect(app.window_mgr.progress['health'].rows).to eq ["hp#{'75'.rjust(28)}"]
    end

    it 'shows a kept countdown\'s new label and current value at its new width' do
      define("<window class='countdown' top='21' left='0' height='1' width='30' value='roundtime' label='Roundtime'/>",
             'roundtime')

      app.execute_command('.layout roundtime')

      expect(app.window_mgr.countdown['roundtime'].rows).to eq ["Roundtime#{'0'.rjust(21)}"]
    end
  end

  # BUG FOUND (fixed here): the text builder read the value attribute
  # without checking it was there, so a text window with no value raised
  # NoMethodError halfway through the layout. At startup the client exited
  # with a Ruby backtrace; after .layout no stream had a window, so all game
  # text was lost. It now gets a window that shows no stream, like a
  # progress, countdown or indicator window with no value.
  describe 'a text window with no value' do
    let(:app) do
      Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                      settings_file: File.join(@dir, 'settings.xml'), host: '127.0.0.1', port: 8000)
    end

    # The empty window comes first, so every window after it depends on
    # the builder getting past it.
    let(:layout_with_empty_text) do
      <<~XML
        <window class='text' top='0' left='0' height='5' width='40'/>
        <window class='text' top='5' left='0' height='10' width='60' value='main'/>
        <window class='progress' top='20' left='0' height='1' width='30' value='health' label='HP'/>
        <window class='command' top='23' left='0' height='1' width='80'/>
      XML
    end

    around do |example|
      Dir.mktmpdir { |dir| @dir = dir; example.run }
    end

    before do
      allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
      stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
      allow(IO).to receive(:select).and_return(nil)
    end

    # Feed raw server lines through the real server loop into the app's
    # windows, as the server thread does.
    def receive_from_server(*lines)
      event_bus = EventBus.new
      app.window_mgr.subscribe_to_events(event_bus)
      processor = GameTextProcessor.new(
        window_mgr: app.window_mgr, shared_state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
        cmd_buffer: app.cmd_buffer, event_bus: event_bus,
        xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' }
      )
      queue = lines.map { |line| "#{line}\r\n" }
      server = Object.new
      server.define_singleton_method(:gets) { queue.shift&.dup }
      processor.run(server)
    end

    it 'is built, shows no stream, and the rest of the layout loads' do
      load(layout_with_empty_text)

      empty = TextWindow.list.find { |window| window.begy.zero? }
      expect(geometry(empty)).to eq [0, 0, 5, 39]
      expect(wm.stream.keys).to eq ['main']
      expect(wm.stream.values).not_to include(empty)
      expect(geometry(wm.progress['health'])).to eq [20, 0, 1, 30]
      expect(wm.command_window_layout).to eq WindowLayout.new(height: '1', width: '80', top: '23', left: '0')
    end

    it 'starts the client with it, and game text reaches main' do
      File.write(File.join(@dir, 'settings.xml'),
                 "<settings><layout id='default'>#{layout_with_empty_text}</layout></settings>")

      app.send(:load_settings_and_layout)
      receive_from_server('A goblin arrives.')

      expect(app.cmd_buffer.window).to be app.window_mgr.command_window
      expect(app.window_mgr.stream['main'].rows.reject(&:empty?)).to eq ['A goblin arrives.']
    end

    it 'switches to it with .layout, and game text still reaches main' do
      File.write(File.join(@dir, 'settings.xml'), '<settings/>')
      define(first_layout, 'first')
      define(layout_with_empty_text, 'empty-text')
      app.window_mgr.load_layout('first')
      app.cmd_buffer.window = app.window_mgr.command_window
      main = app.window_mgr.stream['main']
      tabbed = app.window_mgr.stream['thoughts']

      app.execute_command('.layout empty-text')
      receive_from_server('A goblin arrives.')

      expect(app.window_mgr.stream['main']).to be main
      expect(closed?(tabbed)).to be true
      expect(main.rows.reject(&:empty?)).to eq ['A goblin arrives.']
    end
  end

  # Startup and .layout apply a layout through the same steps
  # (Application#apply_layout): the room window follows the current links
  # setting, and a text window the layout adds starts its text on its
  # bottom row, whichever of the two built it.
  describe 'a layout applied at startup and by .layout' do
    let(:links) { true }
    let(:app) do
      Application.new({ char: nil, no_status: true, links: links, room_window_only: false },
                      settings_file: settings_path, host: '127.0.0.1', port: 8000)
    end
    let(:settings_path) { File.join(@dir, 'settings.xml') }

    # The room window of the layout shown now.
    def room
      app.window_mgr.room['room']
    end

    around do |example|
      Dir.mktmpdir { |dir| @dir = dir; example.run }
    end

    before do
      File.write(settings_path, <<~XML)
        <settings>
          <layout id='default'>
            <window class='text' top='0' left='0' height='10' width='40' value='main'/>
            <window class='room' top='10' left='0' height='5' width='40'/>
            <window class='command' top='23' left='0' height='1' width='80'/>
          </layout>
          <layout id='second'>
            <window class='text' top='0' left='0' height='10' width='40' value='main'/>
            <window class='text' top='0' left='40' height='4' width='40' value='thoughts'/>
            <window class='room' top='10' left='0' height='6' width='40'/>
            <window class='command' top='23' left='0' height='1' width='80'/>
          </layout>
        </settings>
      XML
      allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
      stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
      app.send(:load_settings_and_layout)
    end

    # Show a room whose exit "north" is a link, as the game's exits do.
    def show_room
      room.update_exits('Obvious paths: north.', links: [{ start: 15, end: 20, cmd: 'north' }])
    end

    # What a click on each cell of "north" in the room window sends.
    def north_clicks
      y = room.rows.index('Obvious paths: north.')
      (15...20).map { |x| room.link_cmd_at(y, x) }.uniq
    end

    it 'keeps the room window\'s links on after .layout when --links turned them on' do
      show_room
      expect(north_clicks).to eq ['north']

      app.execute_command('.layout second')
      show_room

      expect(north_clicks).to eq ['north']
    end

    context 'when started without --links' do
      let(:links) { false }

      it 'keeps the room window\'s links on after .layout when .links turned them on' do
        app.execute_command('.links')

        app.execute_command('.layout second')
        show_room

        expect(north_clicks).to eq ['north']
      end

      it 'turns the links of a room window .layout built on and off with .links' do
        app.execute_command('.layout second')
        show_room
        expect(north_clicks).to eq [nil]

        app.execute_command('.links')
        expect(north_clicks).to eq ['north']

        app.execute_command('.links')
        expect(north_clicks).to eq [nil]
      end
    end

    it 'starts the text of a text window .layout adds on its bottom row, as at startup' do
      main = app.window_mgr.stream['main']
      main.add_string('You wave.')
      expect(main.rows.last(2)).to eq ['', 'You wave.']

      app.execute_command('.layout second')
      thoughts = app.window_mgr.stream['thoughts']
      thoughts.add_string('You think.')

      expect(thoughts.rows).to eq ['', '', '', 'You think.']
    end

    it 'shows the current window\'s scrollbar as active after .layout, as at startup' do
      active = ["\u25B6", *Array.new(8, "\u2503"), ''] # the thumb, at the bottom, is a reverse-video blank
      main = app.window_mgr.stream['main']
      expect(main.scrollbar.rows).to eq active

      app.execute_command('.layout second')

      expect(main.scrollbar.rows).to eq active
      expect(app.window_mgr.stream['thoughts'].scrollbar.rows).to all(be_empty)
    end

    it 'does not fill a text window .layout keeps: its lines stay where they were' do
      main = app.window_mgr.stream['main']
      main.add_string('You wave.')
      shown = main.rows

      app.execute_command('.layout second')

      expect(app.window_mgr.stream['main']).to be main
      expect(main.rows).to eq shown
    end
  end
end
