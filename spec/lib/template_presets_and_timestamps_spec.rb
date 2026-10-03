# frozen_string_literal: true

# Tests two settings the bundled templates share with tysong.xml.
#
# The thoughts preset: a stream without a window falls back to main in the
# preset named after the stream, and the stream is 'thoughts' (both games
# send <pushStream id="thoughts"/>), so a template's thoughts color has to
# be the 'thoughts' preset to reach those lines. mahtra.xml and default.xml
# put their thoughts window at top='33', so below 34 rows (the specs' 80x24
# terminal) it isn't built and thoughts fall back to main. The line is a
# real DragonRealms server line (DR corpus, 2026-08-06), driven through the
# real server loop on the virtual screen.
#
# The dim-timestamp highlight: --speech-ts writes the hour without a
# leading zero ("(2:13:20)", Clock#h_mm_ss), so original.xml's pattern has
# to allow a one-digit hour to match a timestamp before 10:00.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'
require_relative '../../lib/games'

RSpec.describe 'bundled templates' do
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  # A distinct color pair number for every fg/bg combination drawn, so a
  # cell's colors can be read back from its attributes.
  let(:pairs) { Hash.new { |hash, key| hash[key] = hash.size + 1 } }

  # A real thought, as DR sent it (log prefix removed), and its pop.
  let(:thought) do
    ['<pushStream id="thoughts"/>[DRPrime]-DR:Souv: "I believe you can forage everything everywhere with few exceptions"',
     '<popStream/>']
  end
  let(:thought_text) { '[DRPrime]-DR:Souv: "I believe you can forage everything everywhere with few exceptions"' }

  before do
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, bg| pairs[[fg, bg]] }
    allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, bg| pairs[[fg, bg]] }
    allow(IO).to receive(:select).and_return(nil)
  end

  def load_template(name)
    path = File.expand_path("../../templates/#{name}", __dir__)
    expect(SettingsLoader.load(path, {}, Hash.new { |hash, key| hash[key] = proc {} }, proc {})).to be_nil
  end

  # Build the template's default layout at the current terminal size and a
  # DR processor that feeds it.
  def build
    @wm = WindowManager.new
    @wm.load_layout('default')
    @wm.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus, game_rules: Games.rules_for('DR')
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.flatten.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    @processor.run(server)
  end

  # The rows of main the thought wraps onto (main is a tabbed window here:
  # its first row is the tab bar).
  def thought_rows
    rows = @wm.stream['main'].rows
    first = rows.index { |row| row.start_with?('[DRPrime]') }
    return [] unless first

    (first...rows.length).take_while { |y| !rows[y].empty? }
  end

  # The distinct [fg, bg] of the thought's characters in main.
  def thought_colors
    win = @wm.stream['main']
    thought_rows.flat_map do |y|
      row = win.rows[y]
      (0...row.length).reject { |x| row[x] == ' ' }.map { |x| pairs.key(win.attrs_at(y, x) >> 8) || [nil, nil] }
    end.uniq
  end

  %w[mahtra.xml default.xml].each do |template|
    context "#{template} on an 80x24 terminal (no thoughts window: thoughts fall back to main)" do
      before { load_template(template) }

      it 'has no window for thoughts' do
        build

        expect(@wm.stream.keys).to include('main')
        expect(@wm.stream.keys).not_to include('thoughts')
      end

      it 'shows a thought in main in the template\'s cyan, its highlights kept' do
        build

        receive_from_server(thought)

        shown = thought_rows.map { |y| @wm.stream['main'].rows[y].strip }.join(' ')
        expect(shown).to eq thought_text
        # Cyan wherever the template's highlights (the green [DRPrime] tag,
        # the white "you") don't color it; no character is left uncolored.
        expect(thought_colors).to contain_exactly(['46ac36', nil], ['0EE3D8', nil], ['FFFFFF', nil])
      end

      it 'defines no preset named after a stream the game never sends' do
        expect(PRESET.keys).to include('thoughts')
        expect(PRESET.keys).not_to include('thought')
      end
    end
  end

  context 'original.xml\'s dim-timestamp highlight' do
    before { load_template('original.xml') }

    # The 555555 regions HighlightProcessor gives +text+, as [start, end].
    def dimmed(text)
      HighlightProcessor.apply_highlights(text, []).select { |c| c[:fg] == '555555' }.map { |c| [c[:start], c[:end]] }
    end

    it 'dims a --speech-ts timestamp with a one-digit hour' do
      text = '[DRPrime]-DR:Souv: "I believe you can forage" (2:13:20)'

      expect(dimmed(text)).to eq [[text.index('('), text.length]]
    end

    it 'still dims one with a two-digit hour' do
      text = '[DRPrime]-DR:Souv: "I believe you can forage" (12:13:20)'

      expect(dimmed(text)).to eq [[text.index('('), text.length]]
    end

    it 'dims nothing that is not a timestamp at the end of the line' do
      expect(dimmed('Souv says, "(2:13:20) was the time."')).to eq []
      expect(dimmed('Souv says, (123:13:20)')).to eq []
    end
  end
end
