# frozen_string_literal: true

# Tests LayoutLoader, which turns a layout into windows, through
# WindowManager#load_layout on the virtual screen (24x80): which elements
# become windows and where, which windows a second layout reuses, that
# every window it drops is closed, and what an unknown layout does.
# Switching with the .layout command is driven through the real
# Application at the end.

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
end
