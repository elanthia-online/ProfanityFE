# frozen_string_literal: true

# The room players indicator's names, driven through the real server loop
# into windows built from layout XML, on each way the players arrive: the
# room players component, and the inline "Also here:" line a LOOK sends
# (read at the exits line with a room window, at once without one).
#
# Each line comes two ways: linked, as DragonRealms sends it when Lich
# identifies as the Saga client and passes its links on (Profanity's
# --rich-stream; GemStone always links players), and with the links
# stripped, as Lich sends it to every other Profanity. The post strings
# are free text, in the shapes of real ones (2026-11 DR logs): "whose form
# ...", a post string with its own " and ", one ending in its own
# "... and crossbones", a status after a bare verb. The names and titles
# are made up.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Room players indicator names' do
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:indicator_updates) { [] }

  def load_layout(*windows)
    LAYOUT['test'] = REXML::Document.new("<layout>#{windows.join}</layout>").root
    @wm = WindowManager.new
    @wm.load_layout('test')
    @wm.subscribe_to_events(event_bus)
    event_bus.on(:indicator_update) { |data| indicator_updates << data if data[:id] == 'room players' }
    @processor = GameTextProcessor.new(
      window_mgr: @wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  before { allow(IO).to receive(:select).and_return(nil) }

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |_command| nil }
    server.define_singleton_method(:flush) { nil }
    @processor.run(server)
  end

  def link(name, id) = %(<a exist="-#{id}" noun="#{name}">#{name}</a>)

  # What Lich sends a front end without the game_links capability
  # (Markup.strip_game_links).
  def strip_links(line) = line.gsub(/<a\b[^>]*>|<\/a>/, '')

  def label = indicator_updates.last[:label]

  let(:players) do
    "Also here: Goblin Bait #{link('Aldric', 10700002)} whose form wavers within a roiling cloud of grey smoke, " \
      "Daydreamer #{link('Brenna', 10700003)} who is coated in grime and surrounded by a swirling cloud of filth, " \
      "Keeper of Secrets #{link('Delphine', 10700005)} (prone), " \
      "Stray #{link('Eamon', 10700006)} is surrounded by swirling flames, " \
      "#{link('Fenna', 10700007)} who is trailed by a flag displaying a skull and crossbones " \
      "and Druid #{link('Corwin', 10700004)} who is sitting."
  end
  let(:names) { 'Aldric, Brenna, Delphine, Eamon, Fenna, Corwin' }

  let(:main_window) { "<window class='text' top='0' left='0' height='4' width='80' value='main'/>" }
  let(:room_window) { "<window class='room' top='4' left='0' height='12' width='80' value='room'/>" }
  let(:indicator) { "<window class='indicator' top='16' left='0' height='1' width='60' value='room players' label=' '/>" }

  # A LOOK in DR's format: the room's inline lines, ended by its exits.
  def look(players_line)
    ['<resource picture="0"/><style id="roomName" />[Willow Walk, Willow Tree] (84081)',
     %(<style id=""/><preset id='roomDesc'>A weeping willow.</preset>  You also see a bench.),
     players_line,
     'Obvious paths: <d>north</d>.',
     '<prompt time="1791331836">&gt;</prompt>']
  end

  shared_examples 'reads every name' do
    it 'from the room players component' do
      receive_from_server("<component id='room players'>#{players_line}</component>")
      expect(label).to eq names
    end

    it 'from the inline "Also here:" line of a LOOK' do
      receive_from_server(*look(players_line))
      expect(label).to eq names
    end
  end

  context 'with a room window' do
    before { load_layout(main_window, room_window, indicator) }

    context 'when the players are linked' do
      let(:players_line) { players }

      it_behaves_like 'reads every name'
    end

    context 'when Lich strips the links' do
      let(:players_line) { strip_links(players) }

      it_behaves_like 'reads every name'
    end
  end

  context 'without a room window' do
    before { load_layout(main_window, indicator) }

    context 'when the players are linked' do
      let(:players_line) { players }

      it_behaves_like 'reads every name'
    end

    context 'when Lich strips the links' do
      let(:players_line) { strip_links(players) }

      it_behaves_like 'reads every name'
    end
  end

  context 'with linked players' do
    before { load_layout(main_window, indicator) }

    # The link names the player; its text is what the game shows.
    it "takes a player's name from the link's noun" do
      receive_from_server(%(<component id='room players'>Also here: Lord <a exist="-1" noun="Aldric">Aldric the Bold</a>.</component>))
      expect(label).to eq 'Aldric'
    end

    let(:corwin_and_ash) do
      "<component id='room players'>Also here: Corwinite #{link('Corwin', 1)} and #{link('Ash', 2)} " \
        'who is wrapped in ash.</component>'
    end

    # With links on, each name's link color lands on the name in the label,
    # not on a title or post string that shares its letters.
    it 'colors each name in the label at its own place while links are on' do
      state.blue_links = true
      receive_from_server(corwin_and_ash)
      expect(label).to eq 'Corwin, Ash'
      expect(indicator_updates.last[:label_colors].map { |c| [c[:start], c[:end]] }).to eq [[0, 6], [8, 11]]
    end

    # With links off (the default), the links name the players but show no
    # color, as in the main and room windows.
    it 'shows no link color while links are off' do
      receive_from_server(corwin_and_ash)
      expect(label).to eq 'Corwin, Ash'
      expect(indicator_updates.last[:label_colors]).to eq []
    end

    it 'still shows a highlight on a linked name while links are off' do
      allow(HighlightProcessor).to receive(:apply_highlights) do |text, colors|
        start = text.index('Ash')
        colors << { start: start, end: start + 3, fg: 'ff0000' }
      end
      receive_from_server(corwin_and_ash)
      expect(indicator_updates.last[:label_colors]).to eq [{ start: 8, end: 11, fg: 'ff0000', bg: nil, ul: nil }]
    end

    it 'clears the indicator when the room empties' do
      receive_from_server("<component id='room players'>#{players}</component>", "<component id='room players'></component>")
      expect(indicator_updates.last[:value]).to be false
    end
  end
end
