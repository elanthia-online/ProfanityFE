# frozen_string_literal: true

# The command line stays on top: no window covers the command window's
# cells on the screen, whatever the layout says.
#
# The real client (Application#run) runs on the virtual screen with a
# scripted game server and keyboard. The virtual screen copies cells to the
# terminal as ncurses does (only the part of each line a window changed
# since its last refresh, see Curses::TerminalScreen), and every screen
# update is recorded as a frame: the terminal's rows and cursor after each
# doupdate, whichever thread or path made it.
#
# The layouts are the overlapping windows of two bundled templates as of
# 2a1987b, before their geometry was made size-relative: at 80x24,
# tysong.xml's main window (top 14, height 37) runs over the command line
# on the bottom row, and mahtra.xml's room window (top 17, height 16,
# columns 53-78) over the command line on row 22. Before the fix, each new
# game line scrolled main over the command line and only a resize drew it
# again; the room window's render did the same to the columns it covers.
# The prompt indicator just left of the command window is the rest of the
# command line, and stays on top with it.

require 'rexml/document'
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

RSpec.describe 'The command line on top of overlapping windows' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:links) { false }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: links, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:main) { app.window_mgr.stream['main'] }
  let(:command) { app.window_mgr.command_window }
  # Each screen update: the terminal's rows and the cursor right after it,
  # and the newest line main held then.
  let(:frames) { [] }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    allow(ProfanityLog).to receive(:write)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    record = lambda do
      frames << { rows: Curses::TerminalScreen.rows, cursor: Curses::TerminalCursor.position,
                  newest: main&.rows&.reject(&:empty?)&.last }
    end
    allow(Curses).to receive(:doupdate).and_wrap_original do |original|
      original.call.tap { record.call }
    end
    allow(CursesRenderer).to receive(:doupdate).and_wrap_original do |original|
      original.call.tap { record.call }
    end
    allow(CursesRenderer).to receive(:render).and_wrap_original do |original, &block|
      original.call(&block).tap { record.call }
    end
  end

  def use_layout(windows)
    File.write(settings_path, "<settings>\n<layout id='default'>\n#{windows}</layout>\n</settings>\n")
  end

  # Enough lines to fill tysong's 37-row main window from its bottom row
  # (off the screen at 80x24) up past the command line, then two real
  # GemStone lines and their prompts (GSF-Tysong, 2026-09-30).
  let(:game_lines) do
    (1..40).map { |n| "Line #{n} of a long room description." } + [
      %(<preset id='speech'>Speaking to you, <a exist="-11165808" noun="Nexushealbot">Nexushealbot</a> exclaims</preset>, "You are healed!"),
      '<prompt time="1790826944">&gt;</prompt>',
      '<a exist="-11235806" noun="Boolean">Boolean</a> put a <a exist="533302832" noun="runestaff">silver-inlaid carmiln runestaff</a> in ' \
      '<a exist="-11235806" noun="Boolean">his</a> <a exist="388217517" noun="pack">black leather pack</a>.',
      '<prompt time="1790826944">&gt;</prompt>'
    ]
  end
  let(:last_line) { 'Boolean put a silver-inlaid carmiln runestaff in his black leather pack.' }

  def drawn?(line) = frames.any? { |frame| frame[:newest]&.end_with?(line) }

  # The frames from the first one that shows +text+ on the bottom row at
  # the command window's column.
  def frames_since_typed(text, row:, column:)
    first = frames.index { |frame| frame[:rows][row][column, text.length] == text }
    first ? frames[first..] : []
  end

  describe "tysong.xml's windows at 80x24 (main runs over the command line on the bottom row)" do
    before do
      use_layout(<<~XML)
        <window class='text' top='14' left='20'  height='37' width='140' value='main' buffer-size='4000'/>
        <window class='indicator' top='lines-1' left='20' height='1' width='1' label='&gt;' value='prompt' fg='f1f1f1,44444'/>
        <window class='command'   top='lines-1' left='21' width='cols-21' height='1' />
      XML
    end

    it 'lays the windows out as described above' do
      run_client(keyboard)

      expect([command.begy, command.begx, command.maxx]).to eq [23, 21, 59]
      expect([main.begy, main.begx, main.maxy, main.maxx]).to eq [14, 20, 37, 139]
    end

    it 'shows the typed text on the command line after new game lines, at every screen update' do
      run_client(keyboard('abc', -> { game_server.say(*game_lines) }, wait_until { drawn?(last_line) }))

      after_typing = frames_since_typed('abc', row: 23, column: 21)
      expect(after_typing.size).to be > game_lines.size / 2
      # the prompt indicator (column 20) and the command window (21 on)
      expect(after_typing.map { |frame| frame[:rows][23][20..] }).to all(eq('>abc'))
      expect(after_typing.map { |frame| frame[:cursor] }).to all(eq([23, 24]))
      # main's text did reach the row above the command line
      expect(frames.last[:rows][22]).to match(/ Line \d+ of a long room description\.\z/)
    end

    it 'keeps an empty command line blank over main, the cursor at its start' do
      run_client(keyboard(-> { game_server.say(*game_lines) }, wait_until { drawn?(last_line) }))

      expect(frames.last[:rows][22]).to match(/ Line \d+ of a long room description\.\z/)
      expect(frames.last[:rows][23][20..]).to eq '>'
      expect(frames.last[:cursor]).to eq [23, 21]
    end

    it 'shows the command line over the disconnect notice, which scrolls main under it' do
      shown_at_exit = []
      exit_key = lambda do
        shown_at_exit << frames.last
        'q'
      end
      typed = keyboard('look', -> { game_server.say(*game_lines) }, wait_until { drawn?(last_line) },
                       -> { game_server.hang_up }, idle: true, exit_keys: [exit_key])

      status, = run_client(typed)

      expect(status).to eq 0
      expect(shown_at_exit.size).to eq 1
      expect(shown_at_exit.first[:rows][23][20..]).to eq '>look'
      expect(shown_at_exit.first[:cursor]).to eq [23, 25]
      expect(main.rows.reject(&:empty?).last(3)).to eq ['* Connection closed', '* Press any key to exit...', '*']
    end

    it 'keeps the command line on top after a resize to the same size and more game lines' do
      more = (41..45).map { |n| "Line #{n} after the resize." }
      resizes = 0
      allow(app.window_mgr).to receive(:resize).and_wrap_original do |original, *args|
        original.call(*args).tap { resizes += 1 }
      end
      run_client(keyboard('abc', -> { game_server.say(*game_lines) }, wait_until { drawn?(last_line) },
                          Curses::KEY_RESIZE, wait_until { resizes == 2 },
                          -> { game_server.say(*more) }, wait_until { drawn?(more.last) }))

      expect(resizes).to eq 2

      expect(frames.last[:newest]).to eq more.last
      expect(frames.last[:rows][23][20..]).to eq '>abc'
      expect(frames.last[:cursor]).to eq [23, 24]
    end

    it 'keeps the prompt the game sent last on top, refitted to its length' do
      prompts = game_lines + ['<prompt time="1790826945">R&gt;</prompt>'] + (41..45).map { |n| "Line #{n} after the new prompt." }
      run_client(keyboard('abc', -> { game_server.say(*prompts) }, wait_until { drawn?('Line 45 after the new prompt.') }))

      expect(app.window_mgr.indicator['prompt'].maxx).to eq 2
      expect([command.begy, command.begx]).to eq [23, 22]
      expect(frames.last[:rows][23][20..]).to eq 'R>abc'
      expect(frames.last[:cursor]).to eq [23, 25]
    end

    # Main's rows 8 and 9 show on screen rows 22 and 23; row 23 is under
    # the command line. A click goes by what the screen shows.
    context 'with links on, a link in main under the command line' do
      let(:links) { true }
      let(:door_lines) do
        (1..8).map { |n| "Line #{n} of a long room description." } +
          ["Exit here: <d cmd='go visible door'>door</d> is on the row above the command line.",
           "Exit here: <d cmd='go hidden door'>door</d> is under the command line."] +
          (1..27).map { |n| "Tail #{n} of a long room description." }
      end

      def click_at(y, x)
        event = ->(bstate) { allow(Curses).to receive(:getmouse).and_return(Struct.new(:bstate, :y, :x).new(bstate, y, x)) }
        [press_after(Curses::KEY_MOUSE) { event.call(Curses::BUTTON1_PRESSED) },
         press_after(Curses::KEY_MOUSE) { event.call(Curses::BUTTON1_RELEASED) }]
      end

      it 'follows no link for a click on the command line, only the one the screen shows' do
        now = 100.0
        allow(SelectionManager).to receive(:monotonic_now) { now += 1 }
        shown = under = nil
        run_client(keyboard('abc', -> { game_server.say(*door_lines) }, wait_until { drawn?('Tail 27 of a long room description.') },
                            lambda {
                              shown = frames.last[:rows][22..23]
                              under = main.rows[8..9]
                            },
                            *click_at(23, 31), *click_at(23, 20), *click_at(22, 31),
                            wait_until { game_server.commands.any? }))

        expect(under).to eq ['Exit here: door is on the row above the command line.',
                             'Exit here: door is under the command line.']
        expect(shown).to eq [(' ' * 20) + 'Exit here: door is on the row above the command line.', (' ' * 20) + '>abc']
        expect(game_server.commands).to eq ['go visible door']
      end
    end
  end

  # Every screen update refreshes the command window with #noutrefresh
  # and one doupdate; nothing in the client calls its #refresh. A refresh
  # must still keep the command line on top, so a new path that uses it
  # can't bring the bug back.
  describe 'refreshing the command window with #refresh, outside the client' do
    let(:window_mgr) { WindowManager.new }
    let(:main) { window_mgr.stream['main'] }
    let(:command) { window_mgr.command_window }

    before do
      LAYOUT['on top refresh'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='14' left='20' height='37' width='140' value='main'/>
          <window class='indicator' top='lines-1' left='20' height='1' width='1' label='&gt;' value='prompt'/>
          <window class='command' top='lines-1' left='21' width='cols-21' height='1'/>
        </layout>
      XML
      window_mgr.load_layout('on top refresh')
    end

    after { LAYOUT.delete('on top refresh') }

    it 'copies the prompt and the command window whole, over main drawn after their last refresh' do
      command.addstr('abc')
      command.refresh
      (1..37).each { |n| main.add_string("Line #{n} of a long room description.") }
      main.noutrefresh
      expect(main.rows[9]).to eq 'Line 10 of a long room description.'

      command.refresh

      expect(Curses::TerminalScreen.row(22)).to eq "#{' ' * 20}Line 9 of a long room description."
      expect(Curses::TerminalScreen.row(23)).to eq "#{' ' * 20}>abc"
      expect(Curses::TerminalCursor.position).to eq [23, 24]
    end
  end

  describe "mahtra.xml's windows at 80x24 (the room window runs over columns 53-78 of the command line)" do
    # The template's command window is 104 columns wide, past the right
    # edge of an 80-column screen, where ncurses won't move it; cols-1
    # keeps it on the screen.
    before do
      use_layout(<<~XML)
        <window class='text' top='0' left='0' height='16' width='52' value='main'/>
        <window class='room' top='17' left='((cols/3)*2)+1' height='16' width='cols/3' title-preset='roomName' creatures-preset='monsterbold'/>
        <window class='command'   top='lines-2' left='1'   width='cols-1' height='1'/>
      XML
    end

    let(:room) { app.window_mgr.room['room'] }

    # A DragonRealms move as the game sends it (from a real session).
    let(:room_lines) do
      ["<nav rm='4217140'/>",
       %(<streamWindow id='room' title='Room' subtitle=" - [Seord Kerwaith, Mountainside] (4217140)" ) +
         %(location='center' target='drop' ifClosed='' resident='true'/>),
       "<component id='room desc'>Night covers the narrow gorge, and the wind finds every gap in the rocks " \
       'above the trail, whistling through them in long, low notes.</component>',
       "<component id='room objs'>You also see <pushBold/>a rat<popBold/> and a <d cmd='look rock'>rock</d>.</component>",
       "<component id='room players'>Also here: Bob.</component>",
       "<component id='room exits'>Obvious paths: <d>northeast</d>, <d>southwest</d>.<compass></compass></component>",
       "<component id='room extra'></component>",
       '<resource picture="0"/><style id="roomName" />[Seord Kerwaith, Mountainside] (4217140)',
       %(<style id=""/><preset id='roomDesc'>Night covers the narrow gorge.</preset>  You also see a rat and a rock.),
       'Also here: Bob.',
       'Obvious paths: <d>northeast</d>, <d>southwest</d>.',
       %(<compass><dir value="ne"/><dir value="sw"/></compass>),
       '<prompt time="1787793483">&gt;</prompt>']
    end

    it 'keeps the command line over the room window, in every column the room covers' do
      run_client(keyboard('abc', -> { game_server.say(*room_lines) },
                          wait_until { frames.any? { |frame| frame[:rows][17].include?('Seord Kerwaith') } }))

      expect([command.begy, command.begx]).to eq [22, 1]
      expect([room.begy, room.begx, room.maxy, room.maxx]).to eq [17, 53, 16, 26]
      # the room window has text in its row over the command line
      expect(room.row(22 - room.begy)).not_to be_empty
      expect(frames.last[:rows][17]).to include('Seord Kerwaith')
      expect(frames.last[:rows][22]).to eq ' abc'
      expect(frames.last[:cursor]).to eq [22, 4]
    end
  end
end
