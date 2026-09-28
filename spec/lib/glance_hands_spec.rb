# frozen_string_literal: true

# What the hand indicators show after a glance. DR sends a <right>/<left>
# tag only when a hand's contents change, so a hand that has been empty
# since login has never had a tag; the glance text is then the only thing
# that says it's empty. The layout matches a live one: both hand
# indicators start blank (label=' ').

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Hand indicators after a glance' do
  before { GagPatterns.load_defaults }

  let(:event_bus) { EventBus.new }
  let(:window_manager) do
    WindowManager.new.tap do |wm|
      LAYOUT['hands'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='10' width='80' value='main'/>
          <window class='indicator' top='23' left='20' height='1' width='20' label=' ' value='left'/>
          <window class='indicator' top='23' left='45' height='1' width='20' label=' ' value='right'/>
        </layout>
      XML
      wm.load_layout('hands')
      wm.subscribe_to_events(event_bus)
    end
  end
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: window_manager,
      shared_state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    allow(IO).to receive(:select).and_return(nil)
    allow(processor).to receive(:show_disconnect_message)
    allow(processor).to receive(:exit)
    processor.run(server)
  end

  # What a hand indicator shows, trailing blanks removed.
  def shown(hand)
    window_manager.indicator[hand].rows.first.rstrip
  end

  it 'shows both hands as Empty after glancing at empty hands' do
    receive_from_server('You glance down at your empty hands.')

    expect([shown('left'), shown('right')]).to eq %w[Empty Empty]
  end

  # BUG FOUND (fixed here): only the both-empty glance was recognized, so
  # with an item in the right hand the never-tagged left hand stayed blank.
  it 'shows the left hand as Empty when the glance finds nothing in it' do
    receive_from_server(
      '<right exist="96025553" noun="lootsack">cloth lootsack</right>',
      'You glance down to see a kertig greatsword with a tempered blade in your right hand and nothing in your left hand.'
    )

    expect(shown('left')).to eq 'Empty'
  end

  # Wording from the live game (2026-09-29): with only the left hand
  # holding something, the glance doesn't mention the right hand.
  it 'shows the right hand as Empty when only the left hand holds something' do
    receive_from_server(
      '<left exist="5" noun="codex">kuwinite codex</left>',
      'You glance down to see a firestained kuwinite codex gilded with Gorbesh iconography in your left hand.'
    )

    expect([shown('left'), shown('right')]).to eq ['kuwinite codex', 'Empty']
  end

  it 'turns the right hand indicator off, as an Empty hand tag does' do
    receive_from_server(
      '<right exist="1" noun="sword">steel sword</right>',
      'You glance down to see a firestained kuwinite codex in your left hand.'
    )
    from_glance = [shown('right'), window_manager.indicator['right'].value]

    receive_from_server('<right exist="1" noun="sword">steel sword</right>', '<right>Empty</right>')

    expect(from_glance).to eq [shown('right'), window_manager.indicator['right'].value]
  end

  it 'changes neither hand when the glance finds something in both' do
    receive_from_server(
      '<right exist="1" noun="sword">steel sword</right>',
      '<left exist="5" noun="codex">kuwinite codex</left>',
      'You glance down to see a steel sword in your right hand and a firestained kuwinite codex in your left hand.'
    )

    expect([shown('left'), shown('right')]).to eq ['kuwinite codex', 'steel sword']
  end

  it 'leaves the held hand showing the name from its tag, not the glance text' do
    receive_from_server(
      '<right exist="96025553" noun="lootsack">cloth lootsack</right>',
      'You glance down to see a heavy Imperial weave cloth lootsack in your right hand and nothing in your left hand.'
    )

    expect(shown('right')).to eq 'cloth lootsack'
  end

  # The indicator's value picks its colour (off for Empty, on when holding
  # something), so a stale "holding" value must not survive the glance.
  it 'turns the left hand indicator off, as an Empty hand tag does' do
    receive_from_server(
      '<left exist="1" noun="sword">steel sword</left>',
      'You glance down to see a cloth lootsack in your right hand and nothing in your left hand.'
    )
    from_glance = [shown('left'), window_manager.indicator['left'].value]

    receive_from_server('<left exist="1" noun="sword">steel sword</left>', '<left>Empty</left>')

    expect(from_glance).to eq [shown('left'), window_manager.indicator['left'].value]
  end
end
