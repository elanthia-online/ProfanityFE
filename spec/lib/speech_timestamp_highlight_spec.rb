# frozen_string_literal: true

# Highlights and the --speech-ts timestamp. Highlights apply once, to the
# line as it is shown: after the timestamp is added, so a highlight can
# match it (tysong.xml dims it), and never twice to the rest of the line.
# Real lines (GemStone corpus_streams) go through the real server loop,
# with tysong.xml's highlight table loaded by the real SettingsLoader, into
# windows on the virtual screen.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/clock'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Highlights on a --speech-ts timestamp' do
  dim = '555555'

  before do
    allow(Curses).to receive_messages(lines: 30, cols: 200)
    GagPatterns.load_defaults
    # tysong.xml's highlights (and presets), as the client loads them; its
    # key bindings need key names
    stub_const('KEY_NAME', KeyCodes.key_names(->(_code) {}))
    error = SettingsLoader.load(File.expand_path('../../templates/tysong.xml', __dir__), {},
                                Hash.new { |hash, name| hash[name] = proc {} }, proc {})
    raise error if error
    @now = Time.new(2026, 10, 1, 21, 0, 9)
    event_bus.on(:stream_text) { |data| sent << data.merge(colors: data[:colors].map(&:dup)) }
  end

  # GSIV-Ilten/2026-10-01_21-00-59.xml:618-619: a speech line.
  let(:ilten_speech) do
    [%(<pushStream id="speech"/><preset id='speech'><a exist="-11241335" noun="Vaelstar">Vaelstar</a> asks</preset>, "Any healers?"),
     '<popStream/>']
  end
  let(:asks) { 'Vaelstar asks, "Any healers?"' }
  # GSIV-Ilten/2026-10-01_21-00-59.xml: a thought.
  let(:ilten_thought) do
    ['<pushStream id="thoughts"/>[Help] <a exist="-11198907" noun="Jirum">Jirum</a>: "Fun cart rides?"', '<popStream/>']
  end
  let(:thought) { '[Help] Jirum: "Fun cart rides?"' }

  let(:sent) { [] }
  let(:clock) { Clock.new(now: -> { @now }) }
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:windows) { %w[speech thoughts] }
  let(:window_manager) do
    WindowManager.new(clock: clock).tap do |wm|
      rows = windows.each_with_index.map do |stream, i|
        "<window class='text' top='#{10 + (i * 4)}' left='0' height='4' width='120' value='#{stream}'/>"
      end
      LAYOUT['hl'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='10' width='120' value='main'/>
          #{rows.join("\n")}
        </layout>
      XML
      wm.load_layout('hl')
      wm.subscribe_to_events(event_bus)
    end
  end
  let(:speech_ts) { true }
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

  # The one line sent to +stream+.
  def line_on(stream)
    lines = sent.select { |data| data[:stream] == stream && !data[:text].empty? }
    expect(lines.size).to eq 1
    lines.first
  end

  # [start, end] of each run in +line+ with foreground +fg+.
  def spans(line, fg)
    line[:colors].select { |run| run[:fg] == fg }.map { |run| [run[:start], run[:end]] }
  end

  # The [start, end] of the " (H:MM:SS)" timestamp's parenthesis to the end.
  def timestamp_span(text)
    [text.rindex(' (') + 1, text.length]
  end

  describe 'in the speech window' do
    it 'dims the timestamp at a two-digit hour' do
      receive_from_server(*ilten_speech)

      line = line_on('speech')
      expect(line[:text]).to eq "#{asks} (21:00:09)"
      expect(spans(line, dim)).to eq [timestamp_span(line[:text])]
    end

    it 'draws the timestamp in the dim color and the speech in its own' do
      # One color pair per foreground/background, so the screen tells them apart
      pairs = Hash.new { |hash, key| hash[key] = hash.size + 1 }
      allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, bg| pairs[[fg, bg]] }

      receive_from_server(*ilten_speech)

      window = window_manager.stream['speech']
      start = window.row(0).index('(21:00:09)')
      dim_attr = Curses.color_pair(pairs[[dim, nil]])
      expect((start...start + 10).map { |x| window.attrs_at(0, x) }.uniq).to eq [dim_attr]
      expect(window.attrs_at(0, 0)).not_to eq dim_attr
    end

    [[0, 0, 0, '0:00:00'], [2, 13, 20, '2:13:20'], [9, 59, 59, '9:59:59'],
     [10, 0, 0, '10:00:00'], [23, 59, 59, '23:59:59']].each do |hour, min, sec, shown|
      it "dims the timestamp #{shown} (one- or two-digit hour)" do
        @now = Time.new(2026, 10, 2, hour, min, sec)

        receive_from_server(*ilten_speech)

        line = line_on('speech')
        expect(line[:text]).to eq "#{asks} (#{shown})"
        expect(spans(line, dim)).to eq [timestamp_span(line[:text])]
      end
    end

    it 'dims a GemStone whisper\'s timestamp' do
      # GSF-Pickasso/2026-10-01_22-00-48.xml
      receive_from_server('<pushStream id="speech"/><preset id="whisper">You quietly whisper to Nexushealbot,</preset> "Poison."',
                          '<popStream/>')

      line = line_on('speech')
      expect(spans(line, dim)).to eq [timestamp_span(line[:text])]
    end

    it 'colors the rest of the line once, in place' do
      HIGHLIGHT[/healers/] = ['ff0000', nil, nil]

      receive_from_server(*ilten_speech)

      line = line_on('speech')
      expect(spans(line, 'ff0000')).to eq [[asks.index('healers'), asks.index('healers') + 7]]
      expect(line[:colors].size).to eq line[:colors].uniq.size
    end

    it 'matches a highlight against the line as shown, timestamp included' do
      # A pattern anchored at the line's end now meets the timestamp
      # there, not the speech's closing quote.
      HIGHLIGHT[/"Any healers\?"$/] = ['ff0000', nil, nil]
      HIGHLIGHT[/healers\?" \(\d+:\d\d:\d\d\)$/] = ['00ff00', nil, nil]

      receive_from_server(*ilten_speech)

      line = line_on('speech')
      expect(spans(line, 'ff0000')).to eq []
      expect(spans(line, '00ff00')).to eq [[asks.index('healers'), line[:text].length]]
    end
  end

  describe 'thoughts' do
    it 'dims the timestamp in a thoughts window' do
      receive_from_server(*ilten_thought)

      line = line_on('thoughts')
      expect(line[:text]).to eq "#{thought} (21:00:09)"
      expect(spans(line, dim)).to eq [timestamp_span(line[:text])]
    end

    context 'when they fall back to main' do
      let(:windows) { [] }

      it 'dims the timestamp, colors the rest once and puts the stream color under both' do
        HIGHLIGHT[/cart/] = ['ff0000', nil, nil]
        # The stream's preset (tysong.xml names it `thought`, so set it here)
        PRESET['thoughts'] = ['00ff00', '001a00']

        receive_from_server(*ilten_thought)

        line = line_on('main')
        text = line[:text]
        expect(text).to eq "#{thought} (21:00:09)"
        expect(spans(line, dim)).to eq [timestamp_span(text)]
        expect(spans(line, 'ff0000')).to eq [[text.index('cart'), text.index('cart') + 4]]
        # The stream color spans the whole line and comes after the highlights
        expect(line[:colors].last).to eq(start: 0, fg: '00ff00', bg: '001a00', end: text.length)
        expect(line[:colors].count { |run| run[:fg] == '00ff00' }).to eq 1
      end
    end
  end

  describe 'without --speech-ts' do
    let(:speech_ts) { false }

    it 'shows no timestamp and colors the line as before' do
      HIGHLIGHT[/healers/] = ['ff0000', nil, nil]

      receive_from_server(*ilten_speech)

      line = line_on('speech')
      expect(line[:text]).to eq asks
      expect(spans(line, dim)).to eq []
      expect(spans(line, 'ff0000')).to eq [[asks.index('healers'), asks.index('healers') + 7]]
    end
  end

  describe 'main text' do
    it 'is colored once' do
      HIGHLIGHT[/crow/] = ['ff0000', nil, nil]

      # GSIV-Ilten/2026-10-01_21-00-59.xml:613
      receive_from_server('The sudden cawing of a crow is the only warning before a huge murder of the birds descend.')

      line = line_on('main')
      expect(spans(line, 'ff0000')).to eq [[23, 27]]
      expect(line[:colors].size).to eq line[:colors].uniq.size
    end
  end
end
