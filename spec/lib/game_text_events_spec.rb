# frozen_string_literal: true

# What the game-text checks and the routing of GameTextProcessor show:
# the nerve damage (nsys) indicator, the stun countdown, the hand
# indicators, main and stream windows, highlights, and when the pending
# prompt shows (not after movement, not after a bracket prompt line).
#
# Lines are fed through the real server loop (GameTextProcessor#run) into
# real windows built from layout XML; the assertions are on what those
# windows show on the virtual screen (spec/support/virtual_screen.rb).
# Multi-line gags are in multiline_gags_spec.rb and room component lines
# in room_component_lines_spec.rb.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'GameTextProcessor game text on screen' do
  # The countdown windows count down from this fixed time.
  let(:clock) { Clock.new(now: -> { Time.at(1_800_000_000) }) }
  # Color pair number per foreground color, so a cell's color can be read
  # back from its attributes.
  let(:pairs) { { 'ff0000' => 1, '00ff00' => 2, 'ff9900' => 3, 'ffff00' => 4, '444444' => 5 } }
  # The game repeats an unchanged prompt; that marks a prompt as pending,
  # shown before the next line of main text.
  let(:same_prompt) { '<prompt time="1800000000">&gt;</prompt>' }

  before { allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) } }

  # Start a client: the windows of a layout, and a processor (with its own
  # event bus and shared state) that feeds them.
  #
  # @param windows_xml [String] the layout's <window> elements
  # @return [void]
  def load_layout(windows_xml)
    LAYOUT['events'] = REXML::Document.new("<layout>#{windows_xml}</layout>").root
    event_bus = EventBus.new
    @window_manager = WindowManager.new(clock: clock)
    @window_manager.load_layout('events')
    @window_manager.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @window_manager, shared_state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would (Lich ends every line with CRLF). The first prompt makes the
  # client send 'look', which this server accepts.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |*| nil }
    server.define_singleton_method(:flush) { nil }
    allow(IO).to receive(:select).and_return(nil)
    @processor.run(server)
  end

  # The lines a stream's text window shows, blank rows left out.
  def shown_in(stream)
    @window_manager.stream[stream].rows.reject(&:empty?)
  end

  # The color of each character of +text+ where main shows it: a
  # foreground color, nil when uncolored, or an Array when mixed.
  def color_in_main(text)
    window = @window_manager.stream['main']
    y = window.rows.index { |row| row.include?(text) }
    raise "#{text.inspect} not in main: #{shown_in('main').inspect}" unless y

    x = window.row(y).index(text)
    colors = (x...(x + text.length)).map { |col| pairs.key(window.attrs_at(y, col) >> 8) }.uniq
    colors.size == 1 ? colors.first : colors
  end

  describe 'the nerve damage indicator' do
    # Its colors by damage rank: none, slurred speech, muscle spasms,
    # trouble with muscle control.
    before do
      allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, _bg| pairs.fetch(fg, 0) }
      load_layout(<<~XML)
        <window class='text' top='0' left='0' height='8' width='80' value='main'/>
        <window class='indicator' top='20' left='0' height='1' width='4' label='nsys' value='nsys'
                fg='444444,ffff00,ff9900,ff0000'/>
      XML
    end

    # The foreground color the nsys indicator is drawn in.
    def nsys_color
      pairs.key(@window_manager.indicator['nsys'].attrs_at(0, 0) >> 8)
    end

    it 'shows the worst rank (red) for trouble with muscle control' do
      receive_from_server('You have a very difficult time with muscle control in your left arm.')

      expect(nsys_color).to eq 'ff0000'
    end

    it 'shows the middle rank (orange) for constant muscle spasms' do
      receive_from_server('You have constant muscle spasms in your right leg.')

      expect(nsys_color).to eq 'ff9900'
    end

    it 'shows the lowest rank (yellow) for slurred speech' do
      receive_from_server('You have developed slurred speech.')

      expect(nsys_color).to eq 'ffff00'
    end

    it 'stays in its no-damage color for other text' do
      receive_from_server('You swing your sword at a goblin.')

      expect(nsys_color).to eq '444444'
    end
  end

  describe 'the stun countdown' do
    before do
      load_layout(<<~XML)
        <window class='text' top='0' left='0' height='8' width='80' value='main'/>
        <window class='countdown' top='20' left='0' height='1' width='12' label='Stunned' value='stunned'/>
      XML
    end

    # What the stun countdown window shows: its label and the seconds left.
    def stun_countdown
      @window_manager.countdown['stunned'].rows.first
    end

    it 'counts down five seconds per round of stun' do
      receive_from_server('You are stunned for 5 rounds!')

      expect(stun_countdown).to eq 'Stunned   25'
    end

    it 'counts down five seconds for a single round' do
      receive_from_server('You are stunned for 1 round!')

      expect(stun_countdown).to eq 'Stunned    5'
    end

    it 'recognizes the stun message indented by spaces' do
      receive_from_server('  You are stunned for 12 rounds!')

      expect(stun_countdown).to eq 'Stunned   60'
    end

    it 'does not start on a line that only mentions a stun' do
      receive_from_server('The goblin looks stunned.',
                          'Bob says, "You are stunned for 3 rounds!"')

      expect(stun_countdown).to eq 'Stunned    0'
    end
  end

  describe 'the hand indicators after a glance at empty hands' do
    # (What each hand shows after a glance is in glance_hands_spec.rb.)
    it 'are drawn to the terminal even when no window shows the glance text' do
      load_layout(<<~XML)
        <window class='indicator' top='23' left='20' height='1' width='20' label=' ' value='left'/>
        <window class='indicator' top='23' left='45' height='1' width='20' label=' ' value='right'/>
      XML
      allow(Curses).to receive(:doupdate).and_call_original

      receive_from_server('You glance down at your empty hands.')

      expect(Curses).to have_received(:doupdate)
    end
  end

  describe 'which window shows a line' do
    it 'shows regular game text in main' do
      load_layout("<window class='text' top='0' left='0' height='8' width='80' value='main'/>")

      receive_from_server('A goblin attacks you!')

      expect(shown_in('main')).to eq ['A goblin attacks you!']
    end

    it "shows a stream's text in its own window, not in main" do
      load_layout(<<~XML)
        <window class='text' top='0' left='0' height='8' width='80' value='main'/>
        <window class='text' top='10' left='0' height='8' width='80' value='combat'/>
      XML

      receive_from_server('<pushStream id="combat"/>A goblin swings at you.<popStream/>')

      expect(shown_in('combat')).to eq ['A goblin swings at you.']
      expect(shown_in('main')).to be_empty
    end

    it "shows the text of a stream without a window in main, in the stream's preset color" do
      load_layout("<window class='text' top='0' left='0' height='8' width='80' value='main'/>")
      PRESET['thoughts'] = ['00ff00', nil]

      receive_from_server('<pushStream id="thoughts"/>Someone thinks out loud.<popStream/>')

      expect(shown_in('main')).to eq ['Someone thinks out loud.']
      expect(color_in_main('Someone thinks out loud.')).to eq '00ff00'
    end

    it 'shows no row for a line of only spaces' do
      load_layout("<window class='text' top='0' left='0' height='8' width='80' value='main'/>")

      receive_from_server('A goblin arrives.', '   ', 'A goblin leaves.')

      expect(@window_manager.stream['main'].rows.first(2)).to eq ['A goblin arrives.', 'A goblin leaves.']
    end

    it 'colors the words a highlight matches' do
      load_layout("<window class='text' top='0' left='0' height='8' width='80' value='main'/>")
      HIGHLIGHT[/goblin/] = ['ff0000', nil, nil]

      receive_from_server('A goblin attacks you!')

      expect(color_in_main('goblin')).to eq 'ff0000'
      expect(color_in_main('attacks you!')).to be_nil
    end
  end

  describe 'the pending prompt' do
    before { load_layout("<window class='text' top='0' left='0' height='12' width='80' value='main'/>") }

    it 'shows before the next line of game text' do
      receive_from_server(same_prompt, 'Hello world.')

      expect(shown_in('main')).to eq ['>', 'Hello world.']
    end

    it 'shows after a line that is not movement' do
      receive_from_server('You attack the goblin.', same_prompt, 'The goblin dodges.')

      expect(shown_in('main')).to eq ['You attack the goblin.', '>', 'The goblin dodges.']
    end

    it 'is skipped after a movement line' do
      receive_from_server('You walk north.', same_prompt, 'A breeze blows.')

      expect(shown_in('main')).to eq ['You walk north.', 'A breeze blows.']
    end

    it 'is skipped after each movement verb the game uses' do
      movement_verbs = %w[run walk go swim climb crawl drag stride sneak stalk]

      main_after = movement_verbs.to_h do |verb|
        load_layout("<window class='text' top='0' left='0' height='12' width='80' value='main'/>")
        receive_from_server("You #{verb} through the archway.", same_prompt, 'A breeze blows.')
        [verb, shown_in('main')]
      end

      expect(main_after).to eq(movement_verbs.to_h { |verb| [verb, ["You #{verb} through the archway.", 'A breeze blows.']] })
    end

    it 'is used up by a bracket prompt line, which shows in its place' do
      receive_from_server(same_prompt, '[Cleric]>', 'Hello world.')

      expect(shown_in('main')).to eq ['[Cleric]>', 'Hello world.']
    end
  end
end
