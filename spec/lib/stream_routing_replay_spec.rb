# frozen_string_literal: true

# Replays a captured game stream through the real server loop into real
# windows and checks which window every line ends up in.
#
# spec/fixtures/stream_routing_session.xml holds real lines from two DR
# Lich XML session logs (Ytterby 2026-08-27, Catheroine 2026-09-26),
# timestamps stripped: percWindow refreshes, room and exp components, an
# empath touch that opens the familiar stream twice and closes it with two
# bare pops, atmospherics, and combat closed by <popStream id="combat" />
# (once more than it was opened). The expected windows are the ones the old
# design (every pop returns to main) put these lines in; stream nesting must
# not move any of them.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Stream routing of a captured game stream' do
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }

  let(:streams) { %w[main familiar percWindow atmospherics combat] }
  let(:fixture) { File.expand_path('../fixtures/stream_routing_session.xml', __dir__) }

  before do
    rows = streams.each_with_index.map do |stream, i|
      klass = stream == 'percWindow' ? 'percWindow' : 'text'
      "<window class='#{klass}' top='#{i * 3}' left='0' height='3' width='200' value='#{stream}'/>"
    end
    LAYOUT['test'] = REXML::Document.new("<layout>#{rows.join}</layout>").root
    @wm = WindowManager.new
    @wm.load_layout('test')
    @wm.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
    # No 'look' at the first prompt: this server only reads
    @processor.instance_variable_get(:@prompts).instance_variable_set(:@first_prompt, false)
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    allow(IO).to receive(:select).and_return(nil)
    @processor.run(server)
  end

  # Every line a window holds, oldest first (the spell window's current list).
  def shown_in(stream)
    window = @wm.stream[stream]
    lines = window.is_a?(PercWindow) ? window.buffer_content : window.buffer.reverse
    lines.map(&:first)
  end

  it 'puts every line of the session in the same window as before' do
    receive_from_server(File.readlines(fixture, chomp: true))

    expect(streams.to_h { |s| [s, shown_in(s)] }).to eq(
      'main'         => [
        '>',
        'Fidon drums his fingers on his bucket rhythmically.',
        '>',
        'Fidon drums his fingers on his bucket rhythmically.',
        '>',
        "Throve puts his almanac in his scavenger's pack.",
        '>',
        'Chieftain Jazriel just arrived.',
        '>',
        'Your body feels at full strength. (100%)',
        'Your spirit feels full of life. (100%)',
        "Fidon rummages through a scuffed traveler's pack but it's clear he hasn't a clue if what he is looking for is there.",
        '>',
        'You touch Fidon.',
        'You sense a successful empathic link has been forged between you and Fidon.',
        "You feel the burning fire of pain and suffering building slowly as you instinctively draw out the truth behind Fidon's injuries.",
        'You sense nothing wrong with Fidon.',
        '>',
        'Jazriel visibly churns with an inner rage!',
        '>',
        'You begin to lecture Throve on the proper use of the Scholarship skill.',
        '>',
        'You touch Throve.',
        'You sense a successful empathic link has been forged between you and Throve.',
        "You feel the burning fire of pain and suffering building slowly as you instinctively draw out the truth behind Throve's injuries.",
        '>',
        'Throve roots around the area for a moment.',
        'Throve forages around the area.',
        '>',
        'You reach out with your senses and see blazing (20/21) streams of vibrant blue and white Life mana flowing through the area.',
        'Letting your senses extend further, you feel there is luminous (14/21) mana to the south, and radiant (15/21) mana to the north.',
        'You sense the Regenerate spell upon you, which will last until you fail to provide 19 mana for it.',
        'Roundtime: 3 sec.',
        '>',
        'A deep howl of bloodlust erupts from Jazriel as his chest puffs out from the strain of corded chest muscles tightening all at once!',
        'You manage to remain upright!',
        'A jeol moradu howls in encouragement!',
        '>',
        'Gnarta leaps from hiding and ambushes a jeol moradu!',
        "Gnarta bends over the moradu's corpse briefly."
      ],
      'familiar'     => [
        "Fidon's injuries include...",
        '... no injuries to speak of.',
        'Fidon has normal vitality.',
        'Fidon is all healthy.'
      ],
      'percWindow'   => [
        'Regenerate (Indefinite)'
      ],
      'atmospherics' => [
        "The eyes of Gnarta's monk pendant flash white for a moment.",
        "The ka'hurst rivets on Gnarta's thighband shimmer with a strikingly green sheen."
      ],
      'combat'       => [
        "A jeol moradu's back is blistered and seared as the rivulet of blue-white lava rolls over it.",
        "A faint sizzling sound fills the air as the stream of blue-white magma grazes a jeol moradu's back.",
        "Gnarta's pernach lands a vicious strike that knocks the larynx clear back to the vertebrae (So much for last words!).  ",
        'A jeol moradu comes crashing down.  The impact of the giant causes the ground to tremble beneath you!',
        'Emeshest manages to remain upright!',
        'You manage to remain upright!',
        'Gnarta manages to remain upright!',
        'A jeol moradu howls in encouragement!',
        'A jeol moradu breathes his last, and the ground finally stops heaving.',
        'The swirling confines of malevolent darkness wane from about a jeol moradu.'
      ]
    )
  end
end
