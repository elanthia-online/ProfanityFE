# frozen_string_literal: true

# Tests where every window ends up, and what it shows, when the terminal is
# resized: WindowManager#resize re-evaluates each window's layout
# expressions against the new terminal size. Windows are built from layout
# XML through WindowManager#load_layout and draw onto the virtual screen
# (spec/support/virtual_screen.rb); the terminal size is stubbed.
#
# Geometry values are written [begy, begx, maxy, maxx]: the window's top
# row and left column on the screen, then its height and width.

require 'rexml/document'
require_relative '../../lib/event_bus'
require_relative '../../lib/window_manager'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../../lib/windows/sink_window' # real SinkWindow

RSpec.describe WindowManager, '#resize geometry' do
  subject(:wm) { described_class.new }

  let(:event_bus) { EventBus.new.tap { |bus| wm.subscribe_to_events(bus) } }
  let(:command) { CommandBuffer.new }

  # One window of every class, sized from the terminal (24x80 when built):
  #   main and thoughts text windows, a tabbed window, a one-row tabbed
  #   window, the exp, spell and room windows, a progress bar, a countdown,
  #   a kneeling indicator at fixed coordinates (off screen once the
  #   terminal is small), the prompt, the command line, and a sink.
  let(:every_window_class) do
    <<~XML
      <window class='text' top='0' left='0' height='lines/2' width='cols/2' value='main,death'/>
      <window class='text' top='0' left='cols/2' height='lines/4' width='cols/4' value='thoughts'/>
      <window class='tabbed' top='0' left='cols*3/4' height='lines/2' width='cols/4' tabs='combat,logons'/>
      <window class='tabbed' top='lines/4' left='cols/2' height='1' width='cols/4' tabs='atmo,arrivals'/>
      <window class='exp' top='lines/2' left='0' height='5' width='cols/4'/>
      <window class='percWindow' top='lines/2' left='cols/4' height='5' width='cols/4'/>
      <window class='room' top='lines/2' left='cols/2' height='lines/2-4' width='cols/2'/>
      <window class='progress' top='lines-4' left='0' height='1' width='cols/4' value='health' label='HP'/>
      <window class='countdown' top='lines-3' left='0' height='1' width='cols-60' value='roundtime' label='RT'/>
      <window class='indicator' top='18' left='70' height='1' width='10' value='kneeling' label='Kneeling'/>
      <window class='indicator' top='lines-1' left='0' height='1' width='1' value='prompt' label='&gt;'/>
      <window class='command' top='lines-1' left='1' height='1' width='cols-1'/>
      <window class='sink' value='atmospherics'/>
    XML
  end

  # Where the every-class layout puts each window on the 24x80 terminal.
  # The prompt is two columns wide for the 'H>' prompt, which pushes the
  # command line one column right.
  let(:geometries_at_24x80) do
    { main: [0, 0, 12, 39], thoughts: [0, 40, 6, 19], combat: [0, 60, 12, 19], atmo: [6, 40, 1, 19],
      exp: [12, 0, 5, 19], spells: [12, 20, 5, 19], room: [12, 40, 8, 40],
      health: [20, 0, 1, 20], roundtime: [21, 0, 1, 20], kneeling: [18, 70, 1, 10],
      prompt: [23, 0, 1, 2], command: [23, 2, 1, 78] }
  end

  before do
    terminal(24, 80)
  end

  def terminal(lines, cols)
    allow(Curses).to receive_messages(lines: lines, cols: cols)
  end

  def load(windows_xml, id: 'geometry')
    LAYOUT[id] = REXML::Document.new("<layout>#{windows_xml}</layout>").root
    wm.load_layout(id)
  end

  def resize_to(lines, cols)
    terminal(lines, cols)
    wm.resize(command)
  end

  def geometry(window)
    [window.begy, window.begx, window.maxy, window.maxx]
  end

  # Every window of the every-class layout, by a short name.
  def windows
    {
      main: wm.stream['main'], thoughts: wm.stream['thoughts'], combat: wm.stream['combat'],
      atmo: wm.stream['atmo'], exp: wm.stream['exp'], spells: wm.stream['percWindow'],
      room: wm.room['room'], health: wm.progress['health'], roundtime: wm.countdown['roundtime'],
      kneeling: wm.indicator['kneeling'], prompt: wm.indicator['prompt'], command: wm.command_window
    }
  end

  def geometries
    windows.transform_values { |window| geometry(window) }
  end

  # Every cell of +window+, row by row: the row's text and each cell's
  # attributes (colors included).
  def cells(window)
    (0...window.maxy).map { |y| [window.row(y), (0...window.maxx).map { |x| window.attrs_at(y, x) }] }
  end

  def screens
    windows.transform_values(&:rows)
  end

  # The scrollbar column of a text or tabbed window: where it is, what it
  # shows, and which of its rows are drawn in reverse video (the thumb).
  def scrollbar(window)
    bar = window.scrollbar
    { at: geometry(bar), rows: bar.rows,
      thumb: (0...bar.maxy).select { |y| bar.attrs_at(y, 0).anybits?(Curses::A_REVERSE) } }
  end

  def scrollbars
    %i[main thoughts combat atmo].to_h { |name| [name, scrollbar(windows[name])] }
  end

  # Note +name+ in +log+ each time +window+ is copied to the screen.
  def record_flushes(window, name, log)
    allow(window).to receive(:noutrefresh).and_wrap_original do |original|
      log << name
      original.call
    end
  end

  # Everything the user sees, for comparing before and after a resize.
  def screen_state
    { geometries: geometries, screens: screens, scrollbars: scrollbars, cursor: command.window.curx }
  end

  # Fill every window with something to show, then type a command.
  def fill_windows
    (1..14).each { |n| wm.stream['main'].add_string("main line #{n}") }
    wm.stream['main'].add_string('a main line long enough to wrap in a narrow window')
    %w[t1 t2 t3].each { |text| wm.stream['thoughts'].add_string(text) }
    %w[c1 c2 c3 c4 c5 c6].each { |text| wm.stream['combat'].route_string(text, [], 'combat') }
    wm.stream['logons'].route_string('Bob joins', [], 'logons')
    wm.stream['atmo'].route_string('wind', [], 'atmo')
    wm.stream['exp'].component_opened('Parry Ability')
    wm.stream['exp'].add_string('   Parry Ability: 1709 59%  [34/34]', [])
    wm.stream['percWindow'].add_string('Shadows (2 roisaen)')
    wm.room['room'].update_title('[Town Square]')
    wm.room['room'].update_desc('A wide square paved with old stones.')
    wm.room['room'].update_exits('Obvious paths: north, south.')
    wm.room['room'].render
    wm.progress['health'].update(50, 100)
    wm.countdown['roundtime'].active = true
    wm.countdown['roundtime'].tick
    wm.indicator['kneeling'].update(true)
    event_bus.emit(:prompt_changed, text: 'H>')
    command.window = wm.command_window
    'look at the stones'.each_char { |ch| command.put_ch(ch) }
  end

  context 'with a window of every class' do
    before do
      load(every_window_class)
      fill_windows
    end

    it 'builds every window where the layout puts it' do
      expect(geometries).to eq geometries_at_24x80
    end

    it 'moves and sizes every window for a larger terminal' do
      resize_to(40, 120)

      expect(geometries).to eq(
        main: [0, 0, 20, 59], thoughts: [0, 60, 10, 29], combat: [0, 90, 20, 29], atmo: [10, 60, 1, 29],
        exp: [20, 0, 5, 29], spells: [20, 30, 5, 29], room: [20, 60, 16, 60],
        health: [36, 0, 1, 30], roundtime: [37, 0, 1, 60], kneeling: [18, 70, 1, 10],
        prompt: [39, 0, 1, 2], command: [39, 2, 1, 118]
      )
    end

    it 'redraws what each window shows at the larger size' do
      resize_to(40, 120)

      expect(screens).to eq(
        main: ((1..14).map { |n| "main line #{n}" } + ['a main line long enough to wrap in a narrow window'] + [''] * 5),
        thoughts: %w[t1 t2 t3] + [''] * 7,
        combat: [' 1:combat | 2:logons*', 'c1', 'c2', 'c3', 'c4', 'c5', 'c6'] + [''] * 13,
        atmo: [' 1:atmo | 2:arrivals'],
        exp: ['Parry Ability: 1709 59% [34/3', '4]', '', '', ''],
        spells: ['Shadows (2 roisaen)', '', '', '', ''],
        room: ['[[Town Square]]', 'A wide square paved with old stones.', 'Obvious paths: north, south.'] + [''] * 13,
        # The bar and the countdown fill their new widths.
        health: ["HP#{'50'.rjust(28)}"], roundtime: ["RT#{'?'.rjust(58)}"], kneeling: ['Kneeling'],
        prompt: ['H>'], command: ['look at the stones']
      )
    end

    # main is the current scroll window, so its scrollbar is the active one.
    it 'draws only the first text window\'s scrollbar, beside the text, after a resize' do
      resize_to(40, 120)

      expect(scrollbars).to eq(
        main: { at: [0, 59, 20, 1], rows: ["\u25B6"] + ["\u2503"] * 18 + [''], thumb: [19] },
        thoughts: { at: [0, 89, 10, 1], rows: [''] * 10, thumb: [] },
        combat: { at: [0, 119, 20, 1], rows: [''] + ['|'] * 18 + [''], thumb: [19] },
        atmo: { at: [10, 89, 1, 1], rows: [''], thumb: [] }
      )
    end

    it 'moves and sizes every window for a smaller terminal, leaving off-screen ones where they were' do
      resize_to(12, 40)

      # kneeling (top 18) is below the last line, so it stays put; the
      # countdown's width (cols-60) is negative, so it is one column.
      expect(geometries).to eq(
        main: [0, 0, 6, 19], thoughts: [0, 20, 3, 9], combat: [0, 30, 6, 9], atmo: [3, 20, 1, 9],
        exp: [6, 0, 5, 9], spells: [6, 10, 5, 9], room: [6, 20, 2, 20],
        health: [8, 0, 1, 10], roundtime: [9, 0, 1, 1], kneeling: [18, 70, 1, 10],
        prompt: [11, 0, 1, 2], command: [11, 2, 1, 38]
      )
    end

    it 'redraws what each window shows at the smaller size' do
      resize_to(12, 40)

      expect(screens).to eq(
        main: ['main line 13', 'main line 14', 'a main line long', '  enough to wrap', '  in a narrow', '  window'],
        thoughts: %w[t1 t2 t3],
        combat: [' 1:combat', 'c2', 'c3', 'c4', 'c5', 'c6'],
        atmo: [' 1:atmo'],
        exp: ['Parry Abi', 'lity: 170', '9 59% [34', '/34]', ''],
        spells: ['Shadows', '  (2', '  roisae', '  n)', ''],
        room: ['Obvious paths:', 'north, south.'],
        # A label wider than the window: each drawn part that doesn't fit
        # ends in the last column, as in ncurses, so the countdown shows
        # the last part it draws.
        health: ["HP#{'50'.rjust(8)}"], roundtime: ['T'], kneeling: ['Kneeling'],
        prompt: ['H>'], command: ['look at the stones']
      )
      expect(scrollbars).to eq(
        main: { at: [0, 19, 6, 1], rows: ["\u25B6"] + ["\u2503"] * 4 + [''], thumb: [5] },
        thoughts: { at: [0, 29, 3, 1], rows: [''] * 3, thumb: [] },
        combat: { at: [0, 39, 6, 1], rows: [''] + ['|'] * 4 + [''], thumb: [5] },
        atmo: { at: [3, 29, 1, 1], rows: [''], thumb: [] }
      )
    end

    it 'clamps every window to at least one row and column at the smallest size it resizes for' do
      resize_to(3, 10)

      expect(geometries).to eq(
        main: [0, 0, 1, 4], thoughts: [0, 5, 1, 1], combat: [0, 7, 1, 1], atmo: [0, 5, 1, 1],
        exp: [1, 0, 5, 1], spells: [1, 2, 5, 1], room: [1, 5, 1, 5],
        health: [0, 0, 1, 2], roundtime: [0, 0, 1, 1], kneeling: [18, 70, 1, 10],
        prompt: [2, 0, 1, 2], command: [2, 2, 1, 8]
      )
      expect(screens).to eq(
        main: ['dow'], thoughts: [''], combat: [''], atmo: [''],
        exp: ['P', 'a', 'r', 'r', ''], spells: ['S', 'h', 'a', 'd', ''], room: ['Obvio'],
        health: ['H5'], roundtime: ['T'], kneeling: ['Kneeling'],
        prompt: ['H>'], command: [' stones']
      )
      expect(scrollbars).to eq(
        main: { at: [0, 4, 1, 1], rows: [''], thumb: [0] },
        thoughts: { at: [0, 6, 1, 1], rows: [''], thumb: [] },
        combat: { at: [0, 8, 1, 1], rows: [''], thumb: [] },
        atmo: { at: [0, 6, 1, 1], rows: [''], thumb: [] }
      )
      expect(command.window.curx).to eq 7
    end

    # Every window is drawn again from what it holds; one whose size is
    # the same shows the same cells, colors included.
    #
    # KNOWN BUG, not intended behaviour: the combat tabbed window's
    # scrollbar is left out only because of it. An inactive tabbed window
    # shows no scrollbar while lines arrive, but a full redraw (this resize)
    # draws its inactive scrollbar. It should stay blank (audit §0.2,
    # decisions of 2026-09-30, bucket 3; repro
    # proofs/bucket3/tag-handlers-bridge/bug_tabbed_scrollbar_spec.rb; fix
    # on branch tabbed-inactive-scrollbar). Drop both .except(:combat) calls
    # and this paragraph once that fix lands.
    it 'draws every window the same when the terminal size has not changed' do
      drawn = windows.transform_values { |window| cells(window) }
      bars = scrollbars.except(:combat)

      resize_to(24, 80)

      expect(windows.transform_values { |window| cells(window) }).to eq drawn
      expect(scrollbars.except(:combat)).to eq bars
    end

    it 'leaves everything as it was when the terminal is under 3 lines or under 10 columns' do
      resize_to(12, 40)
      shown = screen_state

      resize_to(2, 80)
      expect(screen_state).to eq shown

      resize_to(24, 9)
      expect(screen_state).to eq shown
    end

    it 'puts every window back where it was built when the terminal returns to its size' do
      [[40, 120], [3, 10], [2, 80], [12, 40], [24, 9]].each { |size| resize_to(*size) }

      resize_to(24, 80)

      expect(geometries).to eq geometries_at_24x80
      expect(screens.slice(:main, :thoughts, :combat, :atmo, :prompt, :command)).to eq(
        main: (5..14).map { |n| "main line #{n}" } + ['a main line long enough to wrap in a', '  narrow window'],
        thoughts: %w[t1 t2 t3] + [''] * 3,
        combat: [' 1:combat | 2:logon', 'c1', 'c2', 'c3', 'c4', 'c5', 'c6'] + [''] * 5,
        atmo: [' 1:atmo | 2:arriva'],
        prompt: ['H>'], command: ['look at the stones']
      )
    end

    # Overlapping windows show whichever was copied to the screen last, so
    # the order the windows are flushed in is part of what the user sees.
    it 'flushes the windows to the screen in the same order on every resize' do
      flushed = []
      windows.each do |name, window|
        record_flushes(window, name, flushed)
        record_flushes(window.scrollbar, :"#{name}_scrollbar", flushed) if window.respond_to?(:scrollbar) && window.scrollbar
      end

      resize_to(40, 120)

      expect(flushed.chunk_while { |a, b| a == b }.map(&:first)).to eq %i[
        main main_scrollbar main thoughts thoughts_scrollbar thoughts
        combat_scrollbar combat combat_scrollbar combat atmo_scrollbar atmo
        exp spells room kneeling prompt health roundtime command prompt command
      ]
    end
  end

  describe 'after a .layout switch' do
    # A second layout: main moves to the bottom half, the kneeling
    # indicator to the top row, and the command line to the right of it.
    let(:second_layout) do
      <<~XML
        <window class='text' top='lines/2' left='0' height='lines/2-1' width='cols' value='main'/>
        <window class='indicator' top='0' left='0' height='1' width='cols/2' value='kneeling' label='Kneel'/>
        <window class='command' top='0' left='cols/2' height='1' width='cols/2'/>
      XML
    end

    before do
      load(every_window_class)
      fill_windows
    end

    it 'keeps the reused text and command windows where they were until the terminal is resized' do
      main = wm.stream['main']

      load(second_layout, id: 'second')

      expect([geometry(main), geometry(wm.command_window)]).to eq [[0, 0, 12, 39], [23, 2, 1, 78]]
    end

    it 'moves a reused indicator to its new place at once, to draw its label there' do
      kneeling = wm.indicator['kneeling']

      load(second_layout, id: 'second')

      expect(geometry(kneeling)).to eq [0, 0, 1, 40]
      expect(kneeling.rows).to eq ['Kneel']
    end

    it 'moves the reused windows to their new places on the next resize' do
      main = wm.stream['main']
      kneeling = wm.indicator['kneeling']
      load(second_layout, id: 'second')

      resize_to(30, 100)

      expect([geometry(main), geometry(kneeling), geometry(wm.command_window)])
        .to eq [[15, 0, 14, 99], [0, 0, 1, 50], [0, 50, 1, 50]]
      expect(main.rows).to eq((2..14).map { |n| "main line #{n}" } + ['a main line long enough to wrap in a narrow window'])
      expect(main.scrollbar.rows).to eq ["\u25B6"] + ["\u2503"] * 12 + ['']
      expect(geometry(main.scrollbar)).to eq [15, 99, 14, 1]
      expect(kneeling.rows).to eq ['Kneel']
      expect(wm.command_window.row(0)).to eq 'look at the stones'
    end

    # The dropped windows are closed, and any call on a closed window
    # raises, so the resize itself proves it left them alone.
    it 'resizes only the windows the new layout kept' do
      dropped = windows.except(:main, :kneeling, :command, :prompt)
      load(second_layout, id: 'second')

      expect { resize_to(30, 100) }.not_to raise_error
      expect(dropped.values.map { |window| window.call_log.last.first }).to all(eq :close)
    end

    it 'resizes the windows of the first layout again after switching back to it' do
      load(second_layout, id: 'second')
      load(every_window_class)

      resize_to(40, 120)

      expect(geometry(wm.stream['main'])).to eq [0, 0, 20, 59]
      expect(geometry(wm.stream['combat'])).to eq [0, 90, 20, 29]
      expect(geometry(wm.indicator['kneeling'])).to eq [18, 70, 1, 10]
      # The prompt is fitted to the last prompt the game sent again.
      expect([geometry(wm.indicator['prompt']), geometry(wm.command_window)]).to eq [[39, 0, 1, 2], [39, 2, 1, 118]]
      expect(wm.indicator['prompt'].rows).to eq ['H>']
    end
  end

  # Adding a window class takes a class and a builder; WindowManager#resize
  # finds it through the class registry.
  describe 'a window class defined outside the window manager' do
    let(:gauge_class) { Class.new(BaseWindow) }

    before do
      gauge = gauge_class
      BaseWindow.register_type('gauge') { |height, width, top, left, _element, _wm| gauge.new(height, width, top, left) }
    end

    after { BaseWindow.type_registry.delete('gauge') }

    it 'is moved and sized with the terminal' do
      load("<window class='gauge' top='lines-2' left='cols/2' height='1' width='cols/2'/>")
      gauge = gauge_class.list.first
      expect(geometry(gauge)).to eq [22, 40, 1, 40]

      resize_to(30, 100)

      expect(geometry(gauge)).to eq [28, 50, 1, 50]
    end
  end
end
