# frozen_string_literal: true

# The active tabbed window (the current scroll window, SCROLL_WINDOW[0],
# the one the scroll keys act on) shows its scrollbar whatever its shown
# tab holds. With an empty tab it looks as an active text window with an
# empty buffer does: the active marker on top, the bar, and the thumb at
# the bottom (a live view). A redraw used to return before the scrollbar
# when the shown tab was empty, so a terminal resize (even to the same
# size), .resize or .layout left the column blank, and switching from a
# scrolled-back tab to an empty one left the old tab's thumb where it
# was. An inactive tabbed window stays blank (#206). Driven through the
# real Application, WindowManager, key actions and windows on the
# virtual screen (24x80).

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

RSpec.describe 'A tabbed window whose shown tab is empty' do
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

  # The cell beside the tab bar.
  def tab_bar_cell = scrollbar_cells(tabbed).first

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
        <layout id='one_row'>
          <window class='text' top='0' left='0' height='6' width='40' value='main'/>
          <window class='tabbed' top='8' left='0' height='1' width='40' tabs='combat,logons'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
        <layout id='two_rows'>
          <window class='text' top='0' left='0' height='6' width='40' value='main'/>
          <window class='tabbed' top='8' left='0' height='2' width='40' tabs='combat,logons'/>
          <window class='text' top='12' left='0' height='1' width='40' value='thoughts'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
      </settings>
    XML
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    SettingsLoader.load(settings_path, app.key_binding, app.key_action, app.method(:do_macro))
    app.execute_command('.layout default')
  end

  # What the tabbed window has to match: an active text window with an
  # empty buffer keeps its scrollbar through a resize and set_active.
  # (The Application fills each new text window with blank rows, so the
  # empty one is built with a WindowManager of its own.)
  it 'matches an active text window with an empty buffer, which keeps its scrollbar' do
    wm = WindowManager.new
    LAYOUT['empty_text'] = REXML::Document.new(<<~XML).root
      <layout><window class='text' top='0' left='0' height='5' width='40' value='empty'/></layout>
    XML
    wm.load_layout('empty_text')
    text = wm.stream['empty']
    expect(text.buffer).to be_empty
    expect(SCROLL_WINDOW).to eq [text]
    expect(scrollbar_cells(text)).to eq active(5)

    wm.resize(nil)
    expect(scrollbar_cells(text)).to eq active(5)

    terminal_size(lines: 26, cols: 100)
    wm.resize(nil)
    expect(scrollbar_cells(text)).to eq active(5)

    text.set_active(false)
    text.set_active(true)
    expect(scrollbar_cells(text)).to eq active(5)
  end

  describe 'when the window is the active one' do
    before { press('switch_current_window') }

    it 'shows its scrollbar once it becomes active' do
      expect(SCROLL_WINDOW.first).to be tabbed
      expect(tabbed.tabs).to eq('combat' => [], 'logons' => [])
      expect(tabbed_cells).to eq active(text_rows)
    end

    it 'shows its scrollbar again when it becomes active again' do
      press('switch_current_window') # main
      expect(tabbed_cells).to eq blank(text_rows)

      press('switch_current_window') # the tabbed window again

      expect(tabbed_cells).to eq active(text_rows)
    end

    describe 'after a terminal resize (what KEY_RESIZE runs)' do
      it 'shows its scrollbar when the size is the same' do
        press('resize')

        expect(tabbed.rows).to eq [' 1:combat | 2:logons', '', '', '', '']
        expect(tabbed_cells).to eq active(text_rows)
        expect(tab_bar_cell).to eq ['', false]
      end

      it 'shows its scrollbar when the terminal grew' do
        terminal_size(lines: 26, cols: 100)

        press('resize')

        expect(tabbed.maxy).to eq 7
        expect(tabbed_cells).to eq active(6)
      end

      it 'shows its scrollbar when the terminal shrank' do
        terminal_size(lines: 22)

        press('resize')

        expect(tabbed.maxy).to eq 3
        expect(tabbed_cells).to eq active(2)
      end

      it 'still shows it once lines arrive in the shown tab' do
        press('resize')

        tabbed.route_string('c1', [], 'combat')

        expect(tabbed.rows).to eq [' 1:combat | 2:logons', 'c1', '', '', '']
        expect(tabbed_cells).to eq active(text_rows)
      end
    end

    it 'shows its scrollbar after .resize' do
      app.execute_command('.resize')

      expect(tabbed_cells).to eq active(text_rows)
    end

    describe 'when .layout reuses it' do
      it 'shows its scrollbar in the same place' do
        app.execute_command('.layout default')

        expect(app.window_mgr.stream['combat']).to be tabbed
        expect(tabbed_cells).to eq active(text_rows)
      end

      it 'shows its scrollbar where the new layout moves it' do
        app.execute_command('.layout moved')

        expect(app.window_mgr.stream['combat']).to be tabbed
        expect([tabbed.begy, tabbed.begx, tabbed.maxx]).to eq [10, 20, 49]
        expect(tabbed_cells).to eq active(text_rows)
      end
    end

    describe 'on a tab switch' do
      it 'keeps its scrollbar switching between two empty tabs' do
        press('next_tab')
        expect(tabbed.active_tab).to eq 'logons'
        expect(tabbed_cells).to eq active(text_rows)

        app.execute_command('.tab 1')
        expect(tabbed.active_tab).to eq 'combat'
        expect(tabbed_cells).to eq active(text_rows)
      end

      # The other tab is scrolled back two lines: its thumb is two rows
      # above the bottom. The empty tab shows a live view (thumb at the
      # bottom), and switching back shows the other tab's place again.
      it 'moves the thumb to the bottom for an empty tab and back for a scrolled-back one' do
        (1..8).each { |n| tabbed.route_string("c#{n}", [], 'combat') }
        2.times { press('scroll_current_window_up_one') }
        expect(tabbed.rows).to eq [' 1:combat | 2:logons', 'c3', 'c4', 'c5', 'c6']
        expect(tabbed_cells).to eq active(text_rows, thumb: 1)

        press('next_tab')
        expect(tabbed.rows).to eq [' 1:combat | 2:logons', '', '', '', '']
        expect(tabbed_cells).to eq active(text_rows)

        press('prev_tab')
        expect(tabbed.rows).to eq [' 1:combat | 2:logons', 'c3', 'c4', 'c5', 'c6']
        expect(tabbed_cells).to eq active(text_rows, thumb: 1)
      end

      # The other tab is scrolled to the top: its thumb is on the marker's
      # row. The switch moves the thumb to the bottom with the same
      # incremental update a text window uses when its thumb leaves the
      # top row, so the empty tab's column is the one an active text
      # window shows after it is scrolled to the top and back to the
      # bottom, whatever that looks like (today the bar glyph on the top
      # row, with no marker until the next full redraw; an open question
      # for the maintainer, shared with text windows and full tabs).
      it 'moves the thumb off the top row as an active text window does, leaving no stale thumb' do
        (1..8).each { |n| tabbed.route_string("c#{n}", [], 'combat') }
        10.times { press('scroll_current_window_up_one') }
        expect(tabbed.rows).to eq [' 1:combat | 2:logons', 'c1', 'c2', 'c3', 'c4']
        expect(tabbed_cells).to eq active(text_rows, thumb: 0)

        press('next_tab')
        expect(tabbed.rows).to eq [' 1:combat | 2:logons', '', '', '', '']
        empty_tab_cells = tabbed_cells
        expect(empty_tab_cells.last).to eq :thumb
        expect(empty_tab_cells[0...-1]).not_to include :thumb

        # The reference: an active text window with as many rows, scrolled
        # to the top and back to the bottom (built last: a WindowManager of
        # its own replaces the scroll windows).
        wm = WindowManager.new
        LAYOUT['top_and_back'] = REXML::Document.new(<<~XML).root
          <layout><window class='text' top='0' left='0' height='#{text_rows}' width='40' value='ref'/></layout>
        XML
        wm.load_layout('top_and_back')
        text = wm.stream['ref']
        (1..8).each { |n| text.add_string("r#{n}") }
        expect(text).to be_active
        expect(scrollbar_cells(text)).to eq active(text_rows)
        text.scroll_lines(-10)
        expect(scrollbar_cells(text)).to eq active(text_rows, thumb: 0)
        text.scroll_lines(10)

        expect(empty_tab_cells).to eq scrollbar_cells(text)
      end

      it 'keeps its scrollbar after a resize on the empty tab and a switch to a full one' do
        (1..8).each { |n| tabbed.route_string("c#{n}", [], 'combat') }
        press('next_tab')

        press('resize')
        expect(tabbed_cells).to eq active(text_rows)

        press('prev_tab')
        expect(tabbed.rows).to eq [' 1:combat | 2:logons', 'c5', 'c6', 'c7', 'c8']
        expect(tabbed_cells).to eq active(text_rows)
      end
    end
  end

  # #206: an inactive tabbed window shows no scrollbar on any path, empty
  # tab or not.
  describe 'when the window is not the active one' do
    it 'shows no scrollbar after a resize, .resize, .layout or a tab switch' do
      expect(tabbed).not_to be_active
      expect(tabbed_cells).to eq blank(text_rows)

      press('resize')
      expect(tabbed_cells).to eq blank(text_rows)

      app.execute_command('.resize')
      expect(tabbed_cells).to eq blank(text_rows)

      app.execute_command('.layout moved')
      expect(tabbed_cells).to eq blank(text_rows)

      press('next_tab')
      expect(tabbed_cells).to eq blank(text_rows)
      expect(scrollbar_cells(main)).to eq active(6)
    end

    it 'shows no scrollbar after it stops being active and is resized' do
      press('switch_current_window') # the tabbed window
      press('switch_current_window') # main

      press('resize')

      expect(tabbed_cells).to eq blank(text_rows)
    end
  end

  # A one-row tabbed window shows only its tab bar (no text rows, so no
  # scrollbar cells); a two-row one has one text row, whose scrollbar is
  # the thumb alone, as a one-row text window's is (#121, #123).
  describe 'with one or two rows' do
    it 'shows no scrollbar beside a one-row window, active, after a resize or a tab switch' do
      app.execute_command('.layout one_row')
      press('switch_current_window')
      expect(SCROLL_WINDOW.first).to be tabbed
      expect(tabbed.maxy).to eq 1

      press('resize')
      expect(scrollbar_cells(tabbed)).to eq blank(1)

      press('next_tab')
      expect(tabbed.rows).to eq [' 1:combat | 2:logons']
      expect(scrollbar_cells(tabbed)).to eq blank(1)
    end

    it 'shows the thumb beside a two-row window, as a one-row text window does' do
      app.execute_command('.layout two_rows')
      one_row_text = app.window_mgr.stream['thoughts']
      expect(one_row_text).to be_a TextWindow
      press('switch_current_window') # the tabbed window
      expect(SCROLL_WINDOW.first).to be tabbed
      expect(tabbed.maxy).to eq 2

      press('resize')
      expect(tabbed_cells).to eq [:thumb]
      expect(tab_bar_cell).to eq ['', false]

      press('next_tab')
      expect(tabbed_cells).to eq [:thumb]

      press('switch_current_window') # the one-row text window
      expect(SCROLL_WINDOW.first).to be one_row_text
      expect(scrollbar_cells(one_row_text)).to eq [:thumb]
    end
  end
end
