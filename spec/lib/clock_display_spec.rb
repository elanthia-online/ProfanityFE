# frozen_string_literal: true

# What the player sees wherever Profanity shows the time: the timestamp on
# a window's lines, the time before a death or logon line, the --speech-ts
# timestamp, and a countdown's remaining seconds once the game's clock is
# known. The real layout builder, WindowManager and GameTextProcessor share
# one Clock stopped at a time the spec chooses; windows draw onto the
# virtual screen.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/clock'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'The time shown in windows' do
  before do
    GagPatterns.load_defaults
    @now = Time.new(2026, 9, 29, 9, 5, 7)
  end

  let(:clock) { Clock.new(now: -> { @now }) }
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:window_manager) do
    WindowManager.new(clock: clock).tap do |wm|
      LAYOUT['clock'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='3' width='40' value='main' timestamp='on'/>
          <window class='tabbed' top='3' left='0' height='3' width='40' tabs='arrivals' timestamp='on'/>
          <window class='text' top='6' left='0' height='3' width='40' value='death'/>
          <window class='text' top='9' left='0' height='3' width='40' value='logons'/>
          <window class='text' top='12' left='0' height='3' width='40' value='speech'/>
          <window class='countdown' top='15' left='0' height='1' width='20' value='roundtime' label='RT'/>
        </layout>
      XML
      wm.load_layout('clock')
      wm.subscribe_to_events(event_bus)
    end
  end
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: window_manager,
      shared_state: state,
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus,
      speech_timestamps: speech_ts,
      clock: clock
    )
  end
  let(:speech_ts) { false }
  let(:colors) { [] }

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

  # The non-blank rows of a stream's window, trailing blanks removed.
  def shown(stream)
    window_manager.stream[stream].rows.map(&:rstrip).reject(&:empty?)
  end

  # The color runs sent with each non-empty line for +stream+.
  def colors_for(stream)
    colors.select { |data| data[:stream] == stream }.map { |data| data[:colors] }
  end

  describe 'a window with timestamp="on"' do
    it 'shows the time after each line' do
      receive_from_server('A goblin waves.')

      expect(shown('main')).to eq ['A goblin waves. [09:05]']
    end

    it 'shows the time after each line in a tabbed window' do
      window_manager.stream['arrivals'].add_string('Mahtra arrives.')

      expect(shown('arrivals')).to include 'Mahtra arrives. [09:05]'
    end

    it 'shows the time each line was added' do
      window_manager.stream['main'].add_string('first')
      @now = Time.new(2026, 9, 29, 23, 0, 59)
      window_manager.stream['main'].add_string('second')

      expect(shown('main')).to eq ['first [09:05]', 'second [23:00]']
    end
  end

  describe 'the death window' do
    before { event_bus.on(:stream_text) { |data| colors << data unless data[:text].empty? } }

    it 'shows a DragonRealms death as the time and the name, the time in red' do
      receive_from_server('<pushStream id="death"/> * Bob was just struck down!', '<popStream id="death"/>')

      expect(shown('death')).to eq ['09:05 Bob']
      expect(colors_for('death')).to eq [[{ start: 0, end: 5, fg: 'ff0000' }]]
    end

    it 'marks a phoenix death "MF" and a sacrifice "Sacrifice"' do
      receive_from_server(
        '<pushStream id="death"/> * A fiery phoenix soars into the heavens as Bob\'s spirit arises from the ashes of death.',
        '<popStream id="death"/>',
        '<pushStream id="death"/> * Sue was just sacrificed to Eluned!', '<popStream id="death"/>'
      )

      expect(shown('death')).to eq ['09:05 Bob MF', '09:05 Sue Sacrifice']
    end

    it 'shows a GemStone death as the time, the name and the area, the time in red' do
      receive_from_server('<pushStream id="death"/> * Bob may just be going home on his shield!', '<popStream/>')

      expect(shown('death')).to eq ['09:05 Bob RED']
      expect(colors_for('death')).to eq [[{ start: 0, end: 5, fg: 'ff0000' }]]
    end

    it 'keeps highlights on the name after the time' do
      HIGHLIGHT[/Bob/] = ['00ff00', nil, nil]

      receive_from_server('<pushStream id="death"/> * Bob was just struck down!', '<popStream id="death"/>')

      expect(colors_for('death')).to match [[a_hash_including(start: 6, end: 9, fg: '00ff00'),
                                             { start: 0, end: 5, fg: 'ff0000' }]]
    end
  end

  describe 'the logons window' do
    before { event_bus.on(:stream_text) { |data| colors << data unless data[:text].empty? } }

    it 'shows an arrival as the time and the name, the time in the arrival color' do
      receive_from_server('<pushStream id="logons"/> * Mahtra joins the adventure with little fanfare.',
                          '<popStream id="logons"/>')

      expect(shown('logons')).to eq ['09:05 Mahtra']
      expect(colors_for('logons')).to eq [[{ start: 0, end: 5, fg: '007700' }]]
    end
  end

  describe 'the speech window with --speech-ts' do
    let(:speech_ts) { true }

    it 'shows the time after the line, without a leading zero on the hour' do
      receive_from_server(%(<pushStream id="speech"/>You say, "Hi."), '<popStream id="speech"/>')

      expect(shown('speech')).to eq ['You say, "Hi." (9:05:07)']
    end

    it 'keeps a two-digit hour' do
      @now = Time.new(2026, 9, 29, 21, 0, 9)

      receive_from_server(%(<pushStream id="speech"/>You say, "Hi."), '<popStream id="speech"/>')

      expect(shown('speech')).to eq ['You say, "Hi." (21:00:09)']
    end
  end

  describe 'a countdown' do
    # The game's clock (prompt time) runs 10.5 seconds behind this one.
    let(:server_now) { 1_790_000_000 }

    before do
      @now = Time.at(server_now + 10.5)
      state.skip_server_time_offset = false
    end

    def roundtime_shown = window_manager.countdown['roundtime'].rows.first

    it 'shows the seconds left by the game clock, counting down as this clock advances' do
      receive_from_server("<prompt time=\"#{server_now}\">&gt;</prompt>",
                          "<roundTime value='#{server_now + 5}'/>")

      expect(roundtime_shown).to eq "RT#{'5'.rjust(18)}"

      @now += 2
      window_manager.countdown['roundtime'].tick

      expect(roundtime_shown).to eq "RT#{'3'.rjust(18)}"
    end

    it 'shows no time left once the round time has passed' do
      receive_from_server("<prompt time=\"#{server_now}\">&gt;</prompt>",
                          "<roundTime value='#{server_now + 5}'/>")
      @now += 5
      window_manager.countdown['roundtime'].tick

      expect(roundtime_shown).to eq "RT#{'0'.rjust(18)}"
    end
  end
end
