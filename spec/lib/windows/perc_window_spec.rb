# frozen_string_literal: true

# Tests the spell window (PercWindow) as a user sees it: the window is built
# from layout XML by WindowManager and draws onto the virtual screen
# (spec/support/virtual_screen.rb). The integration examples drive
# GameTextProcessor with spell blocks as DragonRealms sends them.

require 'rexml/document'
require_relative '../../../lib/event_bus'
require_relative '../../../lib/game_text_processor'
require_relative '../../../lib/window_manager'

RSpec.describe PercWindow do
  # A spell window 8 rows high and 20 columns wide. The builder keeps one
  # column back, so the window is 19 columns and text wraps at 18.
  let(:window_manager) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='percWindow' top='0' left='0' height='8' width='20' value='percWindow'/></layout>
    XML
    wm = WindowManager.new
    wm.load_layout('test')
    wm
  end
  let(:window) { window_manager.stream['percWindow'] }

  # Deliver one spell update the way WindowManager does: clearStream, then
  # each spell line.
  def receive_spells(*spells)
    window.clear_spells
    spells.each { |spell| window.add_string(spell) }
  end

  def visible_rows
    window.rows.reject(&:empty?)
  end

  describe 'wrapping' do
    it 'wraps a long spell under itself, with its continuation directly beneath' do
      receive_spells('Shadows (2 roisaen)', 'Manifest Force (12 roisaen)',
                     'Ethereal Shield (30 roisaen)', 'Aura Sight (40 roisaen)')

      expect(visible_rows).to eq ['Aura Sight (40', '  roisaen)',
                                  'Ethereal Shield', '  (30 roisaen)',
                                  'Manifest Force', '  (12 roisaen)',
                                  'Shadows (2', '  roisaen)']
    end

    it 'keeps identical continuation text for every spell that has it' do
      receive_spells('Aura Sight (40 roisaen)', 'Shadows (2 roisaen)')

      expect(visible_rows).to eq ['Aura Sight (40', '  roisaen)', 'Shadows (2', '  roisaen)']
    end

    it 'shows the first rows of the list when the spells do not all fit' do
      receive_spells('Ethereal Shield (30 roisaen)', 'Manifest Force (12 roisaen)',
                     'Aura Sight (40 roisaen)', 'Shadows (2 roisaen)', 'Clear Vision (1 roisaen)')

      expect(window.rows).to eq ['Aura Sight (40', '  roisaen)',
                                 'Ethereal Shield', '  (30 roisaen)',
                                 'Manifest Force', '  (12 roisaen)',
                                 'Shadows (2', '  roisaen)']
    end
  end

  describe 'batches' do
    it 'shows the current batch as soon as its lines arrive' do
      receive_spells('Bloodthorns (44)', 'Instinct (13)')

      expect(visible_rows).to eq ['Bloodthorns (44)', 'Instinct (13)']
    end

    it 'replaces the previous batch with the next one' do
      receive_spells('Bloodthorns (44)', 'Instinct (13)')
      receive_spells('Bloodthorns (43)')

      expect(visible_rows).to eq ['Bloodthorns (43)']
    end

    it 'is empty after a clear with no spells following' do
      receive_spells('Bloodthorns (44)')
      window.clear_spells

      expect(visible_rows).to be_empty
    end

    it 'shows a spell repeated within a batch once' do
      receive_spells('Instinct (13)', 'Instinct (13)')

      expect(visible_rows).to eq ['Instinct (13)']
    end

    it 'ignores blank lines' do
      receive_spells('Instinct (13)', '', '   ')

      expect(visible_rows).to eq ['Instinct (13)']
    end

    it 'exposes the displayed lines for selection' do
      receive_spells('Shadows (2 roisaen)', 'Instinct (13)')

      expect(window.buffer_content.map { |line, _colors, continuation| [line, continuation] })
        .to eq [['Instinct (13)', false], ['Shadows (2 ', false], ['  roisaen)', true]]
    end
  end

  describe 'redraw and resize' do
    it 'keeps the spells on redraw' do
      receive_spells('Bloodthorns (44)', 'Instinct (13)')
      window.redraw
      window.redraw

      expect(visible_rows).to eq ['Bloodthorns (44)', 'Instinct (13)']
    end

    it 'keeps the spells when the terminal is resized, rewrapping to the new width' do
      receive_spells('Aura Sight (40 roisaen)', 'Instinct (13)')

      # WindowManager#resize repositions the window to its full layout width
      # (20), so text now wraps at 19 columns.
      window_manager.resize(nil)

      expect(visible_rows).to eq ['Aura Sight (40', '  roisaen)', 'Instinct (13)']
    end

    it 'rewraps to a wider window on resize' do
      receive_spells('Aura Sight (40 roisaen)', 'Instinct (13)')
      window.resize(8, 30)
      window.redraw

      expect(visible_rows).to eq ['Aura Sight (40 roisaen)', 'Instinct (13)']
    end
  end

  describe 'sort order' do
    it 'sorts percentages, OM, Cyclic, plain durations, no duration, and Fading' do
      receive_spells('Fader (Fading)', 'Short (5)', 'Cyc (Cyclic)', 'Long (900)', 'Plain',
                     'Orb (OM)', 'Pct (80%)', 'Mid (1200)')

      expect(window.rows).to eq ['Pct (80%)', 'Orb (OM)', 'Cyc (Cyclic)', 'Mid (1200)',
                                 'Plain', 'Long (900)', 'Short (5)', 'Fader (Fading)']
    end

    it 'keeps arrival order for spells with equal weight' do
      receive_spells('Beta (10)', 'Alpha (10)', 'Gamma (10)')

      expect(visible_rows).to eq ['Beta (10)', 'Alpha (10)', 'Gamma (10)']
    end
  end

  # The spell block as a real DragonRealms session sends it, fed through
  # GameTextProcessor, EventBus, and WindowManager into the window.
  describe 'receiving a spell block from the server' do
    let(:event_bus) { EventBus.new.tap { |bus| window_manager.subscribe_to_events(bus) } }
    let(:state) do
      Struct.new(:need_prompt, :prompt_text, :skip_server_time_offset,
                 :room_title, :blue_links, :room_window_only, :server_time_offset,
                 :remote_url, :log_gags) do
        def update_terminal_title = nil
      end.new(false, '>', true, '', false, false, 0.0, false, false)
    end
    let(:processor) do
      GameTextProcessor.new(
        window_mgr: window_manager,
        shared_state: state,
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
      allow(Curses).to receive(:doupdate)
      allow(processor).to receive(:show_disconnect_message)
      allow(processor).to receive(:exit)
      processor.run(server)
    end

    def spell_block(*spells, closer: '<popStream/><prompt time="1790000000">&gt;</prompt>')
      ['<clearStream id="percWindow"/>',
       "<pushStream id=\"percWindow\"/>#{spells.first}",
       *spells[1..],
       closer]
    end

    before { CONFIG.perc_transforms.push([/ roisaen/, '']) }

    it 'shows the spells of a block once the block has been received' do
      receive_from_server(*spell_block('Senses of the Tiger  (30 roisaen)', 'Cheetah Swiftness  (Indefinite)',
                                       'River in the Sky  (33 roisaen)', 'Bloodthorns  (44 roisaen)',
                                       'Instinct  (13 roisaen)'))

      expect(visible_rows).to eq ['Bloodthorns (44)', 'RITS (33)', 'SOTT (30)', 'INST (13)', 'CS (Indefinite)']
    end

    it 'keeps long effects together with their wrapped durations' do
      receive_from_server(*spell_block('Heroic Strength Elixir  (12 roisaen)', 'Bloodthorns  (44 roisaen)',
                                       'Philosopher Stone Glow  (30 roisaen)'))

      expect(visible_rows).to eq ['Bloodthorns (44)', 'Philosopher Stone', '  Glow (30)',
                                  'Heroic Strength', '  Elixir (12)']
    end

    it 'shows each block when it arrives, not when the next one starts' do
      receive_from_server(*spell_block('Bloodthorns  (44 roisaen)', 'Instinct  (13 roisaen)'),
                          *spell_block('Bloodthorns  (43 roisaen)',
                                       closer: '<popStream/><castTime value="1790000003"/>'))

      expect(visible_rows).to eq ['Bloodthorns (43)']
    end

    # Spell lines are highlighted as the server sends them, then shortened
    # (perc-transforms, spell abbreviations, double spaces). A highlight
    # must end up on the text it matched, wherever that text now is.
    describe 'highlights on a shortened spell line' do
      let(:red) { Curses.color_pair(1) }

      before do
        allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| fg == 'ff0000' ? 1 : 0 }
      end

      # Columns of row +y+ drawn in the highlight color.
      def red_columns(y)
        (0...window.maxx).select { |x| window.attrs_at(y, x) == red }
      end

      it 'colors the abbreviation of a highlighted spell name, and nothing beyond it' do
        HIGHLIGHT[/Osrel Meraud|Persistence of Mana/] = ['ff0000', nil, nil]

        receive_from_server(*spell_block('Persistence of Mana  (OM)', 'Osrel Meraud  (96%)'))

        expect(visible_rows).to eq ['OM (96%)', 'POM (OM)']
        expect(red_columns(0)).to eq [0, 1]
        expect(red_columns(1)).to eq [0, 1, 2]
      end

      it 'moves a highlight left when a transform deletes text before it' do
        CONFIG.perc_transforms.push([/Khri /, ''])
        HIGHLIGHT[/Avoidance/] = ['ff0000', nil, nil]

        receive_from_server(*spell_block('Khri Avoidance  (31 roisaen)'))

        expect(visible_rows).to eq ['Avoidance (31)']
        expect(red_columns(0)).to eq (0...9).to_a
      end

      it 'moves a highlight left when the double space before it is collapsed' do
        HIGHLIGHT[/44/] = ['ff0000', nil, nil]

        receive_from_server(*spell_block('Bloodthorns  (44 roisaen)'))

        expect(visible_rows).to eq ['Bloodthorns (44)']
        expect(red_columns(0)).to eq [13, 14]
      end

      it 'still colors a highlight on the abbreviation itself' do
        HIGHLIGHT[/\bPOM\b/] = ['ff0000', nil, nil]

        receive_from_server(*spell_block('Persistence of Mana  (OM)'))

        expect(visible_rows).to eq ['POM (OM)']
        expect(red_columns(0)).to eq [0, 1, 2]
      end

      it 'still colors a highlight on text a transform produced' do
        CONFIG.perc_transforms.push([/Indefinite/, 'Cyclic'])
        HIGHLIGHT[/Cyclic/] = ['ff0000', nil, nil]

        receive_from_server(*spell_block('Cheetah Swiftness  (Indefinite)'))

        expect(visible_rows).to eq ['CS (Cyclic)']
        expect(red_columns(0)).to eq (4...10).to_a
      end

      it 'sends a highlight that matches before and after shortening only once' do
        HIGHLIGHT[/\(OM\)/] = ['ff0000', nil, nil]
        sent = []
        event_bus.on(:stream_text) { |data| sent << data[:colors] if data[:stream] == 'percWindow' }

        receive_from_server(*spell_block('Persistence of Mana  (OM)'))

        expect(red_columns(0)).to eq [4, 5, 6, 7]
        expect(sent).to eq [[{ start: 4, end: 8, fg: 'ff0000', bg: nil, ul: nil }]]
      end

      it 'leaves a line with no highlight uncolored' do
        HIGHLIGHT[/Osrel Meraud/] = ['ff0000', nil, nil]

        receive_from_server(*spell_block('Bloodthorns  (44 roisaen)'))

        expect(visible_rows).to eq ['Bloodthorns (44)']
        expect(red_columns(0)).to be_empty
      end
    end
  end
end
