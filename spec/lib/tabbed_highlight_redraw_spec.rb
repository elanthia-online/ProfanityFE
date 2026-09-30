# frozen_string_literal: true

# A selection highlight stays on screen when a window is redrawn without
# re-wrapping its lines: a terminal resize that keeps the window's width
# (to the same size or to another height), .resize, and .layout reusing
# the window. A text window always kept it; a tabbed window drew its text
# without it, and the highlight came back only with the next line to
# arrive in the shown tab. A tabbed window now shows it on the cells a
# text window with the same lines and selection shows it on. A re-wrap
# (a new width) still drops the selection (#118), and so does a tab
# switch (#177).
#
# Driven through the real client (Application#run) on the virtual screen:
# the game server sends the lines, the user drags over them with the
# mouse, and the terminal resizes and dot commands come from the keyboard.
# Each example drags over the text window first and runs the redraw, then
# does the same over the tabbed window, and compares what each showed.

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

RSpec.describe 'A selection highlight through a redraw' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:terminal) { { lines: 24, cols: 80 } }
  let(:mouse_events) { [] }
  let(:copied) { [] }
  # Times the layout was fitted to the terminal (WindowManager#resize)
  let(:fits) { [0] }
  # What the window dragged over showed at each note: { [window, step] => view }
  let(:seen) { {} }

  # The lines the game sends to each window: 4 text rows show l3..l6.
  let(:lines) { %w[l1-one l2-two l3-three l4-four l5-five l6-six] }

  # The two windows the user drags over, each with its stream: a text
  # window (ooc) and a tabbed window (assess and voln tabs, assess shown).
  # Both are 40 columns wide (39 of text), with 4 text rows at 24 lines
  # and 6 at 26.
  let(:windows) { { text: 'ooc', tabbed: 'assess' } }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    allow(Curses).to receive(:lines) { terminal[:lines] }
    allow(Curses).to receive(:cols) { terminal[:cols] }
    allow(ProfanityLog).to receive(:write)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    allow(SelectionManager).to receive(:copy_to_clipboard) { |text| copied << text }
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    allow(Curses).to receive(:getmouse) { mouse_events.shift }
    allow(app.window_mgr).to receive(:resize).and_wrap_original do |resize, *args|
      resize.call(*args)
      fits[0] += 1
    end
    SelectionManager.clear_selection
    File.write(settings_path, <<~XML)
      <settings>
        <key id='enter' action='send_command'/>
        <layout id='default'>
          <window class='text' top='0' left='0' height='4' width='41' value='main'/>
          <window class='text' top='5' left='0' height='lines-20' width='41' value='ooc'/>
          <window class='tabbed' top='lines-14' left='0' height='lines-19' width='41' tabs='assess,voln'/>
          <window class='command' top='lines-1' left='0' height='1' width='80'/>
        </layout>
        <layout id='wide'>
          <window class='text' top='0' left='0' height='4' width='41' value='main'/>
          <window class='text' top='5' left='0' height='lines-20' width='51' value='ooc'/>
          <window class='tabbed' top='lines-14' left='0' height='lines-19' width='51' tabs='assess,voln'/>
          <window class='command' top='lines-1' left='0' height='1' width='80'/>
        </layout>
      </settings>
    XML
  end

  after { SelectionManager.clear_selection }

  # @return [BaseWindow, nil] the window showing +stream+ (the layout is
  #   built when the client starts: keyboard steps look windows up when
  #   they come)
  def window_for(stream) = app.window_mgr.stream[stream]

  # Keyboard steps: the game sends +lines+ on +stream+; no key until the
  # last one is shown.
  def game_sends(stream, *lines)
    [-> { game_server.say(*lines.map { |line| %(<pushStream id="#{stream}"/>#{line}\r\n<popStream/>) }) },
     wait_until { window_for(stream).rows.include?(lines.last) }]
  end

  # Keyboard step: a mouse event at text row +row+, column +x+ of the
  # window showing +stream+.
  def mouse(bstate, stream, row, x)
    press_after(Curses::KEY_MOUSE) do
      window = window_for(stream)
      mouse_events << Struct.new(:bstate, :y, :x).new(bstate, window.begy + window.content_top + row, x)
    end
  end

  # Keyboard steps: drag over the window showing +stream+ from text row
  # 1, column 2 to text row 2, column 5 (the release copies the selection).
  def drag(stream)
    [mouse(Curses::BUTTON1_PRESSED, stream, 1, 2), mouse(Curses::REPORT_MOUSE_POSITION, stream, 2, 4),
     mouse(Curses::BUTTON1_RELEASED, stream, 2, 5)]
  end

  # Keyboard steps: the terminal resizes to +lines+ (or stays the same
  # size) and sends KEY_RESIZE; no key until the layout was fitted.
  def terminal_resize(lines: nil)
    fitted = nil
    [press_after(Curses::KEY_RESIZE) do
      fitted = fits[0] + 1
      terminal[:lines] = lines if lines
    end, wait_until { fits[0] == fitted }]
  end

  # Keyboard step: note what the +kind+ window shows (its text rows, the
  # cells of them in reverse video, and whether it has a selection) as
  # step +step+.
  def note(kind, step)
    lambda do
      window = window_for(windows[kind])
      text_rows = (window.content_top...window.maxy).to_a
      reverse = text_rows.flat_map do |y|
        (0...window.maxx).select { |x| window.attrs_at(y, x).anybits?(Curses::A_REVERSE) }
                         .map { |x| [y - window.content_top, x] }
      end
      seen[[kind, step]] = { rows: text_rows.map { |y| window.row(y) }, reverse: reverse,
                             highlight: window.has_highlight? }
      nil
    end
  end

  # Run the client: the game fills both windows; then, for the text
  # window and then the tabbed window, the user drags over it, and the
  # steps the block returns for that window come (+before_drag+ first).
  #
  # @param before_drag [Array] keyboard steps before each drag
  # @yieldparam kind [Symbol] :text or :tabbed
  # @yieldparam stream [String] the window's stream
  # @yieldreturn [Array] keyboard steps
  def run_on_each_window(before_drag: [])
    steps = windows.flat_map do |kind, stream|
      [*before_drag, *drag(stream), note(kind, :dragged), *yield(kind, stream)]
    end
    run_client(keyboard(*game_sends('ooc', *lines), *game_sends('assess', *lines), *steps))
  end

  # The dragged cells of text row +row+ (l4-four from column 2 to its
  # end) and the next one (columns 0-4), as [text row, column].
  def dragged_cells(row = 1)
    (2...7).map { |x| [row, x] } + (0...5).map { |x| [row + 1, x] }
  end

  # The view of a window with 4 text rows showing l3..l6 after the drag.
  let(:highlighted) { { rows: %w[l3-three l4-four l5-five l6-six], reverse: dragged_cells, highlight: true } }

  # @return [Array] what the text window and the tabbed window showed at +step+
  def both(step) = [seen[[:text, step]], seen[[:tabbed, step]]]

  it 'keeps it through a terminal resize to the same size' do
    run_on_each_window { |kind| [*terminal_resize, note(kind, :resized)] }

    expect(copied).to eq ["-four\nl5-fi"] * 2
    expect(both(:dragged)).to eq [highlighted] * 2
    expect(both(:resized)).to eq [highlighted] * 2
  end

  it 'keeps it through .resize' do
    run_on_each_window { |kind| [".resize\n", note(kind, :resized)] }

    expect(both(:resized)).to eq [highlighted] * 2
  end

  it 'keeps it through .layout reusing the window' do
    run_on_each_window { |kind| [".layout default\n", note(kind, :relaid)] }

    expect(both(:relaid)).to eq [highlighted] * 2
  end

  it 'keeps it on its text through a terminal resize to another height that keeps the width' do
    run_on_each_window(before_drag: terminal_resize(lines: 24)) do |kind|
      [*terminal_resize(lines: 26), note(kind, :taller)]
    end

    # 6 text rows show l1..l6: l4 and l5 are on rows 3 and 4
    expect(both(:dragged)).to eq [highlighted] * 2
    expect(both(:taller)).to eq [{ rows: lines, reverse: dragged_cells(3), highlight: true }] * 2
  end

  it 'keeps it on its text after a redraw as the next line arrives' do
    run_on_each_window do |kind, stream|
      [*terminal_resize, note(kind, :resized), *game_sends(stream, 'l7-seven'), note(kind, :next_line)]
    end

    expect(both(:resized)).to eq [highlighted] * 2
    expect(both(:next_line)).to eq [{ rows: %w[l4-four l5-five l6-six l7-seven], reverse: dragged_cells(0),
                                      highlight: true }] * 2
  end

  it 'keeps it through a redraw, then drops it when a new width re-wraps the lines' do
    run_on_each_window(before_drag: [".layout default\n"]) do |kind|
      [*terminal_resize, note(kind, :resized), ".layout wide\n", note(kind, :rewrapped)]
    end

    expect(both(:resized)).to eq [highlighted] * 2
    expect(both(:rewrapped)).to eq [{ rows: highlighted[:rows], reverse: [], highlight: false }] * 2
  end

  describe 'in a tabbed window' do
    let(:windows) { { tabbed: 'assess' } }

    it 'keeps it through a redraw, then drops it on a tab switch, and it stays gone on switching back' do
      run_on_each_window do
        [*terminal_resize, note(:tabbed, :resized), ".tab voln\n", note(:tabbed, :other_tab), ".tab assess\n",
         *terminal_resize, note(:tabbed, :back)]
      end

      expect(seen[[:tabbed, :resized]]).to eq highlighted
      expect(seen[[:tabbed, :other_tab]]).to eq(rows: ['', '', '', ''], reverse: [], highlight: false)
      expect(seen[[:tabbed, :back]]).to eq(rows: highlighted[:rows], reverse: [], highlight: false)
    end
  end
end
