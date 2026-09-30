# frozen_string_literal: true

# An inactive text window (one the scroll keys don't act on: not the
# current scroll window, SCROLL_WINDOW[0]) shows no scrollbar, on every
# path, as an inactive tabbed window shows none
# (spec/lib/tabbed_inactive_scrollbar_spec.rb): not while a drag held at
# its edge scrolls it, not as lines arrive while it is scrolled back, not
# when a lowered buffer size moves its view, and none is left behind
# once its view is back at the bottom. The active window's scrollbar is
# drawn as before. Driven through the real Application, WindowManager,
# key actions and windows on the virtual screen (24x80).

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

RSpec.describe 'An inactive text window' do
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

  # A drag held at main's top edge, then at its bottom row, as the input
  # loop's tick runs it (see MouseController#tick_drag_auto_scroll).
  def drag_up(window) = window.drag_auto_scroll(0)
  def drag_down(window) = window.drag_auto_scroll(window.maxy - 1)

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    # SCROLL_WINDOW is main, thoughts, then the tabbed window. 'small'
    # keeps the same windows (so .layout reuses them) with main's buffer
    # size lowered to 12 lines.
    File.write(settings_path, <<~XML)
      <settings>
        <layout id='default'>
          <window class='text' top='0' left='0' height='6' width='40' value='main'/>
          <window class='text' top='0' left='40' height='4' width='39' value='thoughts'/>
          <window class='tabbed' top='8' left='0' height='5' width='40' tabs='combat,logons'/>
          <window class='command' top='23' left='0' height='1' width='80'/>
        </layout>
        <layout id='small'>
          <window class='text' top='0' left='0' height='6' width='40' value='main' buffer-size='12'/>
          <window class='text' top='0' left='40' height='4' width='39' value='thoughts'/>
          <window class='tabbed' top='8' left='0' height='5' width='40' tabs='combat,logons'/>
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
    (1..20).each do |n|
      main.add_string("m#{n}")
      thoughts.add_string("t#{n}")
      tabbed.route_string("c#{n}", [], 'combat')
    end
  end

  context 'when another text window is the active one' do
    before { press('switch_current_window') } # thoughts

    it 'is main, and only thoughts shows a scrollbar' do
      expect(SCROLL_WINDOW).to eq [thoughts, tabbed, main]
      expect(scrollbar_cells(main)).to eq blank(6)
      expect(scrollbar_cells(thoughts)).to eq active(4)
    end

    # The only way to scroll an inactive window is a drag held at its
    # edge (the scroll keys and the wheel act on the active window).
    it 'shows no scrollbar while a drag scrolls it back, as lines arrive, or once back at the bottom' do
      expect(drag_up(main)).to be true
      expect(main.rows).to eq %w[m14 m15 m16 m17 m18 m19]
      expect(scrollbar_cells(main)).to eq blank(6)

      main.add_string('m21')
      expect(main.rows).to eq %w[m14 m15 m16 m17 m18 m19]
      expect(scrollbar_cells(main)).to eq blank(6)

      expect(drag_down(main)).to be true
      expect(drag_down(main)).to be true
      expect(main.buffer_pos).to eq 0
      expect(main.rows).to eq %w[m16 m17 m18 m19 m20 m21]
      expect(scrollbar_cells(main)).to eq blank(6)

      main.add_string('m22')
      expect(main.rows).to eq %w[m17 m18 m19 m20 m21 m22]
      expect(scrollbar_cells(main)).to eq blank(6)
      expect(scrollbar_cells(thoughts)).to eq active(4)
    end

    describe 'when its buffer size is lowered while it is scrolled back' do
      before do
        10.times { drag_up(main) }
        expect(main.rows).to eq %w[m5 m6 m7 m8 m9 m10]
      end

      it 'shows no scrollbar when the view keeps its place' do
        main.max_buffer_size = 16

        expect(main.rows).to eq %w[m5 m6 m7 m8 m9 m10]
        expect(scrollbar_cells(main)).to eq blank(6)
      end

      it 'shows no scrollbar when the view moves onto the oldest row left' do
        main.max_buffer_size = 12

        expect(main.rows).to eq %w[m9 m10 m11 m12 m13 m14]
        expect(scrollbar_cells(main)).to eq blank(6)
      end

      it 'shows no scrollbar when too few rows are left to scroll back over' do
        main.max_buffer_size = 4

        expect(main.buffer_pos).to eq 0
        expect(main.rows).to eq ['m17', 'm18', 'm19', 'm20', '', '']
        expect(scrollbar_cells(main)).to eq blank(6)
      end

      # .layout sets the buffer size, then resizes every window, which
      # leaves an inactive window's scrollbar blank. The screen update
      # between the two (LayoutLoader#load) must not show one either.
      it 'never shows a scrollbar while .layout lowers it' do
        shown = []
        allow(CursesRenderer).to receive(:doupdate).and_wrap_original do |original|
          shown << scrollbar_cells(main)
          original.call
        end

        app.execute_command('.layout small')

        expect(main.rows).to eq %w[m9 m10 m11 m12 m13 m14]
        expect(shown).not_to be_empty
        expect(shown.uniq).to eq [blank(6)]
        expect(scrollbar_cells(thoughts)).to eq active(4)
      end
    end
  end

  # Left behind: the window was the active one, scrolled back, when
  # another window became the active one.
  describe 'that was active and scrolled back when another window became active' do
    before do
      press('scroll_current_window_up_one')
      press('scroll_current_window_up_one')
      expect(scrollbar_cells(main)).to eq active(6, thumb: 4)
      press('switch_current_window') # thoughts
    end

    it 'shows no scrollbar once it is inactive, as lines arrive, or once a drag brings it back to the bottom' do
      expect(scrollbar_cells(main)).to eq blank(6)

      main.add_string('m21')
      expect(main.rows).to eq %w[m13 m14 m15 m16 m17 m18]
      expect(scrollbar_cells(main)).to eq blank(6)

      3.times { drag_down(main) }
      expect(main.buffer_pos).to eq 0
      expect(scrollbar_cells(main)).to eq blank(6)
      expect(scrollbar_cells(thoughts)).to eq active(4)
    end

    it 'shows its scrollbar where its view is once it is active again' do
      main.add_string('m21')

      press('switch_current_window') # the tabbed window
      press('switch_current_window') # main

      expect(scrollbar_cells(main)).to eq active(6, thumb: 4)
      expect(scrollbar_cells(thoughts)).to eq blank(4)
    end
  end

  # Main keeps 12 lines here ('small'), so lines arriving while it is
  # scrolled back evict the rows its view reached, which moves it.
  describe 'whose view lines arriving move onto the oldest row left' do
    before do
      app.execute_command('.layout small')
      2.times { press('scroll_current_window_up_one') }
      press('switch_current_window') # thoughts
    end

    it 'shows no scrollbar' do
      expect(scrollbar_cells(main)).to eq blank(6)

      (21..30).each { |n| main.add_string("m#{n}") }

      expect(main.rows).to eq %w[m19 m20 m21 m22 m23 m24]
      expect(scrollbar_cells(main)).to eq blank(6)
      expect(scrollbar_cells(thoughts)).to eq active(4)
    end
  end

  # The active window's scrollbar is unchanged on the same paths.
  describe 'unlike the active window' do
    it 'the active window shows its scrollbar through a drag, lines arriving, a lowered buffer size' do
      drag_up(main)
      expect(scrollbar_cells(main)).to eq active(6, thumb: 5)

      main.add_string('m21')
      expect(scrollbar_cells(main)).to eq active(6, thumb: 5)

      10.times { drag_up(main) }
      main.max_buffer_size = 12
      expect(main.rows).to eq %w[m10 m11 m12 m13 m14 m15]
      expect(scrollbar_cells(main)).to eq active(6, thumb: 0)
    end
  end
end
