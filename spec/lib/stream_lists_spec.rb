# frozen_string_literal: true

# Tests which streams fall back to main when the layout has no window for
# them, which of them get highlights there, and which get a --speech-ts
# timestamp with and without a window of their own. The expected lists are
# the two alternations GameTextProcessor#handle_game_text used to spell out
# as regexes; every case is driven through the real server loop.
#
# The two timestamp lists differ on purpose (maintainer decision, audit
# §0.2): speech is timestamped only in a speech window, never in main.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../../lib/mouse_scroll'
require_relative '../../lib/autocomplete'
require_relative '../../lib/selection_manager'
require_relative '../../lib/application'

RSpec.describe 'Stream fallback and timestamp lists' do
  # The routable-stream alternation, as written twice before Streams.
  routable = %w[death logons thoughts voln familiar assess ooc shopWindow combat moonWindow atmospherics]
  # Streams the old regex didn't match: speech (the deliberate gap), names
  # that only contain or differ in case from a routable one, and streams
  # other code handles by name.
  not_routable = ['speech', 'whispers', 'Death', 'deaths', 'xdeath', 'death ', ' death', 'thought', 'shop',
                  'lnet', 'percWindow', 'exp', 'inv', 'group']

  # A line with no timestamp, and one timestamp as append_speech_timestamp writes it.
  timestamp = /\A\S.* \(\d{1,2}:\d{2}:\d{2}\)\z/

  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:shown) { [] }
  # The processor's speech_timestamps: flag (--speech-ts).
  let(:speech_ts) { false }

  before do
    event_bus.on(:stream_text) { |data| shown << data unless data[:text].empty? }
  end

  # Feed raw server lines through GameTextProcessor#run with a layout whose
  # windows are +streams+ (main is always there).
  def receive_from_server(*lines, windows: [])
    stream = (['main'] + windows).to_h { |name| [name, Object.new] }
    wm = Struct.new(:stream, :indicator, :progress, :countdown, :room,
                    :command_window, :command_window_layout).new(stream, {}, {}, {}, {}, nil, nil)
    processor = GameTextProcessor.new(
      window_mgr: wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus, speech_timestamps: speech_ts
    )
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    allow(IO).to receive(:select).and_return(nil)
    processor.run(server)
  end

  def on_stream(id, text, windows: [])
    receive_from_server("<pushStream id='#{id}'/>#{text}", "<popStream id='#{id}'/>", windows: windows)
  end

  describe 'with no window for the stream' do
    routable.each do |id|
      it "shows #{id} text in main, highlighted" do
        HIGHLIGHT[/goblin/] = ['ff0000', nil, nil]

        on_stream(id, 'A goblin waves.')

        expect(shown.map { |d| [d[:stream], d[:text]] }).to eq [['main', 'A goblin waves.']]
        expect(shown.first[:colors]).to include(a_hash_including(start: 2, end: 8, fg: 'ff0000'))
      end
    end

    not_routable.each do |id|
      it "doesn't show #{id.inspect} text anywhere" do
        on_stream(id, 'A goblin waves.')

        expect(shown).to be_empty
      end
    end

    it 'shows main text after a dropped stream (routing returns to main)' do
      receive_from_server("<pushStream id='speech'/>You say, \"Hi.\"", "<popStream id='speech'/>", 'A goblin waves.')

      expect(shown.map { |d| [d[:stream], d[:text]] }).to eq [['main', 'A goblin waves.']]
    end
  end

  describe 'with a window for the stream' do
    (routable + not_routable).each do |id|
      it "shows #{id.inspect} text in its own window" do
        on_stream(id, 'A goblin waves.', windows: [id])

        expect(shown.map { |d| [d[:stream], d[:text]] }).to eq [[id, 'A goblin waves.']]
      end
    end
  end

  describe 'with --speech-ts' do
    let(:speech_ts) { true }

    in_window = %w[speech thoughts familiar]
    in_main = %w[thoughts familiar]

    (routable + ['speech', 'whispers', 'Speech']).each do |id|
      stamped = in_window.include?(id)
      it "#{stamped ? 'timestamps' : "doesn't timestamp"} #{id.inspect} in its own window" do
        on_stream(id, 'Some text.', windows: [id])

        expect(shown.size).to eq 1
        expect(shown.first[:stream]).to eq id
        if stamped
          expect(shown.first[:text]).to match(timestamp).and start_with('Some text. (')
        else
          expect(shown.first[:text]).to eq 'Some text.'
        end
      end
    end

    routable.each do |id|
      stamped = in_main.include?(id)
      it "#{stamped ? 'timestamps' : "doesn't timestamp"} #{id} when it falls back to main" do
        on_stream(id, 'Some text.')

        expect(shown.map { |d| d[:stream] }).to eq ['main']
        if stamped
          expect(shown.first[:text]).to match(timestamp).and start_with('Some text. (')
        else
          expect(shown.first[:text]).to eq 'Some text.'
        end
      end
    end

    it "shows no speech in main, stamped or not, when there's no speech window" do
      on_stream('speech', 'You say, "Hi."')

      expect(shown).to be_empty
    end

    it "doesn't timestamp LNet chat moved off thoughts to an lnet window" do
      # The lnet move happens before the timestamp check, so the line is on
      # lnet by then, which isn't a timestamped stream.
      on_stream('thoughts', '[Private]-GSIV:Bob: "hi"', windows: %w[thoughts lnet])

      expect(shown.map { |d| [d[:stream], d[:text]] }).to eq [['lnet', '[Private]-GSIV:Bob: "hi"']]
    end

    it "doesn't timestamp main text" do
      receive_from_server('A goblin waves.')

      expect(shown.map { |d| [d[:stream], d[:text]] }).to eq [['main', 'A goblin waves.']]
    end
  end

  describe 'without --speech-ts' do
    %w[speech thoughts familiar].each do |id|
      it "doesn't timestamp #{id} in its own window or in main" do
        on_stream(id, 'Some text.', windows: [id])
        on_stream(id, 'Some text.')

        expect(shown.map { |d| d[:text] }.uniq).to eq ['Some text.']
      end
    end
  end

  describe 'Application' do
    [true, false].each do |flag|
      it "passes speech_ts: #{flag} from the command-line options to the GameTextProcessor" do
        app = Application.new({ char: nil, no_status: true, links: false, room_window_only: false, speech_ts: flag },
                              settings_file: File.join(SPEC_HOME, 'settings.xml'), host: '127.0.0.1', port: 8000)
        app.instance_variable_set(:@server, StringIO.new)
        allow(GameTextProcessor).to receive(:new).and_call_original

        app.send(:start_server_thread).join

        expect(GameTextProcessor).to have_received(:new).with(a_hash_including(speech_timestamps: flag))
      end
    end
  end
end
