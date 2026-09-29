# frozen_string_literal: true

# The active scrollbar marks the window the scroll keys act on (the
# current scroll window, SCROLL_WINDOW[0]): a bold triangle on its top
# row and a heavy bar below it. It must stay on that window through every
# resize (a terminal resize, .resize, .layout) and move with the switch
# key afterwards. Driven through the real Application, WindowManager and
# windows on the virtual screen (24x80).

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

RSpec.describe 'The active scrollbar across resizes' do
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:main) { app.window_mgr.stream['main'] }
  let(:thoughts) { app.window_mgr.stream['thoughts'] }
  let(:tabbed) { app.window_mgr.stream['combat'] }
  let(:room) { app.window_mgr.room['room'] }

  # Each cell of a scrollbar, top to bottom: :thumb for the reverse-video
  # thumb, else the glyph shown and whether it is bold.
  def scrollbar_cells(window)
    bar = window.scrollbar
    (0...bar.maxy).map do |y|
      attrs = bar.attrs_at(y, 0)
      attrs.anybits?(Curses::A_REVERSE) ? :thumb : [bar.row(y), attrs.anybits?(Curses::A_BOLD)]
    end
  end

  # An active scrollbar over +rows+ text rows, thumb at the bottom.
  def active(rows)
    [[LineBuffered::ACTIVE_INDICATOR, true], *Array.new(rows - 2, [LineBuffered::ACTIVE_SCROLLBAR_CHAR, false]), :thumb]
  end

  # An inactive scrollbar over +rows+ text rows, thumb at the bottom.
  def inactive(rows)
    [*Array.new(rows - 1, [LineBuffered::INACTIVE_SCROLLBAR_CHAR, false]), :thumb]
  end

  def blank(rows) = Array.new(rows, ['', false])

  # The tabbed window's scrollbar starts beside its first text row, below
  # the tab bar.
  def tabbed_cells = scrollbar_cells(tabbed).drop(TabbedTextWindow::TAB_BAR_HEIGHT)

  def terminal_resize = app.send(:handle_key, Curses::KEY_RESIZE, nil)

  def switch_window = app.send(:handle_key, KeyCodes::FALLBACK.fetch('tab'), nil)

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    File.write(settings_path, <<~XML)
      <settings>
        <key id='tab' action='switch_current_window'/>
        <layout id='default'>
          <window class='text' top='0' left='0' height='6' width='40' value='main'/>
          <window class='text' top='0' left='40' height='4' width='40' value='thoughts'/>
          <window class='tabbed' top='8' left='0' height='5' width='40' tabs='combat,logons'/>
          <window class='room' top='14' left='0' height='4' width='40'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
      </settings>
    XML
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    app.send(:load_settings_and_layout)
    # A line in the tabbed window, so that every resize draws its
    # scrollbar, as inactive.
    tabbed.route_string('You swing.', [], 'combat')
    room.update_exits('Obvious paths: north.')
  end

  it 'keeps the marker on the current window after a terminal resize' do
    expect(scrollbar_cells(main)).to eq active(6)

    terminal_resize

    expect(scrollbar_cells(main)).to eq active(6)
    expect(tabbed_cells).to eq inactive(4)
  end

  it 'keeps the marker on the current window after .resize' do
    app.execute_command('.resize')

    expect(scrollbar_cells(main)).to eq active(6)
    expect(tabbed_cells).to eq inactive(4)
  end

  it 'keeps the marker on the current window after .layout' do
    app.execute_command('.layout default')

    expect(scrollbar_cells(main)).to eq active(6)
    expect(tabbed_cells).to eq inactive(4)
  end

  it 'keeps the marker on a current window other than the first text window after a resize' do
    switch_window
    expect(scrollbar_cells(thoughts)).to eq active(4)

    terminal_resize

    expect(scrollbar_cells(thoughts)).to eq active(4)
    # The first text window's scrollbar is drawn again too, as inactive.
    expect(scrollbar_cells(main)).to eq inactive(6)
  end

  it 'moves the marker with the switch key after a resize, onto a window whose scrollbar is drawn' do
    terminal_resize
    switch_window # thoughts, whose scrollbar the resize left blank
    expect(scrollbar_cells(thoughts)).to eq active(4)
    expect(scrollbar_cells(main)).to eq blank(6)

    switch_window # the tabbed window, whose scrollbar the resize drew as inactive

    expect(tabbed_cells).to eq active(4)
    expect(scrollbar_cells(thoughts)).to eq blank(4)

    switch_window # back to main

    expect(scrollbar_cells(main)).to eq active(6)
    expect(tabbed_cells).to eq blank(4)
  end

  it 'leaves a window without a scrollbar as it was' do
    shown = room.rows

    terminal_resize
    switch_window

    expect(room.rows).to eq shown
    expect(room).not_to respond_to(:scrollbar)
  end
end
