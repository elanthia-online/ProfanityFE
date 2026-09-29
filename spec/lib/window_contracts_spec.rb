# frozen_string_literal: true

# Tests what the user sees when every kind of window is driven the way the
# client drives it: windows are built from layout XML by
# WindowManager#load_layout, text arrives through the parser's events,
# and the user scrolls with the scroll keys and the mouse wheel and
# selects and clicks with the mouse. These pin the contracts the window
# classes share (scrolling, repainting after a selection, routing, and
# the indicator, progress bar and countdown updates), whatever the
# methods behind them are called.

require 'socket'
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
require_relative '../../lib/event_bus'

RSpec.describe 'Window contracts' do
  # Mouse wheel buttons as .scrollcfg saves them.
  let(:wheel_up) { 0x10000 }
  let(:wheel_down) { 0x200000 }

  let(:cli_options) do
    {
      port: 8000, char: nil, config: nil, template: nil,
      default_color_id: 7, default_background_color_id: 0,
      use_default_colors: false, custom_colors: nil,
      settings_file: nil, no_status: true, links: true,
      speech_ts: false, room_window_only: false,
      remote_url: false, log_file: nil, log_dir: nil,
    }
  end

  let(:server) { StringIO.new }
  let(:copied) { [] }
  let(:logged) { [] }

  let(:app) do
    Application.new(cli_options, settings_file: File.join(SPEC_HOME, 'settings.xml'), host: '127.0.0.1', port: 8000)
  end
  let(:wm) { app.window_mgr }
  let(:event_bus) { EventBus.new.tap { |bus| wm.subscribe_to_events(bus) } }

  # One window of every class. Text wraps at 40 columns in the text
  # window and at 20 in the tabbed one (the builders keep the last column
  # for the scrollbar).
  let(:layout) do
    <<~XML
      <layout>
        <window class='text' top='0' left='0' height='4' width='42' value='main'/>
        <window class='tabbed' top='4' left='0' height='4' width='22' tabs='chat,lnet'/>
        <window class='indicator' top='8' left='0' height='1' width='6' value='kneeling' label='kneel'/>
        <window class='indicator' top='8' left='10' height='1' width='1' value='compass:n' label='n'/>
        <window class='progress' top='9' left='0' height='1' width='20' value='health' label='hp'/>
        <window class='countdown' top='10' left='0' height='1' width='20' value='roundtime' label='RT'/>
        <window class='exp' top='11' left='0' height='3' width='61'/>
        <window class='percWindow' top='14' left='0' height='3' width='31'/>
        <window class='room' top='17' left='0' height='4' width='40' value='room'/>
        <window class='sink' value='atmospherics'/>
        <window class='command' top='23' left='0' height='1' width='80'/>
      </layout>
    XML
  end

  let(:main) { wm.stream['main'] }
  let(:tabbed) { wm.stream['chat'] }
  let(:indicator) { wm.indicator['kneeling'] }
  let(:compass) { wm.indicator['compass:n'] }
  let(:progress) { wm.progress['health'] }
  let(:countdown) { wm.countdown['roundtime'] }
  let(:exp) { wm.stream['exp'] }
  let(:perc) { wm.stream['percWindow'] }
  let(:room) { wm.room['room'] }
  let(:windows) { [main, tabbed, indicator, compass, progress, countdown, exp, perc, room] }

  # A distinct color pair number for every fg/bg combination drawn, so the
  # virtual screen's attributes show which colors each cell got.
  let(:pairs) { Hash.new { |hash, key| hash[key] = hash.size + 1 } }

  # A frozen clock for the countdown.
  let(:now) { [1_000_000.0] }

  before do
    allow(ProfanitySettings).to receive(:load_mouse_settings)
      .and_return('BUTTON4_PRESSED_MASK' => wheel_up, 'BUTTON5_PRESSED_MASK' => wheel_down)
    allow(SelectionManager).to receive(:copy_to_clipboard) { |text| copied << text }
    allow(ProfanityLog).to receive(:write) { |*args, **| logged << args }
    allow(Time).to receive(:now) { Time.at(now[0]) }
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, bg| pairs[[fg, bg]] }
    allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, bg| pairs[[fg, bg]] }
    SelectionManager.clear_selection
    LAYOUT['contracts'] = REXML::Document.new(layout).root
    app.connection.attach(server)
    wm.load_layout('contracts')
    app.cmd_buffer.window = wm.command_window
    event_bus
  end

  after { SelectionManager.clear_selection }

  # Every cell of +window+ as the user sees it: its character and
  # attributes, row by row.
  def cells(window)
    (0...window.maxy).map do |y|
      (0...window.maxx).map { |x| [window.row(y)[x] || ' ', window.attrs_at(y, x)] }
    end
  end

  # Everything every window shows: characters and attributes of each cell,
  # and the scrollbars.
  def screens
    windows.to_h do |window|
      bar = window.respond_to?(:scrollbar) && window.scrollbar ? cells(window.scrollbar) : nil
      [window.class.name + window.begy.to_s, [cells(window), bar]]
    end
  end

  def press_key_action(name)
    app.key_action[name].call
  end

  def mouse(bstate, y, x)
    allow(Curses).to receive(:getmouse).and_return(Struct.new(:bstate, :y, :x).new(bstate, y, x))
    app.send(:handle_key, Curses::KEY_MOUSE, nil)
  end

  def click(y, x)
    mouse(Curses::BUTTON1_PRESSED, y, x)
    mouse(Curses::BUTTON1_RELEASED, y, x)
  end

  def drag(from, to)
    mouse(Curses::BUTTON1_PRESSED, *from)
    mouse(Curses::BUTTON1_RELEASED, *to)
  end

  def reversed_columns(window, y)
    (0...window.maxx).select { |x| window.attrs_at(y, x).anybits?(Curses::A_REVERSE) }
  end

  # The scrollbar row drawn in reverse video: the thumb.
  def thumb(window)
    bar = window.scrollbar
    (0...bar.maxy).find { |y| bar.attrs_at(y, 0).anybits?(Curses::A_REVERSE) }
  end

  def color_at(window, y, x)
    pairs.key((window.attrs_at(y, x) & Curses::A_COLOR) >> 8)
  end

  def stream_text(stream, text, colors = [])
    event_bus.emit(:stream_text, stream: stream, text: text, colors: colors)
  end

  describe 'scrolling a text window' do
    before { (1..10).each { |n| stream_text('main', "line #{n}") } }

    it 'moves by a line and by a page with the scroll keys, and back to the newest lines' do
      expect(main.rows).to eq ['line 7', 'line 8', 'line 9', 'line 10']
      expect(thumb(main)).to eq 3

      press_key_action('scroll_current_window_up_one')
      expect(main.rows).to eq ['line 6', 'line 7', 'line 8', 'line 9']

      press_key_action('scroll_current_window_up_page')
      expect(main.rows).to eq ['line 3', 'line 4', 'line 5', 'line 6']
      expect(thumb(main)).to eq 1

      press_key_action('scroll_current_window_down_one')
      expect(main.rows).to eq ['line 4', 'line 5', 'line 6', 'line 7']

      press_key_action('scroll_current_window_down_page')
      expect(main.rows).to eq ['line 7', 'line 8', 'line 9', 'line 10']

      press_key_action('scroll_current_window_up_page')
      press_key_action('scroll_current_window_up_page')
      expect(main.rows).to eq ['line 1', 'line 2', 'line 3', 'line 4']
      expect(thumb(main)).to eq 0

      press_key_action('scroll_current_window_bottom')
      expect(main.rows).to eq ['line 7', 'line 8', 'line 9', 'line 10']
      expect(thumb(main)).to eq 3
    end

    it 'moves a line per mouse wheel step, wherever the pointer is' do
      mouse(wheel_up, 20, 5)
      mouse(wheel_up, 0, 0)
      expect(main.rows).to eq ['line 5', 'line 6', 'line 7', 'line 8']

      mouse(wheel_down, 9, 3)
      expect(main.rows).to eq ['line 6', 'line 7', 'line 8', 'line 9']
      expect(logged).to be_empty
    end

    it 'keeps a scrolled-back view in place while new lines arrive, then shows them at the bottom' do
      press_key_action('scroll_current_window_up_page')
      stream_text('main', 'line 11')
      expect(main.rows).to eq ['line 4', 'line 5', 'line 6', 'line 7']

      press_key_action('scroll_current_window_bottom')
      expect(main.rows).to eq ['line 8', 'line 9', 'line 10', 'line 11']
    end
  end

  describe 'scrolling a tabbed window' do
    before do
      (1..8).each { |n| stream_text('chat', "chat #{n}") }
      stream_text('lnet', 'lnet 1')
      press_key_action('switch_current_window')
    end

    it 'scrolls the shown tab below the tab bar with the keys and the wheel' do
      expect(tabbed.rows).to eq [' 1:chat | 2:lnet*', 'chat 6', 'chat 7', 'chat 8']

      press_key_action('scroll_current_window_up_one')
      expect(tabbed.rows).to eq [' 1:chat | 2:lnet*', 'chat 5', 'chat 6', 'chat 7']

      mouse(wheel_up, 0, 0)
      press_key_action('scroll_current_window_up_page')
      expect(tabbed.rows).to eq [' 1:chat | 2:lnet*', 'chat 1', 'chat 2', 'chat 3']
      expect(thumb(tabbed)).to eq 1

      mouse(wheel_down, 5, 5)
      press_key_action('scroll_current_window_down_page')
      expect(tabbed.rows).to eq [' 1:chat | 2:lnet*', 'chat 5', 'chat 6', 'chat 7']

      press_key_action('scroll_current_window_bottom')
      expect(tabbed.rows).to eq [' 1:chat | 2:lnet*', 'chat 6', 'chat 7', 'chat 8']
      expect(thumb(tabbed)).to eq 3
    end

    it 'leaves the text window alone' do
      text_rows = main.rows
      press_key_action('scroll_current_window_up_page')

      expect(main.rows).to eq text_rows
    end

    it 'keeps each tab at its own place when switching tabs' do
      press_key_action('scroll_current_window_up_one')
      press_key_action('switch_tab_2')
      expect(tabbed.rows).to eq [' 1:chat | 2:lnet', 'lnet 1', '', '']

      press_key_action('switch_tab_1')
      expect(tabbed.rows).to eq [' 1:chat | 2:lnet', 'chat 5', 'chat 6', 'chat 7']
    end
  end

  describe 'selecting with the mouse' do
    before do
      %w[alpha bravo charlie delta].each { |word| stream_text('main', word) }
      %w[one two three].each { |word| stream_text('chat', word) }
    end

    it 'highlights a drag in a text window, copies it, and clears the highlight at the next press' do
      drag([1, 0], [2, 3])

      expect(copied).to eq ["bravo\ncha"]
      # The copy notice scrolls the text up a row, the highlight with it
      expect(main.rows).to eq ['bravo', 'charlie', 'delta', '* [copied 9 chars]']
      expect([reversed_columns(main, 0), reversed_columns(main, 1)]).to eq [[0, 1, 2, 3, 4], [0, 1, 2]]

      mouse(Curses::BUTTON1_PRESSED, 8, 2)

      expect((0...4).map { |y| reversed_columns(main, y) }).to all(be_empty)
      expect(main.rows).to eq ['bravo', 'charlie', 'delta', '* [copied 9 chars]']
    end

    it 'highlights a drag in a tabbed window and clears it when the selection is cleared' do
      drag([5, 0], [6, 3])

      expect(copied).to eq ["one\ntwo"]
      expect(reversed_columns(tabbed, 1)).to eq [0, 1, 2]
      expect(reversed_columns(tabbed, 2)).to eq [0, 1, 2]

      click(9, 2)

      expect((1...4).map { |y| reversed_columns(tabbed, y) }).to all(be_empty)
      expect(tabbed.rows).to eq [' 1:chat | 2:lnet', 'one', 'two', 'three']
    end

    it 'selects a word with a double click' do
      2.times { click(2, 1) }

      expect(copied).to eq ['charlie']
      # The copy notice scrolls the text up a row, the highlight with it
      expect(main.rows).to eq ['bravo', 'charlie', 'delta', '* [copied 7 chars]']
      expect(reversed_columns(main, 1)).to eq [0, 1, 2, 3, 4, 5, 6]
    end

    it 'keeps the highlight on its text while scrolling' do
      drag([2, 0], [2, 4])
      press_key_action('scroll_current_window_up_one')

      expect(main.rows).to eq ['alpha', 'bravo', 'charlie', 'delta']
      expect(reversed_columns(main, 2)).to eq [0, 1, 2, 3]
    end

    context 'on a window that has nothing to select' do
      before do
        event_bus.emit(:indicator_update, id: 'kneeling', value: true)
        event_bus.emit(:progress_update, id: 'health', value: 40, max: 100)
        event_bus.emit(:countdown_update, id: 'roundtime', end_time: now[0] + 5)
        event_bus.emit(:exp_set_current, skill: 'Parry Ability')
        stream_text('exp', '   Parry Ability: 1709 59% mind lock     0.37')
        stream_text('percWindow', 'Shadows (2 roisaen)')
        event_bus.emit(:room_title, text: '[Town Square]')
        event_bus.emit(:room_exits, text: 'Obvious paths: north.')
      end

      {
        'indicator' => [8, 1], 'compass' => [8, 10], 'progress bar' => [9, 3], 'countdown' => [10, 3],
        'exp window' => [11, 2], 'spell window' => [14, 2], 'room window' => [17, 2]
      }.each do |name, (y, x)|
        it "changes nothing on screen for a click, a drag or a double click on the #{name}" do
          before = screens

          click(y, x)
          drag([y, x], [y, x + 5])
          2.times { click(y, x) }
          mouse(Curses::BUTTON1_PRESSED, 1, 1)
          mouse(Curses::BUTTON1_RELEASED, 1, 1)

          expect(screens).to eq before
          expect(copied).to be_empty
          expect(server.string).to eq ''
          expect(logged).to be_empty
        end

        it "clears a text window's highlight when the #{name} is pressed" do
          drag([1, 0], [1, 4])
          highlighted = (0...4).flat_map { |row| reversed_columns(main, row) }

          mouse(Curses::BUTTON1_PRESSED, y, x)
          mouse(Curses::BUTTON1_RELEASED, y, x)

          expect(highlighted).not_to be_empty
          expect((0...4).map { |row| reversed_columns(main, row) }).to all(be_empty)
          expect(logged).to be_empty
        end
      end
    end
  end

  describe 'clicking a link' do
    it 'sends the command of a link in a text window' do
      stream_text('main', 'go north', [{ start: 3, end: 8, cmd: 'north' }])
      click(0, 4)

      expect(server.string).to eq "north\n"
    end

    it 'sends the command of a link in the room window' do
      app.shared_state.blue_links = true
      event_bus.emit(:room_title, text: '[Town Square]')
      event_bus.emit(:room_exits, text: 'Obvious paths: north.', links: [{ start: 15, end: 20, cmd: 'north' }])
      row = room.rows.index('Obvious paths: north.')
      click(17 + row, 16)

      expect(server.string).to eq "north\n"
    end
  end

  describe 'indicator updates' do
    it 'draws the label in the off color, then in the on color' do
      expect(indicator.rows).to eq ['kneel']
      expect(color_at(indicator, 0, 0)).to eq ['444444', nil]

      event_bus.emit(:indicator_update, id: 'kneeling', value: true)
      expect(color_at(indicator, 0, 0)).to eq ['ffff00', nil]

      event_bus.emit(:indicator_update, id: 'kneeling', label: 'KNEEL', value: false)
      expect(indicator.rows).to eq ['KNEEL']
      expect(color_at(indicator, 0, 4)).to eq ['444444', nil]
    end

    it 'lights the compass direction the room has' do
      event_bus.emit(:compass_update, dirs: %w[n s])
      expect(color_at(compass, 0, 0)).to eq ['ffff00', nil]

      event_bus.emit(:compass_update, dirs: %w[s])
      expect(color_at(compass, 0, 0)).to eq ['444444', nil]
    end

    it 'overlays label colors on the value color' do
      event_bus.emit(:indicator_update, id: 'kneeling', value: true,
                                        label_colors: [{ start: 0, end: 2, fg: 'ff0000' }])

      expect([color_at(indicator, 0, 0), color_at(indicator, 0, 3)]).to eq [['ff0000', nil], ['ffff00', nil]]
    end
  end

  describe 'progress bar updates' do
    # The part past the fill takes the third colors, which this layout
    # leaves unset.
    it 'fills the bar in proportion to the value and shows the value' do
      expect(progress.rows).to eq ["hp#{'100'.rjust(18)}"]

      event_bus.emit(:progress_update, id: 'health', value: 40, max: 100)

      expect(progress.rows).to eq ["hp#{'40'.rjust(18)}"]
      expect((0...20).map { |x| color_at(progress, 0, x) }.chunk_while { |a, b| a == b }.map { |run| [run.first, run.size] })
        .to eq [[[nil, '0000aa'], 8], [[nil, nil], 12]]
    end

    it 'keeps the maximum when an update gives none' do
      event_bus.emit(:progress_update, id: 'health', value: 10, max: 20)
      event_bus.emit(:progress_update, id: 'health', value: 5)

      expect(progress.rows).to eq ["hp#{'5'.rjust(18)}"]
      expect((0...20).count { |x| color_at(progress, 0, x) == [nil, '0000aa'] }).to eq 5
    end

    it 'takes a new label and colors with the value' do
      event_bus.emit(:progress_update, id: 'health', label: 'HP', fg: %w[ffffff], bg: ['00ff00', nil, '330000'],
                                       value: 50, max: 100)

      expect(progress.rows).to eq ["HP#{'50'.rjust(18)}"]
      expect([color_at(progress, 0, 0), color_at(progress, 0, 19)]).to eq [%w[ffffff 00ff00], [nil, '330000']]
    end
  end

  describe 'countdown updates' do
    it 'shows the label and 0 as soon as the layout is loaded' do
      expect(countdown.rows).to eq ["RT#{'0'.rjust(18)}"]
    end

    it 'counts down the seconds left as time passes, a cell per second' do
      event_bus.emit(:countdown_update, id: 'roundtime', end_time: now[0] + 5)
      expect(countdown.rows).to eq ["RT#{'5'.rjust(18)}"]
      expect((0...20).count { |x| color_at(countdown, 0, x) == [nil, 'ff0000'] }).to eq 5

      now[0] += 2
      expect(countdown.tick).to be true
      expect(countdown.rows).to eq ["RT#{'3'.rjust(18)}"]
      expect((0...20).count { |x| color_at(countdown, 0, x) == [nil, 'ff0000'] }).to eq 3

      expect(countdown.tick).to be false
    end

    it 'shows a question mark while active with no time left, and draws the secondary time' do
      event_bus.emit(:countdown_active, id: 'roundtime', active: true)
      expect(countdown.rows).to eq ["RT#{'?'.rjust(18)}"]

      event_bus.emit(:countdown_update, id: 'roundtime', end_time: now[0] + 2, secondary_end_time: now[0] + 4)
      expect(countdown.rows).to eq ["RT#{'4'.rjust(18)}"]
      expect((0...5).map { |x| color_at(countdown, 0, x) })
        .to eq [[nil, 'ff0000'], [nil, 'ff0000'], [nil, '0000ff'], [nil, '0000ff'], [nil, nil]]
    end

    # Both values come from one reading of the clock, so a tick that
    # straddles a second boundary can't show them a second apart.
    it 'takes the primary and secondary time left from the same moment' do
      event_bus.emit(:countdown_update, id: 'roundtime', end_time: now[0] + 5.2, secondary_end_time: now[0] + 5.2)
      readings = [now[0] + 0.95, now[0] + 1.05]
      allow(Time).to receive(:now) { Time.at(readings.shift || readings.last) }

      countdown.tick

      expect(countdown.secondary_value).to eq countdown.value
    end

    it 'counts a stun into the stunned countdown' do
      LAYOUT['stun'] = REXML::Document.new(<<~XML).root
        <layout><window class='countdown' top='0' left='0' height='1' width='12' value='stunned' label='S'/></layout>
      XML
      wm.load_layout('stun')
      stunned = wm.countdown['stunned']

      event_bus.emit(:stun, seconds: 3)

      expect(stunned.rows).to eq ['S          3']
    end
  end

  describe 'exp window updates' do
    it 'shows each skill once, sorted, and drops a deleted skill' do
      event_bus.emit(:exp_set_current, skill: 'Parry Ability')
      stream_text('exp', '   Parry Ability: 1709 59% mind lock     0.37')
      event_bus.emit(:exp_set_current, skill: 'Evasion')
      stream_text('exp', '         Evasion:  800 12%  [ 5/34]')
      event_bus.emit(:exp_set_current, skill: 'Parry Ability')
      stream_text('exp', '   Parry Ability: 1710 01% clear         0.00')

      expect(exp.rows).to eq [' Evasion:  800 12% [ 5/34]', 'Parry Ability: 1710 01% clear         0.00', '']

      event_bus.emit(:exp_set_current, skill: 'Evasion')
      event_bus.emit(:exp_delete_skill)

      expect(exp.rows).to eq ['Parry Ability: 1710 01% clear         0.00', '', '']
    end

    it 'ignores text that is not a skill line' do
      event_bus.emit(:exp_set_current, skill: 'Favors')
      stream_text('exp', 'Favors: 12')

      expect(exp.rows).to eq ['', '', '']
    end
  end

  describe 'spell window updates' do
    it 'shows the batch sorted by time left, and starts again at the next batch' do
      event_bus.emit(:clear_spells)
      stream_text('percWindow', 'Shadows (2 roisaen)')
      stream_text('percWindow', 'Ease Burden (12 roisaen)')
      stream_text('percWindow', 'Manifest Force (Fading)')

      expect(perc.rows).to eq ['Ease Burden (12 roisaen)', 'Shadows (2 roisaen)', 'Manifest Force (Fading)']

      event_bus.emit(:clear_spells)
      stream_text('percWindow', 'Shadows (1 roisaen)')

      expect(perc.rows).to eq ['Shadows (1 roisaen)', '', '']
    end

    it 'wraps a long spell line under itself' do
      stream_text('percWindow', 'A very long spell name that wraps (5 roisaen)')

      expect(perc.rows).to eq ['A very long spell name that', '  wraps (5 roisaen)', '']
    end
  end

  # Not a characterization: before BaseWindow#repaint became the repaint
  # every class answers, it did nothing on indicator, progress, exp, spell
  # and room windows, and it did nothing on a countdown until it drew
  # from its stored values.
  describe 'repaint' do
    before do
      (1..6).each { |n| stream_text('main', "line #{n}") }
      stream_text('chat', 'chat 1')
      event_bus.emit(:indicator_update, id: 'kneeling', value: true)
      event_bus.emit(:progress_update, id: 'health', value: 40, max: 100)
      event_bus.emit(:exp_set_current, skill: 'Evasion')
      stream_text('exp', '         Evasion:  800 12%  [ 5/34]')
      stream_text('percWindow', 'Shadows (2 roisaen)')
      event_bus.emit(:room_title, text: '[Town Square]')
      event_bus.emit(:room_exits, text: 'Obvious paths: north.')
      event_bus.emit(:countdown_update, id: 'roundtime', end_time: now[0] + 2, secondary_end_time: now[0] + 4)
    end

    it 'draws every window with contents again from what it holds' do
      [main, tabbed, indicator, compass, progress, countdown, exp, perc, room].each do |window|
        shown = cells(window)
        window.erase

        window.repaint

        expect(cells(window)).to eq(shown), "#{window.class} was not repainted"
      end
    end
  end

  describe 'routing' do
    it 'sends stream text to the window of its stream' do
      stream_text('main', 'to main')
      stream_text('chat', 'to chat')
      stream_text('lnet', 'to lnet')

      expect(main.rows.first).to eq 'to main'
      expect(tabbed.rows).to eq [' 1:chat | 2:lnet*', 'to chat', '', '']

      press_key_action('switch_tab_2')
      expect(tabbed.rows).to eq [' 1:chat | 2:lnet', 'to lnet', '', '']
    end

    it 'drops stream text for a sink, and for a stream with no window' do
      before = screens

      stream_text('atmospherics', 'a breeze')
      stream_text('nowhere', 'lost')

      expect(screens).to eq before
    end

    it 'shows prompts in each stream window, once per repeat for a bare prompt' do
      event_bus.emit(:add_prompt, text: 'H>')
      event_bus.emit(:add_prompt, text: 'H>')
      event_bus.emit(:add_prompt, text: 'H>', command: 'look')
      event_bus.emit(:add_prompt, stream: 'chat', text: 'R>')
      event_bus.emit(:add_prompt, stream: 'exp', text: 'H>')
      event_bus.emit(:add_prompt, stream: 'percWindow', text: 'H>')
      event_bus.emit(:add_prompt, stream: 'atmospherics', text: 'H>')

      expect(main.rows).to eq ['H>', 'H>look', '', '']
      expect(main.attrs_at(0, 0)).to eq(main.attrs_at(1, 4))
      expect(tabbed.rows).to eq [' 1:chat | 2:lnet', 'R>', '', '']
      expect(exp.rows).to eq ['', '', '']
      expect(perc.rows).to eq ['H>', '', '']
    end

    it 'shows a remote URL in the main window' do
      event_bus.emit(:launch_url, url: 'https://example.com', remote: true)

      expect(main.rows).to eq [' *', ' * LaunchURL: https://example.com', ' *', '']
    end

    it 'shows the room in the room window' do
      event_bus.emit(:room_title, text: '[Town Square]')
      event_bus.emit(:room_desc, text: 'Old stones.')
      event_bus.emit(:room_exits, text: 'Obvious paths: north.')

      expect(room.rows).to eq ['[[Town Square]]', 'Old stones.', 'Obvious paths: north.', '']
    end

    it 'shows the disconnect notice in the main window' do
      event_bus.emit(:disconnect)

      expect(main.rows).to eq ['*', '* Connection closed', '* Press any key to exit...', '*']
    end
  end
end
