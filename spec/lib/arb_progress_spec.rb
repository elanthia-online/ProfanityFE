# frozen_string_literal: true

# A script progress bar (<arbProgress>) driven through the real server
# loop. The lines have the shape gs-scripts' effectmon.lic sends once a
# second for every effect bar: pushed to its own stream, with a label that
# carries the effect name and time left, and colors='bg,fg'.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Script progress bars (arbProgress)' do
  before do
    GagPatterns.load_defaults
    allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, bg| pairs[[fg, bg]] }
  end

  # A distinct color pair number for every fg/bg combination drawn, so the
  # virtual screen's attributes show which colors each cell got.
  let(:pairs) { Hash.new { |hash, key| hash[key] = hash.size + 1 } }

  let(:event_bus) { EventBus.new }
  let(:window_manager) do
    WindowManager.new.tap do |wm|
      LAYOUT['effects'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='10' width='80' value='main'/>
          <window class='progress' top='11' left='0' height='1' width='34' value='spell0'/>
        </layout>
      XML
      wm.load_layout('effects')
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
  let(:bar) { window_manager.progress['spell0'] }

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

  # One effect bar line as effectmon.lic sends it.
  def effect_bar(label, current, colors)
    "<pushStream id=\"effects\"/><arbProgress id='spell0' max='1200' current='#{current}' " \
      "label='#{label}' colors='#{colors}'></arbProgress><popStream/>"
  end

  # The bar's colors as [fg, bg] runs of [colors, length], left to right.
  def color_runs
    (0...bar.maxx).map { |x| pairs.key((bar.attrs_at(0, x) & Curses::A_COLOR) >> 8) }
                  .chunk_while { |a, b| a == b }.map { |run| [run.first, run.size] }
  end

  # How many times the bar was drawn since the log was last cleared.
  def bar_draws
    bar.call_log.count { |meth, _| meth == :noutrefresh }
  end

  it 'shows a new label that comes with the same value' do
    receive_from_server(effect_bar('Spirit Shield.......[00:10:00]', 600, '395573,9BA2B2'))

    receive_from_server(effect_bar('Spirit Warding I....[00:10:00]', 600, '395573,9BA2B2'))

    expect(bar.rows).to eq ['Spirit Warding I....[00:10:00] 600']
  end

  it 'shows new colors that come with the same value' do
    receive_from_server(effect_bar('Spirit Shield.......[00:10:00]', 600, '395573,9BA2B2'))

    receive_from_server(effect_bar('Spirit Shield.......[00:10:00]', 600, '767339,9BA2B2'))

    # Half full: the fill takes the new colors; the rest has none set.
    expect(color_runs).to eq [[%w[9BA2B2 767339], 17], [[nil, nil], 17]]
  end

  it 'does not draw the bar again when nothing changed' do
    receive_from_server(effect_bar('Spirit Shield.......[00:10:00]', 600, '395573,9BA2B2'))
    bar.call_log.clear

    receive_from_server(effect_bar('Spirit Shield.......[00:10:00]', 600, '395573,9BA2B2'))

    expect(bar_draws).to eq 0
  end

  it 'draws the bar once when the label, colors and value all change' do
    receive_from_server(effect_bar('Spirit Shield.......[00:10:00]', 600, '395573,9BA2B2'))
    bar.call_log.clear

    receive_from_server(effect_bar('Spirit Shield.......[00:00:59]', 59, '767339,9BA2B2'))

    expect([bar.rows, bar_draws]).to eq [['Spirit Shield.......[00:00:59]  59'], 1]
  end
end
