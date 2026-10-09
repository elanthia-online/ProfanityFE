# frozen_string_literal: true

# Tests the colors tysong.xml gives GemStone thoughts. A stream without a
# window falls back to main in the preset named after the stream, and the
# stream is 'thoughts', so the template's dark green background has to be
# the 'thoughts' preset to reach those lines.
#
# The settings are the bundled templates/tysong.xml, loaded through the real
# SettingsLoader, and its own 'default' layout is built on the virtual
# screen. At the specs' 80x24 terminal that layout's lnet/thoughts/voln
# window (left='81') is off-screen and not built, so thoughts fall back to
# main, as they do for a GemStone player on an 80-column terminal. Main is
# 60 columns wide there (min(140, cols-20)), so long lines wrap. The
# lines are real GemStone IV server lines (GSIV-Ilten, 2026-10-01), driven
# through the real server loop.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'
require_relative '../../lib/games'

RSpec.describe 'tysong.xml thoughts' do
  let(:template) { File.expand_path('../../templates/tysong.xml', __dir__) }
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  # A distinct color pair number for every fg/bg combination drawn, so a
  # cell's colors can be read back from its attributes.
  let(:pairs) { Hash.new { |hash, key| hash[key] = hash.size + 1 } }
  # 02:13:20 local time, for --speech-ts timestamps.
  let(:clock) { Clock.new(now: -> { Time.local(2026, 10, 2, 2, 13, 20) }) }
  # tysong's thoughts background.
  let(:thoughts_bg) { '001a00' }
  # tysong's highlight on a leading [...] tag, such as a thought's channel.
  let(:channel_fg) { '00C851' }
  # The prompt's own color in main (WindowManager).
  let(:prompt_fg) { '555555' }

  # A real [General] thought: a player link and a double space.
  let(:general) do
    ['<pushStream id="thoughts"/>[General] <a exist="-10740235" noun="Jazmeena">Jazmeena</a> thinks, ' \
     '"Why would I want to be a citizen of Zul Logoth?  It seems so  isolated."',
     '<popStream/><prompt time="1790902884">s&gt;</prompt>']
  end
  let(:general_text) do
    '[General] Jazmeena thinks, "Why would I want to be a citizen of Zul Logoth?  It seems so  isolated."'
  end

  # A real [Help] thought, its prompt and the real main line after it.
  let(:help_then_main) do
    ['<pushStream id="thoughts"/>[Help] <a exist="-11225917" noun="Jezrien">Jezrien</a>: "Maybe you should then."',
     '<popStream/><prompt time="1790906351">s&gt;</prompt>',
     'A blast of heat explodes from <a exist="-11213499" noun="Ajerain">Ajerain\'s</a> ' \
     '<a exist="600164029" noun="spikestar">golvern spikestar</a> as the violet flames surrounding it gain new life.']
  end
  let(:help_text) { '[Help] Jezrien: "Maybe you should then."' }

  # The [General] thought and the main line as main's 60 columns wrap
  # them: a continuation row starts with the 2-space wrap indent.
  let(:general_rows) do
    ['[General] Jazmeena thinks, "Why would I want to be a',
     '  citizen of Zul Logoth?  It seems so  isolated."']
  end
  let(:main_rows) do
    ["A blast of heat explodes from Ajerain's golvern spikestar",
     '  as the violet flames surrounding it gain new life.']
  end
  let(:main_text) do
    "A blast of heat explodes from Ajerain's golvern spikestar as the violet flames surrounding it gain new life."
  end

  before do
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, bg| pairs[[fg, bg]] }
    allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, bg| pairs[[fg, bg]] }
    allow(IO).to receive(:select).and_return(nil)
    expect(SettingsLoader.load(template, {}, Hash.new { |hash, name| hash[name] = proc {} }, proc {})).to be_nil
  end

  # Build tysong's default layout at the current terminal size and a GS
  # processor that feeds it.
  def build(speech_ts: false)
    @wm = WindowManager.new
    @wm.load_layout('default')
    @wm.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus, game_rules: Games.rules_for('GS'), speech_timestamps: speech_ts, clock: clock
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.flatten.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    @processor.run(server)
  end

  def shown_in(stream) = @wm.stream[stream].rows.reject(&:empty?)

  # The [fg, bg] of every character of the row of +stream+ showing +line+,
  # as runs: [[fg, bg], length] in order.
  def color_runs(stream, line)
    win = @wm.stream[stream]
    y = win.rows.index(line)
    colors = (0...line.length).map { |x| pairs.key(win.attrs_at(y, x) >> 8) || [nil, nil] }
    colors.chunk_while { |a, b| a == b }.map { |run| [run.first, run.size] }
  end

  context 'on an 80-column terminal (no thoughts window: thoughts fall back to main)' do
    it 'has no window for thoughts' do
      build

      expect(@wm.stream.keys).to include('main')
      expect(@wm.stream.keys).not_to include('thoughts', 'lnet', 'voln')
    end

    it 'shows a thought in main on the dark green background, the channel highlight kept' do
      build

      receive_from_server(general)

      expect(general_rows.join.squeeze(' ')).to eq general_text.squeeze(' ')
      expect(shown_in('main')).to eq general_rows
      expect(color_runs('main', general_rows[0])).to eq [
        [[channel_fg, thoughts_bg], '[General]'.length],
        [[nil, thoughts_bg], general_rows[0].length - '[General]'.length]
      ]
      # The wrap indent isn't part of the line, so it isn't colored.
      expect(color_runs('main', general_rows[1])).to eq [
        [[nil, nil], 2],
        [[nil, thoughts_bg], general_rows[1].length - 2]
      ]
    end

    it 'colors each thought, and not the prompt or the main line that follow it' do
      build

      receive_from_server(general, help_then_main)

      expect(shown_in('main')).to eq [*general_rows, help_text, 's>', *main_rows]
      expect(color_runs('main', help_text)).to eq [
        [[channel_fg, thoughts_bg], '[Help]'.length],
        [[nil, thoughts_bg], help_text.length - '[Help]'.length]
      ]
      expect(color_runs('main', 's>')).to eq [[[prompt_fg, nil], 2]]
      expect(main_rows.join.squeeze(' ')).to eq main_text.squeeze(' ')
      main_rows.each { |row| expect(color_runs('main', row)).to eq [[[nil, nil], row.length]] }
    end

    it 'extends the background over the --speech-ts timestamp' do
      build(speech_ts: true)

      receive_from_server(help_then_main.first(2))

      stamped = "#{help_text} (2:13:20)"
      expect(shown_in('main')).to eq [stamped]
      # Only the background: whether the timestamp is also dimmed is up to
      # the template's timestamp highlight.
      backgrounds = color_runs('main', stamped).flat_map { |(_fg, bg), length| [bg] * length }
      expect(backgrounds).to eq [thoughts_bg] * stamped.length
    end
  end

  context 'on a terminal wide enough for the thoughts window' do
    before do
      allow(Curses).to receive_messages(lines: 55, cols: 234)
    end

    # The thoughts window doesn't apply the stream's preset (only the
    # fallback to main and the spell window do); it shows the line in its
    # tag colors and highlights.
    it 'shows a thought in the thoughts window without the background, and nothing in main' do
      build

      receive_from_server(help_then_main.first(2))

      expect(shown_in('thoughts')).to eq [help_text]
      expect(color_runs('thoughts', help_text)).to eq [
        [[channel_fg, nil], '[Help]'.length],
        [[nil, nil], help_text.length - '[Help]'.length]
      ]
      expect(shown_in('main')).to eq []
    end
  end

  it "names no preset 'thought' (no stream has that name)" do
    expect(PRESET.keys).to include('thoughts')
    expect(PRESET.keys).not_to include('thought')
  end
end
