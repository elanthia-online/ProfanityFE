# frozen_string_literal: true

# Tests the experience window (ExpWindow) as a user sees it: the window is
# built from layout XML by WindowManager, draws onto the virtual screen
# (spec/support/virtual_screen.rb), and receives skill updates through
# GameTextProcessor as <component id='exp …'> lines.

require 'rexml/document'
require_relative '../../../lib/event_bus'
require_relative '../../../lib/game_text_processor'
require_relative '../../../lib/window_manager'
require_relative '../../../lib/windows/skill' # profanity.rb loads it; spec_helper doesn't

RSpec.describe ExpWindow do
  let(:window_manager) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='exp' top='0' left='0' height='8' width='40'/></layout>
    XML
    wm = WindowManager.new
    wm.load_layout('test')
    wm
  end
  let(:window) { window_manager.stream['exp'] }
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

  def visible_rows
    window.rows.map(&:rstrip).reject(&:empty?)
  end

  # One skill update as a component line. The text is in the
  # "Name: ranks percent%  [mindstate/34]" form ExpWindow parses.
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
end
