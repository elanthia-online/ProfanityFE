# frozen_string_literal: true

# Tests bold that the game opens on one line and closes on a later one.
# The lines are driven through the real server loop into a real window built
# from layout XML, and the assertions are on what the window shows: text is
# in the monsterbold color while bold is open, and only then.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

# Load the REAL GagPatterns module (replaces the spec_helper stub)
original_verbose = $VERBOSE
$VERBOSE = nil
load File.expand_path('../../lib/gag_patterns.rb', __dir__)
$VERBOSE = original_verbose

RSpec.describe 'Bold across lines' do
  before { GagPatterns.load_defaults }
  after { GagPatterns.load_defaults }

  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  # Color pair number per foreground color, so a cell's color can be read
  # back from its attributes.
  let(:pairs) { { 'ff0000' => 1 } }

  before do
    PRESET['monsterbold'] = ['ff0000', nil]
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    allow(IO).to receive(:select).and_return(nil)

    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='8' width='80' value='main'/>
      </layout>
    XML
    @wm = WindowManager.new
    @wm.load_layout('test')
    @wm.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would. Lich ends every line with CRLF.
  def receive_from_server(*lines, line_end: "\r\n")
    queue = lines.map { |line| "#{line}#{line_end}" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    @processor.run(server)
  end

  # Color of each character of +text+ where main shows it: a color code,
  # nil when uncolored, or an Array when mixed.
  def color_on_screen(text)
    win = @wm.stream['main']
    y = win.rows.index { |row| row.include?(text) }
    raise "#{text.inspect} not on screen: #{win.rows.reject(&:empty?).inspect}" unless y

    x = win.row(y).index(text)
    colors = (x...(x + text.length)).map { |col| pairs.key(win.attrs_at(y, col) >> 8) }.uniq
    colors.size == 1 ? colors.first : colors
  end

  it 'carries bold to following lines until a line starting with <popBold/>' do
    receive_from_server('A troll says, <pushBold/>',
                        'Come closer.',
                        'Closer still.',
                        '<popBold/>The troll grins.')

    expect(color_on_screen('Come closer.')).to eq 'ff0000'
    expect(color_on_screen('Closer still.')).to eq 'ff0000'
    expect(color_on_screen('The troll grins.')).to be_nil
  end

  it 'turns bold off after a line that closes it mid-line' do
    receive_from_server('A troll says, <pushBold/>',
                        'Come closer.<popBold/> The troll grins.',
                        'You wave.')

    expect(color_on_screen('Come closer.')).to eq 'ff0000'
    expect(color_on_screen('The troll grins.')).to be_nil
    expect(color_on_screen('You wave.')).to be_nil
  end

  it 'keeps bold on after a line that closes it and opens it again' do
    receive_from_server('A troll says, <pushBold/>',
                        'Come<popBold/> and <pushBold/>closer.',
                        'Closer still.<popBold/>',
                        'You wave.')

    expect(color_on_screen(' and ')).to be_nil
    expect(color_on_screen('closer.')).to eq 'ff0000'
    expect(color_on_screen('Closer still.')).to eq 'ff0000'
    expect(color_on_screen('You wave.')).to be_nil
  end

  # Real DragonRealms FLAG output: the header opens bold with text after
  # it, and the next line closes bold at its start.
  it 'shows the text of a line that leaves bold open in bold' do
    receive_from_server('<pushBold/>  Flag            Status  Behavior for this setting',
                        '<popBold/>  <d cmd="flag LogOn on">LogOn</d>              OFF  Do not show logon messages.')

    expect(color_on_screen('Flag            Status  Behavior for this setting')).to eq 'ff0000'
    expect(color_on_screen('LogOn              OFF  Do not show logon messages.')).to be_nil
  end

  it 'ends carried bold at a prompt' do
    receive_from_server('A troll says, <pushBold/>',
                        'Come closer.',
                        '<prompt time="1790395961">&gt;</prompt>',
                        'You wave.')

    expect(color_on_screen('Come closer.')).to eq 'ff0000'
    expect(color_on_screen('You wave.')).to be_nil
  end

  it 'turns bold off after a gagged line that closes it' do
    GagPatterns.add_general_pattern('The troll grins\.')

    receive_from_server('A troll says, <pushBold/>',
                        'Come closer.<popBold/> The troll grins.',
                        'You wave.')

    expect(@wm.stream['main'].rows.reject(&:empty?)).to eq ['A troll says,', 'You wave.']
    expect(color_on_screen('You wave.')).to be_nil
  end

  it 'still shows a pending prompt at a blank line while bold is carried' do
    receive_from_server('A troll says, <pushBold/>')
    state.need_prompt = true
    receive_from_server('')

    expect(@wm.stream['main'].rows.reject(&:empty?)).to eq ['A troll says,', '>']

    receive_from_server('Come closer.')

    expect(color_on_screen('Come closer.')).to eq 'ff0000'
  end

  it 'carries bold whatever the line ending' do
    receive_from_server('A troll says, <pushBold/>',
                        'Come closer.',
                        '<popBold/>The troll grins.',
                        line_end: "\n")

    expect(color_on_screen('Come closer.')).to eq 'ff0000'
    expect(color_on_screen('The troll grins.')).to be_nil
  end
end
