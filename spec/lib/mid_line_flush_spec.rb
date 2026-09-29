# frozen_string_literal: true

# Tests color spans that are still open when the text parsed so far is
# flushed in the middle of a server line: at a stream switch, or at the end
# of a room description captured for the room window. The lines are driven
# through the real server loop into real windows built from layout XML, and
# the assertions are on what the windows show: the span colors its text on
# both sides of the flush.

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

RSpec.describe 'Color spans across a mid-line flush' do
  before { GagPatterns.load_defaults }
  after { GagPatterns.load_defaults }

  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  # Color pair number per foreground color, so a cell's color can be read
  # back from its attributes.
  let(:pairs) { { 'ff0000' => 1, '00ff00' => 2, '0000ff' => 3 } }

  before do
    PRESET['monsterbold'] = ['ff0000', nil]
    PRESET['speech'] = ['00ff00', nil]
    PRESET['roomDesc'] = ['0000ff', nil]
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    allow(IO).to receive(:select).and_return(nil)
  end

  # Build the windows from layout XML, with a room window when asked.
  #
  # @param room_window [Boolean] whether the layout has a room window
  # @return [void]
  def load_layout(room_window: false)
    room = room_window ? "<window class='room' top='12' left='0' height='8' width='80'/>" : ''
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='8' width='80' value='main'/>
        <window class='text' top='8' left='0' height='4' width='80' value='thoughts'/>
        #{room}
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
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    @processor.run(server)
  end

  # Color of each character of +text+ where a window shows it: a color
  # code, nil when uncolored, or an Array when mixed.
  def color_on_screen(text, stream: 'main')
    win = @wm.stream[stream]
    y = win.rows.index { |row| row.include?(text) }
    raise "#{text.inspect} not on screen: #{win.rows.reject(&:empty?).inspect}" unless y

    x = win.row(y).index(text)
    colors = (x...(x + text.length)).map { |col| pairs.key(win.attrs_at(y, col) >> 8) }.uniq
    colors.size == 1 ? colors.first : colors
  end

  it 'keeps bold open across a stream switch' do
    load_layout
    receive_from_server('<pushBold/>A troll<pushStream id="thoughts"/>You sense rage.<popStream/> snarls.<popBold/> You wave.')

    expect(color_on_screen('A troll')).to eq 'ff0000'
    expect(color_on_screen('You sense rage.', stream: 'thoughts')).to eq 'ff0000'
    expect(color_on_screen('snarls.')).to eq 'ff0000'
    expect(color_on_screen('You wave.')).to be_nil
  end

  it 'keeps a preset and a color open across a stream switch' do
    load_layout
    receive_from_server('<preset id="speech">A troll says, <pushStream id="thoughts"/>Hm.<popStream/>"Hi."</preset> ' \
                        '<color fg="FF0000">Red<pushStream id="thoughts"/>Hm.<popStream/>der</color> done')

    expect(color_on_screen('A troll says,')).to eq '00ff00'
    expect(color_on_screen('"Hi."')).to eq '00ff00'
    expect(color_on_screen('Red')).to eq 'ff0000'
    expect(color_on_screen('der')).to eq 'ff0000'
    expect(color_on_screen('done')).to be_nil
  end

  # Real DragonRealms room output: with a room window, the description is
  # flushed at its closing </preset> so the room window can capture it.
  it 'colors a room description in main with its preset when there is a room window' do
    load_layout(room_window: true)
    receive_from_server('<style id="roomName" />[Kaal Utewg, Old Growth] (4219307)',
                        "<style id=\"\"/><preset id='roomDesc'>In the darkness, trees appear.</preset>  " \
                        'You also see <pushBold/>a void-black umbral moth<popBold/>.')

    expect(color_on_screen('In the darkness, trees appear.')).to eq '0000ff'
    expect(color_on_screen('a void-black umbral moth')).to eq 'ff0000'
    expect(color_on_screen('You also see ')).to be_nil
  end

  it 'keeps a color open past a room title shown only in the room window' do
    state.room_window_only = true
    load_layout(room_window: true)
    receive_from_server('<style id="roomName" />[Kaal Utewg] <color fg="FF0000">x<style id=""/>Red</color> done')

    expect(color_on_screen('Red')).to eq 'ff0000'
    expect(color_on_screen('done')).to be_nil
  end

  it 'colors a room description in main with its preset when there is no room window' do
    load_layout
    receive_from_server('<style id="roomName" />[Kaal Utewg, Old Growth] (4219307)',
                        "<style id=\"\"/><preset id='roomDesc'>In the darkness, trees appear.</preset>  " \
                        'You also see <pushBold/>a void-black umbral moth<popBold/>.')

    expect(color_on_screen('In the darkness, trees appear.')).to eq '0000ff'
    expect(color_on_screen('a void-black umbral moth')).to eq 'ff0000'
  end
end
