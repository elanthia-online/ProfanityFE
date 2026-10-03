# frozen_string_literal: true

# The game sends some stream text twice: once on the stream and once more
# as the next main line (GemStone speech and whispers, DR whispers). The
# main copy is dropped so the line shows once, in its stream window. With
# --speech-ts the window's line carries a timestamp the game's copy doesn't
# have; the copy must still be recognised. Every case replays real lines
# (GemStone corpus_streams, DR corpus) through the real server loop, layout
# builder and windows on the virtual screen.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/clock'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'The game\'s main copy of a stream line with --speech-ts' do
  before do
    # A screen wide enough that no line here wraps
    allow(Curses).to receive_messages(lines: 30, cols: 200)
    GagPatterns.load_defaults
    @now = Time.new(2026, 10, 1, 21, 0, 9)
  end

  # GSIV-Ilten/2026-10-01_21-00-59.xml:618-621: a speech line, then the
  # game's main copy of it, then the prompt.
  let(:ilten_speech) do
    [%(<pushStream id="speech"/><preset id='speech'><a exist="-11241335" noun="Vaelstar">Vaelstar</a> asks</preset>, "Any healers?"),
     '<popStream/>',
     %(<preset id='speech'><a exist="-11241335" noun="Vaelstar">Vaelstar</a> asks</preset>, "Any healers?")]
  end
  let(:ilten_prompt) { '<prompt time="1790903005">s&gt;</prompt>' }
  let(:asks) { 'Vaelstar asks, "Any healers?"' }

  let(:clock) { Clock.new(now: -> { @now }) }
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:windows) { %w[speech thoughts familiar whispers logons death] }
  let(:window_manager) do
    WindowManager.new(clock: clock).tap do |wm|
      rows = windows.each_with_index.map do |stream, i|
        "<window class='text' top='#{10 + ((i / 2) * 4)}' left='#{(i % 2) * 60}' height='4' width='60' value='#{stream}'/>"
      end
      LAYOUT['copies'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='10' width='120' value='main'/>
          #{rows.join("\n")}
        </layout>
      XML
      wm.load_layout('copies')
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

  # The non-blank rows of a stream's window, trailing blanks removed.
  def shown(stream)
    window_manager.stream[stream].rows.map(&:rstrip).reject(&:empty?)
  end

  describe 'a GemStone speech line' do
    it 'shows once, timestamped in the speech window, and not again in main' do
      receive_from_server(*ilten_speech, ilten_prompt)

      expect(shown('speech')).to eq ["#{asks} (21:00:09)"]
      expect(shown('main')).to be_empty
    end

    it 'is recognised at a one-digit hour too' do
      @now = Time.new(2026, 10, 2, 2, 13, 20)

      receive_from_server(*ilten_speech, ilten_prompt)

      expect(shown('speech')).to eq ["#{asks} (2:13:20)"]
      expect(shown('main')).to be_empty
    end

    it 'is recognised when the copy has trailing spaces' do
      receive_from_server(*ilten_speech[0, 2], "#{ilten_speech[2]}  ", ilten_prompt)

      expect(shown('main')).to be_empty
    end

    context 'without --speech-ts' do
      let(:speech_ts) { false }

      it 'is recognised as before' do
        receive_from_server(*ilten_speech, ilten_prompt)

        expect(shown('speech')).to eq [asks]
        expect(shown('main')).to be_empty
      end
    end

    it 'still shows a main line that only matches the timestamped form' do
      # Only the game's copy, as sent, is dropped: a main line that happens
      # to read like the window's timestamped line is not that copy.
      receive_from_server(*ilten_speech[0, 2], "#{asks} (21:00:09)", ilten_prompt)

      expect(shown('main')).to eq ["#{asks} (21:00:09)"]
    end

    it 'shows the copy when another main line comes first (only the next main line is compared)' do
      receive_from_server(*ilten_speech[0, 2],
                          'The sudden cawing of a crow is the only warning before a huge murder of the birds descend.',
                          ilten_speech[2], ilten_prompt)

      expect(shown('main')).to eq ['The sudden cawing of a crow is the only warning before a huge murder of the birds descend.',
                                   asks]
    end

    it 'shows the copy when a prompt comes between' do
      receive_from_server(*ilten_speech[0, 2], ilten_prompt, ilten_speech[2], ilten_prompt)

      expect(shown('main').grep(/Vaelstar/)).to eq [asks]
    end

    it 'shows a repeat of the same line after the copy was dropped' do
      receive_from_server(*ilten_speech, ilten_speech[2], ilten_prompt)

      expect(shown('main')).to eq [asks]
    end
  end

  describe 'a GemStone whisper' do
    # GSF-Pickasso/2026-10-01_22-00-48.xml: the whisper on the speech
    # stream, and the game's main copy with a link in it.
    let(:whisper) do
      [%(<pushStream id="speech"/><preset id="whisper">You quietly whisper to Nexushealbot,</preset> "Poison."),
       '<popStream/>',
       %(<preset id="whisper">You quietly whisper to <a exist="-11165808" noun="Nexushealbot">Nexushealbot</a>,</preset> "Poison.")]
    end

    it 'shows once, timestamped in the speech window' do
      receive_from_server(*whisper, ilten_prompt)

      expect(shown('speech')).to eq ['You quietly whisper to Nexushealbot, "Poison." (21:00:09)']
      expect(shown('main')).to be_empty
    end
  end

  describe 'a stream that has no window' do
    let(:windows) { %w[logons death] }

    it 'shows neither speech nor its copy check when the layout has no speech window' do
      # Speech has no fallback to main, so the copy is the only time it shows.
      receive_from_server(*ilten_speech, ilten_prompt)

      expect(shown('main')).to eq [asks]
    end

    it 'shows thoughts falling back to main timestamped, and a same-text main line after it' do
      # GSIV-Ilten/2026-10-01_21-00-59.xml; stream text shown in main is
      # never taken for a copy of itself.
      thought = '[Help] <a exist="-11198907" noun="Jirum">Jirum</a>: "Fun cart rides?"'
      receive_from_server(%(<pushStream id="thoughts"/>#{thought}), '<popStream/>', thought, ilten_prompt)

      expect(shown('main')).to eq ['[Help] Jirum: "Fun cart rides?" (21:00:09)', '[Help] Jirum: "Fun cart rides?"']
    end
  end

  describe 'a thoughts window' do
    it 'drops a main line repeating a timestamped thought' do
      # GemStone sends no main copy of thoughts (0 of 327); the rule is the
      # one speech uses, whatever the stream.
      thought = '[Help] <a exist="-11198907" noun="Jirum">Jirum</a>: "Fun cart rides?"'
      receive_from_server(%(<pushStream id="thoughts"/>#{thought}), '<popStream/>', thought, ilten_prompt)

      expect(shown('thoughts')).to eq ['[Help] Jirum: "Fun cart rides?" (21:00:09)']
      expect(shown('main')).to be_empty
    end
  end

  describe 'the lines stored as formatted (unchanged)' do
    it 'compares a GemStone logon by its HH:MM Name line, so the raw main line still shows' do
      # GSIV-Ilten/2026-10-01_21-00-59.xml:615-616; GemStone sends no main
      # copy of logons (0 of 4,932).
      logon = ' * <a exist="-11208433" noun="Baon">Baon</a> joins the adventure.'
      receive_from_server(%(<pushStream id="logons"/>#{logon}), '<popStream/>', logon, ilten_prompt)

      expect(shown('logons')).to eq ['21:00 Baon']
      expect(shown('main')).to eq [' * Baon joins the adventure.']
    end
  end

  describe 'a DR whisper (whispers is not a timestamped stream)' do
    # DR-Ytterby 2026-09-26 14:46:54: the copy follows the pop on the same line.
    it 'drops the main copy with --speech-ts, the window line unstamped' do
      receive_from_server('<pushStream id="whispers"/><preset id="whisper">Ytterby whispers,</preset> "Done!"',
                          '<popStream/><preset id="whisper">Ytterby whispers,</preset> "Done!"',
                          '<prompt time="1790390814">&gt;</prompt>')

      expect(shown('whispers')).to eq ['Ytterby whispers, "Done!"']
      expect(shown('main')).to be_empty
    end
  end
end
