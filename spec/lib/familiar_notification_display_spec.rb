# frozen_string_literal: true

# Tests what the user sees when a game line triggers a familiar-window
# notification. The lines are driven through the real server loop into real
# windows built from layout XML, and the assertions are on each window's
# screen: the notification shows in the familiar window in its own color,
# and the triggering line still shows in main with its own tag colors and
# highlights.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/window_manager'

RSpec.describe 'Familiar notification display' do
  let(:event_bus) { EventBus.new }
  let(:state) do
    Struct.new(:need_prompt, :prompt_text, :skip_server_time_offset,
               :room_title, :blue_links, :room_window_only, :server_time_offset,
               :remote_url, :log_gags) do
      def update_terminal_title = nil
    end.new(false, '>', true, '', false, false, 0.0, false, false)
  end
  # Color pair number per foreground color, so a cell's color can be read
  # back from its attributes.
  let(:pairs) { { 'ff0000' => 1, '00ff00' => 2 } }
  let(:trigger) { 'Foo You sense nothing wrong with Mahtra.' }

  before do
    PRESET['monsterbold'] = ['ff0000', nil]
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    allow(IO).to receive(:select).and_return(nil)

    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='3' width='60' value='main'/>
        <window class='text' top='3' left='0' height='3' width='60' value='familiar'/>
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

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    @processor.run(server)
  end

  def window(stream) = @wm.stream[stream]

  # Color of each character of +word+ on the row of +stream+ showing +line+:
  # a color code, nil when uncolored, or an Array when mixed.
  def color_on_screen(stream, line, word)
    win = window(stream)
    y = win.rows.index { |row| row.include?(line) }
    x = win.row(y).index(word)
    colors = (x...(x + word.length)).map { |col| pairs.key(win.attrs_at(y, col) >> 8) }.uniq
    colors.size == 1 ? colors.first : colors
  end

  it 'shows the notification in the familiar window in the monsterbold color' do
    receive_from_server('<pushBold/>Foo<popBold/> You sense nothing wrong with Mahtra.')

    expect(window('familiar').rows.reject(&:empty?)).to eq ['Mahtra is all healthy.']
    expect(color_on_screen('familiar', 'Mahtra is all healthy.', 'Mahtra is all healthy.')).to eq 'ff0000'
  end

  it 'keeps the bold color of the triggering line in main' do
    receive_from_server('<pushBold/>Foo<popBold/> You sense nothing wrong with Mahtra.')

    expect(window('main').rows.reject(&:empty?)).to eq [trigger]
    expect(color_on_screen('main', trigger, 'Foo')).to eq 'ff0000'
    expect(color_on_screen('main', trigger, 'You sense nothing wrong')).to be_nil
  end

  it 'applies highlights to the triggering line in main, as to any other line' do
    HIGHLIGHT[/Mahtra/] = ['00ff00', nil, nil]

    receive_from_server('<pushBold/>Foo<popBold/> You sense nothing wrong with Mahtra.')

    expect(color_on_screen('main', trigger, 'Foo')).to eq 'ff0000'
    expect(color_on_screen('main', trigger, 'Mahtra')).to eq '00ff00'
    expect(color_on_screen('familiar', 'Mahtra is all healthy.', 'Mahtra is all healthy.')).to eq 'ff0000'
  end
end
