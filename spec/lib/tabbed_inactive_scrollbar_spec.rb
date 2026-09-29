# frozen_string_literal: true

# An inactive tabbed window (one the scroll keys don't act on: not the
# current scroll window, SCROLL_WINDOW[0]) shows no scrollbar. Lines
# arriving never drew it; a redraw must not draw it either, whatever runs
# the redraw: a terminal resize (to the same size or another), .resize,
# .layout reusing the window, a tab switch, clearing a selection. The
# active window's scrollbar is drawn on every one of those paths, as
# before. Driven through the real Application, WindowManager, key actions
# and windows on the virtual screen (24x80).

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

RSpec.describe 'An inactive tabbed window' do
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:main) { app.window_mgr.stream['main'] }
  let(:tabbed) { app.window_mgr.stream['combat'] }

  # Rows of text below the tab bar: the tabbed window is 5 rows high.
  let(:text_rows) { 4 }

  # Each cell of a scrollbar, top to bottom: :thumb for the reverse-video
  # thumb, else the glyph shown and whether it is bold.
  def scrollbar_cells(window)
    bar = window.scrollbar
    (0...bar.maxy).map do |y|
      attrs = bar.attrs_at(y, 0)
      attrs.anybits?(Curses::A_REVERSE) ? :thumb : [bar.row(y), attrs.anybits?(Curses::A_BOLD)]
    end
  end

  # The tabbed window's scrollbar cells beside its text rows (below the
  # tab bar row, which the scrollbar never draws on).
  def tabbed_cells = scrollbar_cells(tabbed).drop(TabbedTextWindow::TAB_BAR_HEIGHT)

  # An active scrollbar over +rows+ text rows, thumb at row +thumb+
  # (default: the bottom, a live view).
  def active(rows, thumb: rows - 1)
    Array.new(rows) do |row|
      if row == thumb then :thumb
      elsif row.zero? then [LineBuffered::ACTIVE_INDICATOR, true]
      else
        [LineBuffered::ACTIVE_SCROLLBAR_CHAR, false]
      end
    end
  end

  def blank(rows) = Array.new(rows, ['', false])

  def press(action) = app.key_action.fetch(action).call

  def terminal_size(lines:, cols: 80)
    allow(Curses).to receive(:lines).and_return(lines)
    allow(Curses).to receive(:cols).and_return(cols)
  end

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    # The tabbed window's height follows the terminal: 5 rows at 24 lines.
    File.write(settings_path, <<~XML)
      <settings>
        <layout id='default'>
          <window class='text' top='0' left='0' height='6' width='40' value='main'/>
          <window class='tabbed' top='8' left='0' height='lines-19' width='40' tabs='combat,logons'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
        <layout id='moved'>
          <window class='text' top='0' left='0' height='6' width='40' value='main'/>
          <window class='tabbed' top='10' left='20' height='5' width='50' tabs='combat,logons'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
      </settings>
    XML
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    SettingsLoader.load(settings_path, app.key_binding, app.key_action, app.method(:do_macro))
    app.execute_command('.layout default')
    # More lines than the text rows, in both tabs, so every scrollbar
    # drawn has a thumb and a bar.
    (1..8).each do |n|
      tabbed.route_string("c#{n}", [], 'combat')
      tabbed.route_string("l#{n}", [], 'logons')
    end
  end

  it 'is the tabbed window, and the main window is the active one' do
    expect(SCROLL_WINDOW.first).to be main
    expect(tabbed).not_to be_active
    expect(scrollbar_cells(main)).to eq active(6)
  end

  it 'shows no scrollbar while lines arrive' do
    expect(tabbed.rows).to eq [' 1:combat | 2:logons*', 'c5', 'c6', 'c7', 'c8']
    expect(tabbed_cells).to eq blank(text_rows)
  end

  describe 'after a terminal resize (what KEY_RESIZE runs)' do
    it 'shows no scrollbar when the size is the same' do
      press('resize')

      expect(tabbed.rows).to eq [' 1:combat | 2:logons*', 'c5', 'c6', 'c7', 'c8']
      expect(tabbed_cells).to eq blank(text_rows)
      expect(scrollbar_cells(main)).to eq active(6)
    end

    it 'shows no scrollbar when the terminal grew' do
      terminal_size(lines: 26, cols: 100)

      press('resize')

      expect(tabbed.rows).to eq [' 1:combat | 2:logons*', 'c3', 'c4', 'c5', 'c6', 'c7', 'c8']
      expect(tabbed_cells).to eq blank(6)
      expect(scrollbar_cells(main)).to eq active(6)
    end

    it 'shows no scrollbar when the terminal shrank' do
      terminal_size(lines: 22)

      press('resize')

      expect(tabbed.rows).to eq [' 1:combat | 2:logons*', 'c7', 'c8']
      expect(tabbed_cells).to eq blank(2)
    end
  end

  it 'shows no scrollbar after .resize' do
    app.execute_command('.resize')

    expect(tabbed_cells).to eq blank(text_rows)
    expect(scrollbar_cells(main)).to eq active(6)
  end

  describe 'when .layout reuses it' do
    it 'shows no scrollbar in the same place' do
      app.execute_command('.layout default')

      expect(app.window_mgr.stream['combat']).to be tabbed
      expect(tabbed_cells).to eq blank(text_rows)
      expect(scrollbar_cells(main)).to eq active(6)
    end

    it 'shows no scrollbar where the new layout moves it' do
      app.execute_command('.layout moved')

      expect(app.window_mgr.stream['combat']).to be tabbed
      expect([tabbed.begy, tabbed.begx, tabbed.maxx]).to eq [10, 20, 49]
      expect(tabbed.rows).to eq [' 1:combat | 2:logons*', 'c5', 'c6', 'c7', 'c8']
      expect(tabbed_cells).to eq blank(text_rows)
      expect(scrollbar_cells(main)).to eq active(6)
    end
  end

  describe 'on a tab switch' do
    it 'shows no scrollbar after the next-tab key' do
      press('next_tab')

      expect(tabbed.rows).to eq [' 1:combat | 2:logons', 'l5', 'l6', 'l7', 'l8']
      expect(tabbed_cells).to eq blank(text_rows)
    end

    it 'shows no scrollbar after the previous-tab key' do
      press('prev_tab')

      expect(tabbed.active_tab).to eq 'logons'
      expect(tabbed_cells).to eq blank(text_rows)
    end

    it 'shows no scrollbar after a tab-number key' do
      press('switch_tab_2')

      expect(tabbed.active_tab).to eq 'logons'
      expect(tabbed_cells).to eq blank(text_rows)
    end

    it 'shows no scrollbar after .tab with a number or a name' do
      app.execute_command('.tab 2')
      expect(tabbed.active_tab).to eq 'logons'
      expect(tabbed_cells).to eq blank(text_rows)

      app.execute_command('.tab combat')
      expect(tabbed.active_tab).to eq 'combat'
      expect(tabbed_cells).to eq blank(text_rows)
    end
  end

  it 'shows no scrollbar after a selection in it is cleared' do
    first_row = tabbed.selection_anchor_at(1, 0).first
    tabbed.highlight_selection(first_row, 0, first_row, 2)

    tabbed.clear_highlight

    expect(tabbed.rows).to eq [' 1:combat | 2:logons*', 'c5', 'c6', 'c7', 'c8']
    expect(tabbed_cells).to eq blank(text_rows)
  end

  # A redraw doesn't touch the scrollbar window of an inactive tabbed
  # window at all, so nothing is copied to that column of the screen: a
  # window drawn there by a layout that overlaps it stays as it was.
  it 'leaves its scrollbar column alone on a tab switch' do
    tabbed.scrollbar.call_log.clear

    press('next_tab')

    expect(tabbed.scrollbar.call_log).to be_empty
  end

  describe 'after it stops being the active window' do
    before do
      press('switch_current_window') # the tabbed window
      expect(tabbed_cells).to eq active(text_rows)
      press('switch_current_window') # back to main
    end

    it 'shows no scrollbar once main is active again' do
      expect(scrollbar_cells(main)).to eq active(6)
      expect(tabbed_cells).to eq blank(text_rows)
    end

    it 'shows no scrollbar after a resize, a tab switch or .layout' do
      press('resize')
      expect(tabbed_cells).to eq blank(text_rows)

      press('next_tab')
      expect(tabbed_cells).to eq blank(text_rows)

      app.execute_command('.layout default')
      expect(tabbed_cells).to eq blank(text_rows)
      expect(scrollbar_cells(main)).to eq active(6)
    end
  end

  # The only way to scroll an inactive window is a drag held at its edge
  # (the scroll keys and the wheel act on the active window). Decided
  # (2026-09-30) like a redraw, blank unless the window is active: the
  # scrollbar stays blank, before and after lines arrive in the
  # scrolled-back view, and after the drag scrolls it back down.
  describe 'when a drag scrolls it' do
    it 'shows no scrollbar while scrolled back, as lines arrive, or once back at the bottom' do
      expect(tabbed.drag_auto_scroll(0)).to be true
      expect(tabbed.rows).to eq [' 1:combat | 2:logons*', 'c4', 'c5', 'c6', 'c7']
      expect(tabbed_cells).to eq blank(text_rows)

      tabbed.route_string('c9', [], 'combat')
      expect(tabbed.rows).to eq [' 1:combat | 2:logons*', 'c4', 'c5', 'c6', 'c7']
      expect(tabbed_cells).to eq blank(text_rows)

      expect(tabbed.drag_auto_scroll(tabbed.maxy - 1)).to be true
      expect(tabbed.drag_auto_scroll(tabbed.maxy - 1)).to be true
      expect(tabbed.rows).to eq [' 1:combat | 2:logons*', 'c6', 'c7', 'c8', 'c9']
      expect(tabbed_cells).to eq blank(text_rows)
    end

    it 'shows no scrollbar when a lowered buffer size moves the scrolled-back view' do
      4.times { tabbed.drag_auto_scroll(0) }
      expect(tabbed.rows).to eq [' 1:combat | 2:logons*', 'c1', 'c2', 'c3', 'c4']

      tabbed.max_buffer_size = 6

      expect(tabbed.rows).to eq [' 1:combat | 2:logons*', 'c3', 'c4', 'c5', 'c6']
      expect(tabbed_cells).to eq blank(text_rows)
    end
  end

  # The wheel runs the scroll-one-line actions, which act on the active
  # window whatever the pointer is over.
  it 'is not scrolled by the wheel over it: the active window is' do
    allow(ProfanitySettings).to receive(:load_mouse_settings)
      .and_return('BUTTON4_PRESSED_MASK' => 0x10000, 'BUTTON5_PRESSED_MASK' => 0x200000)
    (1..10).each { |n| main.add_string("m#{n}") }
    wheel = MouseScroll.new(app.key_action, ->(_text) {})
    over_tabbed = Struct.new(:bstate, :x, :y).new(0x10000, 5, tabbed.begy + 2)

    wheel.process(over_tabbed)

    expect(tabbed.buffer_pos).to eq 0
    expect(tabbed_cells).to eq blank(text_rows)
    expect(main.buffer_pos).to eq 1
    expect(scrollbar_cells(main)).to eq active(6, thumb: 4)
  end

  describe 'once it is the active window' do
    before { press('switch_current_window') }

    it 'shows its scrollbar, and the main window shows none' do
      expect(tabbed_cells).to eq active(text_rows)
      expect(scrollbar_cells(main)).to eq blank(6)
    end

    it 'shows its scrollbar after a terminal resize to the same size or another' do
      press('resize')
      expect(tabbed_cells).to eq active(text_rows)

      terminal_size(lines: 26, cols: 100)
      press('resize')
      expect(tabbed_cells).to eq active(6)
    end

    it 'shows its scrollbar after .layout reuses it, in place or moved' do
      app.execute_command('.layout default')
      expect(tabbed_cells).to eq active(text_rows)

      app.execute_command('.layout moved')
      expect(tabbed_cells).to eq active(text_rows)
    end

    it 'shows its scrollbar after a tab switch, by key or .tab' do
      press('next_tab')
      expect(tabbed_cells).to eq active(text_rows)

      app.execute_command('.tab 1')
      expect(tabbed_cells).to eq active(text_rows)
    end

    it 'moves its thumb as the scroll keys scroll it' do
      press('scroll_current_window_up_one')
      expect(tabbed_cells).to eq active(text_rows, thumb: 2)

      press('scroll_current_window_bottom')
      expect(tabbed_cells).to eq active(text_rows)
    end

    it 'shows its scrollbar after a selection in it is cleared' do
      first_row = tabbed.selection_anchor_at(1, 0).first
      tabbed.highlight_selection(first_row, 0, first_row, 2)

      tabbed.clear_highlight

      expect(tabbed_cells).to eq active(text_rows)
    end
  end
end
