# frozen_string_literal: true

# The active window's scrollbar shows the active marker (a bold triangle)
# on its top row whenever the thumb isn't there; with the view at the
# oldest line the thumb covers that row. Moving the thumb redraws only
# the cell it left and the one it moved to, and the cell it left on the
# top row used to get the bar glyph: once the thumb had been on the top
# row, the marker was gone until the next full redraw (a resize, a layout
# or a window switch). Text and tabbed windows alike. Driven through the
# real Application, WindowManager, key actions and windows on the virtual
# screen (24x80).

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

RSpec.describe 'The active marker on the scrollbar' do
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:main) { app.window_mgr.stream['main'] }
  let(:tabbed) { app.window_mgr.stream['combat'] }

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
  # tab bar row).
  def tabbed_cells = scrollbar_cells(tabbed).drop(TabbedTextWindow::TAB_BAR_HEIGHT)

  # An active scrollbar over +rows+ text rows with the thumb at row
  # +thumb+: the marker on the top row unless the thumb is there, the bar
  # everywhere else.
  def active(rows, thumb:)
    Array.new(rows) do |row|
      if row == thumb then :thumb
      elsif row.zero? then [LineBuffered::ACTIVE_INDICATOR, true]
      else
        [LineBuffered::ACTIVE_SCROLLBAR_CHAR, false]
      end
    end
  end

  def press(action) = app.key_action.fetch(action).call

  # Scroll the current window back to its oldest line: page up until the
  # view stops moving.
  def scroll_to_top
    window = SCROLL_WINDOW[0]
    loop do
      before = window.buffer_pos
      press('scroll_current_window_up_page')
      break if window.buffer_pos == before
    end
  end

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    # main: 5 text rows. The tabbed window: 4 text rows below its tab bar
    # at 24 lines (its height follows the terminal).
    File.write(settings_path, <<~XML)
      <settings>
        <layout id='default'>
          <window class='text' top='0' left='0' height='5' width='40' value='main'/>
          <window class='tabbed' top='8' left='0' height='lines-19' width='40' tabs='combat,logons,empty'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
      </settings>
    XML
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    SettingsLoader.load(settings_path, app.key_binding, app.key_action, app.method(:do_macro))
    app.execute_command('.layout default')
  end

  describe 'on the active text window' do
    before do
      (1..20).each { |n| main.add_string("m#{n}") }
      expect(SCROLL_WINDOW.first).to be main
      scroll_to_top
      expect(main.buffer_pos).to be_positive
    end

    it 'is covered by the thumb while the view is at the oldest line' do
      expect(scrollbar_cells(main)).to eq active(5, thumb: 0)
    end

    it 'comes back when scrolling down one line at a time moves the thumb off the top row' do
      press('scroll_current_window_down_one') until scrollbar_cells(main).first != :thumb

      expect(scrollbar_cells(main)).to eq active(5, thumb: 1)
    end

    it 'comes back when a page scroll moves the thumb off the top row' do
      press('scroll_current_window_down_page')

      expect(scrollbar_cells(main).first).to eq [LineBuffered::ACTIVE_INDICATOR, true]
      expect(scrollbar_cells(main).count(:thumb)).to eq 1
    end

    it 'comes back when the view returns to the newest line' do
      press('scroll_current_window_bottom')

      expect(main.rows.last).to eq 'm20'
      expect(scrollbar_cells(main)).to eq active(5, thumb: 4)
    end

    it 'comes back each time the thumb leaves the top row' do
      3.times do
        press('scroll_current_window_bottom')
        expect(scrollbar_cells(main)).to eq active(5, thumb: 4)

        scroll_to_top
        expect(scrollbar_cells(main)).to eq active(5, thumb: 0)
      end
    end

    it 'is covered by the thumb after a resize at the oldest line, and comes back when the thumb leaves' do
      press('resize')
      expect(scrollbar_cells(main)).to eq active(5, thumb: 0)

      press('scroll_current_window_bottom')

      expect(scrollbar_cells(main)).to eq active(5, thumb: 4)
    end

    it 'is covered by the thumb after the window becomes active again at the oldest line, and comes back' do
      press('switch_current_window') # the tabbed window
      press('switch_current_window') # main again
      expect(scrollbar_cells(main)).to eq active(5, thumb: 0)

      press('scroll_current_window_bottom')

      expect(scrollbar_cells(main)).to eq active(5, thumb: 4)
    end
  end

  describe 'on the active tabbed window' do
    before do
      press('switch_current_window')
      expect(SCROLL_WINDOW.first).to be tabbed
      (1..10).each { |n| tabbed.route_string("c#{n}", [], 'combat') }
      (1..10).each { |n| tabbed.route_string("l#{n}", [], 'logons') }
      scroll_to_top
      expect(tabbed.rows.drop(1)).to eq ['c1', 'c2', 'c3', 'c4']
    end

    it 'is covered by the thumb while the shown tab is at its oldest line' do
      expect(tabbed_cells).to eq active(4, thumb: 0)
    end

    it 'comes back when scrolling down one line at a time moves the thumb off the top row' do
      press('scroll_current_window_down_one') until tabbed_cells.first != :thumb

      expect(tabbed_cells).to eq active(4, thumb: 1)
    end

    it 'comes back when the view returns to the newest line' do
      press('scroll_current_window_bottom')

      expect(tabbed.rows.last).to eq 'c10'
      expect(tabbed_cells).to eq active(4, thumb: 3)
    end

    it 'comes back on a switch to a tab showing its newest line' do
      press('next_tab')

      expect(tabbed.rows.drop(1)).to eq ['l7', 'l8', 'l9', 'l10']
      expect(tabbed_cells).to eq active(4, thumb: 3)
    end

    it 'comes back on a switch to an empty tab' do
      app.execute_command('.tab empty')

      expect(tabbed.rows.drop(1)).to eq ['', '', '', '']
      expect(tabbed_cells).to eq active(4, thumb: 3)
    end

    it 'is covered by the thumb again on a switch back to the tab at its oldest line' do
      press('next_tab')
      press('prev_tab')

      expect(tabbed.rows.drop(1)).to eq ['c1', 'c2', 'c3', 'c4']
      expect(tabbed_cells).to eq active(4, thumb: 0)
    end

    it 'is covered by the thumb after a resize at the oldest line, and comes back when the thumb leaves' do
      press('resize')
      expect(tabbed_cells).to eq active(4, thumb: 0)

      press('scroll_current_window_bottom')

      expect(tabbed_cells).to eq active(4, thumb: 3)
    end

    it 'comes back when the thumb leaves the top row of a taller window after a resize' do
      allow(Curses).to receive(:lines).and_return(26)
      press('resize')
      expect(tabbed.maxy).to eq 7
      scroll_to_top
      expect(tabbed_cells).to eq active(6, thumb: 0)

      press('scroll_current_window_down_page')

      expect(tabbed_cells.first).to eq [LineBuffered::ACTIVE_INDICATOR, true]
      expect(tabbed_cells.count(:thumb)).to eq 1
    end
  end

  # Only the active window shows the marker: an inactive window scrolled
  # (a drag held at its edge scrolls it) never gets one.
  it 'never shows on an inactive text window whose thumb leaves the top row' do
    (1..20).each { |n| main.add_string("m#{n}") }
    press('switch_current_window') # the tabbed window
    expect(main).not_to be_active

    main.scroll_lines(-100)
    main.scroll_lines(100)

    expect(scrollbar_cells(main)).not_to include [LineBuffered::ACTIVE_INDICATOR, true]
  end
end
