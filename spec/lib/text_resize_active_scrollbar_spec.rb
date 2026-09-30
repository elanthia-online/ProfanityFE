# frozen_string_literal: true

# After a resize (a terminal resize, .resize, .layout) only the active
# window's scrollbar is drawn: the current scroll window (SCROLL_WINDOW[0])
# keeps its marker, and every inactive text window's scrollbar column is
# left blank, as an inactive tabbed window's is
# (spec/lib/tabbed_inactive_scrollbar_spec.rb). The first text window of
# the layout is no exception. Driven through the real Application,
# WindowManager, key actions and windows on the virtual screen (24x80).

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

RSpec.describe 'Text window scrollbars after a resize' do
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:main) { app.window_mgr.stream['main'] }
  let(:thoughts) { app.window_mgr.stream['thoughts'] }
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
  # tab bar row, which the scrollbar never draws on).
  def tabbed_cells = scrollbar_cells(tabbed).drop(TabbedTextWindow::TAB_BAR_HEIGHT)

  # An active scrollbar over +rows+ text rows, thumb at the bottom.
  def active(rows)
    [[LineBuffered::ACTIVE_INDICATOR, true], *Array.new(rows - 2, [LineBuffered::ACTIVE_SCROLLBAR_CHAR, false]), :thumb]
  end

  def blank(rows) = Array.new(rows, ['', false])

  def press(action) = app.key_action.fetch(action).call

  def terminal_size(lines:, cols:)
    allow(Curses).to receive_messages(lines: lines, cols: cols)
  end

  # Make the next window in SCROLL_WINDOW the current one, +times+ times,
  # as the switch_current_window key does.
  def switch_window(times = 1)
    times.times { press('switch_current_window') }
  end

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    # SCROLL_WINDOW is main, thoughts, then the tabbed window. 'moved'
    # keeps the same windows (so .layout reuses them) in other places.
    File.write(settings_path, <<~XML)
      <settings>
        <layout id='default'>
          <window class='text' top='0' left='0' height='6' width='40' value='main'/>
          <window class='text' top='0' left='40' height='4' width='39' value='thoughts'/>
          <window class='tabbed' top='8' left='0' height='5' width='40' tabs='combat,logons'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
        <layout id='moved'>
          <window class='text' top='2' left='10' height='7' width='50' value='main'/>
          <window class='text' top='12' left='40' height='5' width='30' value='thoughts'/>
          <window class='tabbed' top='14' left='0' height='5' width='38' tabs='combat,logons'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
      </settings>
    XML
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    SettingsLoader.load(settings_path, app.key_binding, app.key_action, app.method(:do_macro))
    app.execute_command('.layout default')
    # More lines than the text rows in every window, so every scrollbar
    # drawn has a thumb and a bar.
    (1..10).each do |n|
      main.add_string("m#{n}")
      thoughts.add_string("t#{n}")
      tabbed.route_string("c#{n}", [], 'combat')
    end
  end

  it 'starts with only the first window, the current one, showing its scrollbar' do
    expect(SCROLL_WINDOW).to eq [main, thoughts, tabbed]
    expect(scrollbar_cells(main)).to eq active(6)
    expect(scrollbar_cells(thoughts)).to eq blank(4)
    expect(tabbed_cells).to eq blank(4)
  end

  context 'when the tabbed window is the current one' do
    before { switch_window(2) }

    it 'shows only its scrollbar before any resize' do
      expect(tabbed_cells).to eq active(4)
      expect(scrollbar_cells(main)).to eq blank(6)
      expect(scrollbar_cells(thoughts)).to eq blank(4)
    end

    it 'leaves the first text window\'s scrollbar blank after a terminal resize to the same size' do
      press('resize')

      expect(scrollbar_cells(main)).to eq blank(6)
      expect(scrollbar_cells(thoughts)).to eq blank(4)
      expect(tabbed_cells).to eq active(4)
      expect(main.rows).to eq %w[m5 m6 m7 m8 m9 m10]
    end

    it 'leaves the first text window\'s scrollbar blank after a terminal resize to another size' do
      terminal_size(lines: 30, cols: 100)

      press('resize')

      expect(scrollbar_cells(main)).to eq blank(6)
      expect(scrollbar_cells(thoughts)).to eq blank(4)
      expect(tabbed_cells).to eq active(4)
    end

    it 'leaves the first text window\'s scrollbar blank after .resize' do
      app.execute_command('.resize')

      expect(scrollbar_cells(main)).to eq blank(6)
      expect(scrollbar_cells(thoughts)).to eq blank(4)
      expect(tabbed_cells).to eq active(4)
    end

    it 'leaves the first text window\'s scrollbar blank when .layout reuses it in place' do
      app.execute_command('.layout default')

      expect(SCROLL_WINDOW.first).to be tabbed
      expect(scrollbar_cells(main)).to eq blank(6)
      expect(scrollbar_cells(thoughts)).to eq blank(4)
      expect(tabbed_cells).to eq active(4)
    end

    it 'leaves the first text window\'s scrollbar blank where .layout moves it' do
      app.execute_command('.layout moved')

      expect(scrollbar_cells(main)).to eq blank(7)
      expect(main.scrollbar.begy).to eq 2
      # The window keeps its right column for the scrollbar: 49 columns
      # from column 10, then the scrollbar.
      expect(main.scrollbar.begx).to eq 59
      expect(scrollbar_cells(thoughts)).to eq blank(5)
      expect(tabbed_cells).to eq active(4)
    end

    # Scrolling an inactive window (as a drag held at its edge does)
    # leaves its scrollbar blank (spec/lib/text_inactive_scrollbar_spec.rb),
    # and so does the resize.
    it 'leaves a scrolled inactive text window\'s scrollbar blank, and keeps its view' do
      main.scroll_lines(-2)
      expect(scrollbar_cells(main)).to eq blank(6)

      press('resize')

      expect(scrollbar_cells(main)).to eq blank(6)
      expect(main.rows).to eq %w[m3 m4 m5 m6 m7 m8]
      expect(tabbed_cells).to eq active(4)
    end
  end

  context 'when the second text window is the current one' do
    before { switch_window }

    it 'draws only its scrollbar after a terminal resize' do
      press('resize')

      expect(scrollbar_cells(thoughts)).to eq active(4)
      expect(scrollbar_cells(main)).to eq blank(6)
      expect(tabbed_cells).to eq blank(4)
    end
  end

  context 'when the first text window is the current one' do
    it 'keeps drawing its scrollbar, and only its, after a terminal resize' do
      press('resize')

      expect(scrollbar_cells(main)).to eq active(6)
      expect(scrollbar_cells(thoughts)).to eq blank(4)
      expect(tabbed_cells).to eq blank(4)
    end
  end
end
