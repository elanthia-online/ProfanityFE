# frozen_string_literal: true

# Tests what a user sees across `.layout` reloads: windows the new layout
# drops must disappear (no ghosts left to hit-test, repaint, or scroll),
# windows it keeps must not be shared or duplicated, and `.resize` must
# leave every window the size the layout built it at.

require 'rexml/document'
require_relative '../../lib/event_bus'
require_relative '../../lib/window_manager'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../../lib/windows/sink_window' # real SinkWindow

RSpec.describe WindowManager, '#load_layout' do
  subject(:window_manager) { described_class.new }

  # One window of every type, tiled on the 24x80 test screen:
  #   rows 0-9   main text | thoughts/logons tabs
  #   rows 10-14 exp | spells | room
  #   row  23    prompt, then the command line
  let(:every_window_type) do
    <<~XML
      <window class='text' top='0' left='0' height='10' width='40' value='main,death'/>
      <window class='tabbed' top='0' left='40' height='10' width='40' tabs='thoughts,logons'/>
      <window class='exp' top='10' left='0' height='5' width='20'/>
      <window class='percWindow' top='10' left='20' height='5' width='20'/>
      <window class='room' top='10' left='40' height='5' width='40'/>
      <window class='progress' top='16' left='0' height='1' width='20' value='health' label='HP'/>
      <window class='countdown' top='17' left='0' height='1' width='20' value='roundtime' label='RT'/>
      <window class='indicator' top='23' left='0' height='1' width='1' value='prompt' label='&gt;'/>
      <window class='command' top='23' left='1' height='1' width='79'/>
    XML
  end

  let(:main_only) do
    <<~XML
      <window class='text' top='0' left='0' height='10' width='40' value='main'/>
      <window class='command' top='23' left='0' height='1' width='80'/>
    XML
  end

  let(:window_types) do
    [TextWindow, TabbedTextWindow, ExpWindow, PercWindow, RoomWindow,
     IndicatorWindow, ProgressWindow, CountdownWindow]
  end

  def load(windows_xml, id: 'test')
    LAYOUT[id] = REXML::Document.new("<layout>#{windows_xml}</layout>").root
    window_manager.load_layout(id)
  end

  def live_window_counts
    window_types.to_h { |klass| [klass, klass.list.size] }
  end

  def closed?(curses_window)
    curses_window.call_log.any? { |(meth, _args)| meth == :close }
  end

  describe 'windows the new layout drops' do
    it 'keeps exactly one window of each type after loading the same layout twice' do
      load(every_window_type)
      load(every_window_type)

      expect(live_window_counts).to eq(window_types.to_h { |klass| [klass, 1] })
    end

    it 'lists only the windows the current layout routes to' do
      load(every_window_type)
      load(every_window_type)

      expect(TabbedTextWindow.list).to eq [window_manager.stream['thoughts']]
      expect(ExpWindow.list).to eq [window_manager.stream['exp']]
      expect(PercWindow.list).to eq [window_manager.stream['percWindow']]
      expect(RoomWindow.list).to eq [window_manager.room['room']]
    end

    it 'removes every window a smaller layout leaves out' do
      load(every_window_type)
      load(main_only)

      expect(live_window_counts).to eq(window_types.to_h { |klass| [klass, klass == TextWindow ? 1 : 0] })
    end

    it 'closes each dropped window and its scrollbar' do
      load(every_window_type)
      tabbed = window_manager.stream['thoughts']
      dropped = [tabbed, window_manager.stream['exp'], window_manager.stream['percWindow'],
                 window_manager.room['room'], window_manager.indicator['prompt']]

      load(main_only)

      expect(dropped.reject { |window| closed?(window) }).to be_empty
      expect(closed?(tabbed.scrollbar)).to be true
    end

    it 'does not close a text window the new layout reuses' do
      load(every_window_type)
      main = window_manager.stream['main']

      load(main_only)

      expect(window_manager.stream['main']).to be main
      expect(closed?(main)).to be false
    end

    it 'closes windows of a window class defined after the built-in ones' do
      custom_class = Class.new(TextWindow)
      stray = custom_class.new(1, 10, 20, 0)

      load(main_only)

      expect(custom_class.list).to be_empty
      expect(closed?(stray)).to be true
    end

    it 'finds no window where only a dropped window used to be' do
      load(every_window_type)
      load(main_only)

      expect(BaseWindow.find_window_at(2, 50)).to be_nil  # old tabbed window
      expect(BaseWindow.find_window_at(12, 50)).to be_nil # old room window
      expect(BaseWindow.find_window_at(12, 5)).to be_nil  # old exp window
    end

    it 'finds the live window, not its dropped predecessor, at the same spot' do
      load(every_window_type)
      load(every_window_type)

      expect(BaseWindow.find_window_at(2, 50)).to be window_manager.stream['thoughts']
    end
  end

  describe 'the scroll-window cycle' do
    it 'holds each live scrollable window exactly once after a reload' do
      load(every_window_type)
      load(every_window_type)

      expect(SCROLL_WINDOW).to contain_exactly(window_manager.stream['main'], window_manager.stream['thoughts'])
    end

    it 'drops scrollable windows the new layout leaves out' do
      load(every_window_type)
      load(main_only)

      expect(SCROLL_WINDOW).to eq [window_manager.stream['main']]
    end

    it 'marks the new first scrollable window active when the old one was dropped' do
      load("<window class='tabbed' top='0' left='0' height='10' width='40' tabs='thoughts'/>")
      load(main_only)

      expect(window_manager.stream['main']).to be_active
    end
  end

  describe 'reusing text windows' do
    it 'gives each layout slot its own window when a stream list is split across slots' do
      load("<window class='text' top='0' left='0' height='10' width='40' value='main,death'/>")
      original = window_manager.stream['main']
      load(<<~XML)
        <window class='text' top='0' left='0' height='10' width='40' value='main,death'/>
        <window class='text' top='10' left='0' height='5' width='40' value='death'/>
      XML

      expect(window_manager.stream['main']).to be original
      expect(window_manager.stream['death']).not_to be original
      expect(TextWindow.list.size).to eq 2
    end

    it 'builds a text window for a stream that was sunk in the previous layout' do
      load("#{main_only}<window class='sink' value='atmospherics'/>")

      expect do
        load("#{main_only}<window class='text' top='10' left='0' height='5' width='40' value='atmospherics'/>")
      end.not_to raise_error
      expect(window_manager.stream['atmospherics']).to be_a TextWindow
    end

    it 'builds a text window for a stream that was a tab in the previous layout' do
      load("<window class='tabbed' top='0' left='0' height='10' width='40' tabs='main,thoughts'/>")
      load(main_only)

      expect(window_manager.stream['main']).to be_an_instance_of TextWindow
    end
  end

  describe 'then #resize' do
    before { load(every_window_type) }

    it 'keeps the exp and spell windows the width the layout built them at' do
      built = [window_manager.stream['exp'].maxx, window_manager.stream['percWindow'].maxx]

      window_manager.resize(nil)

      expect([window_manager.stream['exp'].maxx, window_manager.stream['percWindow'].maxx]).to eq built
    end

    it 'keeps the prompt and command line fitted to a prompt longer than the layout width' do
      event_bus = EventBus.new
      window_manager.subscribe_to_events(event_bus)
      event_bus.emit(:prompt_changed, text: 'RH>')
      prompt = window_manager.indicator['prompt']
      command = window_manager.command_window
      fitted = [prompt.maxx, command.begx, command.maxx]

      window_manager.resize(nil)

      expect(fitted).to eq [3, 3, 77]
      expect([prompt.maxx, command.begx, command.maxx]).to eq fitted
      expect(prompt.rows).to eq ['RH>']
    end

    it 'refits the typed command to the command line width left after fitting the prompt' do
      event_bus = EventBus.new
      window_manager.subscribe_to_events(event_bus)
      event_bus.emit(:prompt_changed, text: 'RH>')
      command = CommandBuffer.new
      command.window = window_manager.command_window
      "#{'a' * 85}XYZ".each_char { |ch| command.put_ch(ch) }

      window_manager.resize(command)

      expect(command.window.row(0)).to end_with('XYZ')
      expect(command.window.curx).to eq 'XYZ'.length + command.window.row(0).index('XYZ')
    end

    it 'never sizes the prompt or command line below one column' do
      event_bus = EventBus.new
      window_manager.subscribe_to_events(event_bus)

      event_bus.emit(:prompt_changed, text: '')
      expect(window_manager.indicator['prompt'].maxx).to eq 1

      event_bus.emit(:prompt_changed, text: '>' * 200)
      expect(window_manager.command_window.maxx).to eq 1
    end
  end

  describe 'dimension expressions' do
    # The spec screen is 24 lines by 80 columns. A text window gives one
    # column to its scrollbar, so its maxx is the layout width minus one.
    it 'sizes and places a window from lines/cols arithmetic' do
      load("<window class='text' top='lines-20' left='cols/4' height='lines-10' width='cols/2+1' value='main'/>")
      main = window_manager.stream['main']

      expect([main.maxy, main.maxx, main.begy, main.begx]).to eq [14, 40, 4, 20]
    end

    # The layout parser is lenient; an eval-based parser would size these to 0.
    it 'treats an unclosed parenthesis as closed and a missing operand as 0' do
      load("<window class='text' top='0' left='0' height='(lines-14' width='cols/2+' value='main'/>")
      main = window_manager.stream['main']

      expect([main.maxy, main.maxx]).to eq [10, 39]
    end
  end
end
