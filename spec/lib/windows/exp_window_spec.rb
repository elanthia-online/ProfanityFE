# frozen_string_literal: true

# Tests the experience window (ExpWindow) as a user sees it: the window is
# built from layout XML by WindowManager, draws onto the virtual screen
# (spec/support/virtual_screen.rb), and receives skill updates through
# GameTextProcessor as <component id='exp …'> lines.

require 'rexml/document'
require_relative '../../../lib/event_bus'
require_relative '../../../lib/game_text_processor'
require_relative '../../../lib/shared_state'
require_relative '../../../lib/window_manager'

RSpec.describe ExpWindow do
  let(:window_manager) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='exp' top='0' left='0' height='8' width='50'/></layout>
    XML
    wm = WindowManager.new
    wm.load_layout('test')
    wm
  end
  let(:window) { window_manager.stream['exp'] }
  let(:event_bus) { EventBus.new.tap { |bus| window_manager.subscribe_to_events(bus) } }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
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

  def visible_rows
    window.rows.map(&:rstrip).reject(&:empty?)
  end

  # One skill update as a component line, wrapped in the whisper preset as
  # DragonRealms sends most of them.
  def skill_line(id, text)
    "<component id='exp #{id}'><preset id='whisper'>#{text}</preset></component>"
  end

  # Two skills that share the first word and the first letter of the second.
  let(:parry_ability) { skill_line('Parry Ability', '   Parry Ability: 1709 59%  [34/34]') }
  let(:parry_aptitude) { skill_line('Parry Aptitude', '  Parry Aptitude:  120 10%  [ 5/34]') }

  describe 'skills whose ids share a first word and the next letter' do
    it 'shows a row for each skill' do
      receive_from_server(parry_ability, parry_aptitude)

      expect(visible_rows).to eq ['Parry Ability: 1709 59% [34/34]',
                                  'Parry Aptitude:  120 10% [ 5/34]']
    end

    it 'removes only the skill whose component arrives empty' do
      receive_from_server(parry_ability, parry_aptitude, "<component id='exp Parry Ability'></component>")

      expect(visible_rows).to eq ['Parry Aptitude:  120 10% [ 5/34]']
    end
  end

  # Lines as DragonRealms sends them (copied from Lich XML session logs):
  # name padded to 16, ranks, percent, the mindstate word(s) padded to 13,
  # the learning rate, then trailing spaces.
  describe 'skill lines in the DragonRealms format' do
    let(:bow) { skill_line('Bow', '             Bow: 1534 07% deliberative  0.27 ') }
    let(:parry) { skill_line('Parry Ability', '   Parry Ability: 1709 59% mind lock     0.37    ') }
    let(:scholarship) do
      "<component id='exp Scholarship'><b>     Scholarship: 1750 00% nearly locked 0.22</b></component>"
    end
    let(:alchemy) { "<component id='exp Alchemy'>         Alchemy:  805 08% pondering     0.64    </component>" }

    it 'shows each skill with its ranks, percent, mindstate and rate as sent' do
      receive_from_server(bow, parry, scholarship, alchemy)

      expect(visible_rows).to eq [' Alchemy:  805 08% pondering     0.64',
                                  '     Bow: 1534 07% deliberative  0.27',
                                  'Parry Ability: 1709 59% mind lock     0.37',
                                  'Scholarship: 1750 00% nearly locked 0.22']
    end

    it 'replaces a skill when its next update arrives' do
      receive_from_server(bow, skill_line('Bow', '             Bow: 1534 08% examining     0.28    '))

      expect(visible_rows).to eq ['     Bow: 1534 08% examining     0.28']
    end

    it 'removes a skill whose component arrives empty' do
      receive_from_server(bow, parry, "<component id='exp Bow'></component>")

      expect(visible_rows).to eq ['Parry Ability: 1709 59% mind lock     0.37']
    end

    it 'shows the DragonRealms and [n/34] formats side by side' do
      receive_from_server(bow, parry_aptitude)

      expect(visible_rows).to eq ['     Bow: 1534 07% deliberative  0.27',
                                  'Parry Aptitude:  120 10% [ 5/34]']
    end

    # The exp stream also carries components that are not skills.
    it 'adds no row for the favor, TDP, rested-exp and sleep components' do
      receive_from_server(
        bow,
        "<component id='exp favor'>          Favors:  73</component>",
        "<component id='exp tdp'>            TDPs:  1705</component>",
        "<component id='exp rexp'>Rested EXP Stored: 1 hour  Usable This Cycle: 1 hour  " \
        'Cycle Refreshes: 12:18 hours</component>',
        "<component id='exp sleep'><b>You are relaxed and your mind has entered a state of rest.  " \
        'To wake up and start learning again, type: AWAKEN</b></component>',
        "<component id='exp sleep'></component>"
      )

      expect(visible_rows).to eq ['     Bow: 1534 07% deliberative  0.27']
    end
  end
end
