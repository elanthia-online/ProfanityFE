# frozen_string_literal: true

# Tab (switch_current_window) on a layout with no text or tabbed window
# has no window to switch to, so it must change nothing: once the user
# loads a layout with text windows again, its first window is the current
# one (it shows the active scrollbar and PageUp scrolls it), and Tab
# cycles through that layout's windows only. Driven through the real
# client (Application#run) on the virtual screen, typing .layout, Tab and
# PageUp as the user does.

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
require_relative '../../lib/application'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../support/client_run'

RSpec.describe 'Tab on a layout without a text window' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:main) { app.window_mgr.stream['main'] }
  let(:thoughts) { app.window_mgr.stream['thoughts'] }
  let(:tab) { KeyCodes::FALLBACK.fetch('tab') }
  let(:page_up) { KeyCodes::FALLBACK.fetch('page_up') }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    allow(ProfanityLog).to receive(:write)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    # 'bare' has an indicator and the command line, but no window Tab can
    # switch to.
    File.write(settings_path, <<~XML)
      <settings>
        <key id='enter' action='send_command'/>
        <key id='tab' action='switch_current_window'/>
        <key id='page_up' action='scroll_current_window_up_page'/>
        <layout id='default'>
          <window class='text' top='0' left='0' height='6' width='40' value='main'/>
          <window class='text' top='0' left='40' height='5' width='39' value='thoughts'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
        <layout id='bare'>
          <window class='indicator' top='0' left='0' height='1' width='10' value='stunned' label='STUN'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
      </settings>
    XML
  end

  # Each cell of a scrollbar, top to bottom: :thumb for the reverse-video
  # thumb, else the glyph shown and whether it is bold.
  def scrollbar_cells(window)
    bar = window.scrollbar
    (0...bar.maxy).map do |y|
      attrs = bar.attrs_at(y, 0)
      attrs.anybits?(Curses::A_REVERSE) ? :thumb : [bar.row(y), attrs.anybits?(Curses::A_BOLD)]
    end
  end

  # An active scrollbar over +rows+ text rows, thumb at row +thumb+ (the
  # marker's row is the top one, drawn over the thumb when it is there).
  def active(rows, thumb:)
    Array.new(rows) do |row|
      if row.zero? then [LineBuffered::ACTIVE_INDICATOR, true]
      elsif row == thumb then :thumb
      else [LineBuffered::ACTIVE_SCROLLBAR_CHAR, false]
      end
    end
  end

  # An inactive window's scrollbar column: blank.
  def blank(rows) = Array.new(rows, ['', false])

  # Keyboard steps: load 'bare', press Tab there, load 'default' again,
  # then show twenty lines in each text window.
  def tab_on_bare_layout
    fill = lambda do
      (1..20).each { |n| main.add_string("m#{n}") }
      (1..20).each { |n| thoughts.add_string("t#{n}") }
    end
    [".layout bare\n", tab, ".layout default\n", fill]
  end

  it 'leaves the first window current: it shows the active scrollbar and PageUp scrolls it' do
    screens = {}
    note = ->(at) { -> { screens[at] = [scrollbar_cells(main), main.rows]; nil } }

    run_client(keyboard(*tab_on_bare_layout, note.call(:before), page_up, note.call(:after)))

    # A page is the window's height less one row.
    expect(screens).to eq(before: [active(6, thumb: 5), %w[m15 m16 m17 m18 m19 m20]],
                          after: [active(6, thumb: 4), %w[m10 m11 m12 m13 m14 m15]])
    expect(thoughts.rows).to eq %w[t16 t17 t18 t19 t20]
  end

  it 'keeps Tab cycling main, thoughts, main' do
    bars = []
    note = -> { -> { bars << [scrollbar_cells(main), scrollbar_cells(thoughts)]; nil } }

    run_client(keyboard(*tab_on_bare_layout, note.call, tab, note.call, tab, note.call, tab, note.call))

    main_current = [active(6, thumb: 5), blank(5)]
    thoughts_current = [blank(6), active(5, thumb: 4)]
    expect(bars).to eq [main_current, thoughts_current, main_current, thoughts_current]
  end
end
