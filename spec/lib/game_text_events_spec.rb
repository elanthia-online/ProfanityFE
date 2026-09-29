# frozen_string_literal: true

# Tests GameTextProcessor#handle_game_text event emissions: indicator
# updates (empty hands, nsys), stream routing (main, dedicated, fallback),
# prompt handling (emit/suppress after movement), stun detection, combat
# gag, and highlight application. (Multi-line gags are in
# multiline_gags_spec.rb, room component lines in
# room_component_lines_spec.rb.)

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'GameTextProcessor event emissions' do
  before { GagPatterns.load_defaults }

  let(:main_window) do
    obj = Object.new
    def obj.route_string(*) = nil
    def obj.add_string(*) = nil
    def obj.respond_to?(m, *) = m == :buffer ? false : super
    obj
  end
  let(:event_bus) { EventBus.new }
  let(:wm) do
    Struct.new(:stream, :indicator, :progress, :countdown, :room,
               :command_window, :command_window_layout).new(
                 { 'main' => main_window }, {}, {}, {}, {}, nil, nil
               )
  end
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:cmd_buffer) { Struct.new(:window).new(nil) }
  let(:xml_escapes) { { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' } }
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: wm,
      shared_state: state,
      cmd_buffer: cmd_buffer,
      xml_escapes: xml_escapes,
      event_bus: event_bus
    )
  end

  # The processor's stream router
  def router = processor.send(:instance_variable_get, :@router)

  # The processor's prompt tracker
  def prompts = processor.send(:instance_variable_get, :@prompts)

  # The screen updates the processor asked for
  def pending_render = processor.send(:instance_variable_get, :@pending_render)

  # Send text through handle_game_text via the private method, with no
  # color runs
  def process(text)
    processor.send(:handle_game_text, text, [])
  end

  # ---- Empty hands indicator ----

  describe 'empty hands text emits indicator events' do
    it 'emits indicator_update for both right and left when glancing at empty hands' do
      events = []
      event_bus.on(:indicator_update) { |data| events << data }

      process('You glance down at your empty hands.')

      right_event = events.find { |e| e[:id] == 'right' }
      left_event = events.find { |e| e[:id] == 'left' }
      expect(right_event).to include(label: 'Empty')
      expect(left_event).to include(label: 'Empty')
    end

    it 'asks for a screen update after emitting empty hands events' do
      process('You glance down at your empty hands.')
      expect(pending_render.update_requested?).to be true
    end
  end

  # ---- Nerve system indicator ----

  describe 'nerve system text emits nsys indicator events' do
    it 'emits nsys value 3 for severe muscle control issues' do
      events = []
      event_bus.on(:indicator_update) { |data| events << data }

      process('You have a very difficult time with muscle control in your left arm.')

      nsys_event = events.find { |e| e[:id] == 'nsys' }
      expect(nsys_event).to include(value: 3)
    end

    it 'emits nsys value 2 for constant muscle spasms' do
      events = []
      event_bus.on(:indicator_update) { |data| events << data }

      process('You have constant muscle spasms in your right leg.')

      nsys_event = events.find { |e| e[:id] == 'nsys' }
      expect(nsys_event).to include(value: 2)
    end

    it 'emits nsys value 1 for slurred speech' do
      events = []
      event_bus.on(:indicator_update) { |data| events << data }

      process('You have developed slurred speech.')

      nsys_event = events.find { |e| e[:id] == 'nsys' }
      expect(nsys_event).to include(value: 1)
    end

    it 'does not emit nsys for unrelated text' do
      events = []
      event_bus.on(:indicator_update) { |data| events << data }

      process('You swing your sword at a goblin.')

      nsys_events = events.select { |e| e[:id] == 'nsys' }
      expect(nsys_events).to be_empty
    end
  end

  # ---- Stream text routing ----

  describe 'text routing emits stream_text events' do
    it 'emits stream_text to main stream for regular game text' do
      events = []
      event_bus.on(:stream_text) { |data| events << data }

      process('A goblin attacks you!')

      expect(events.last).to include(stream: 'main', text: 'A goblin attacks you!')
    end

    it 'emits stream_text to the current stream when a dedicated window exists' do
      wm.stream['combat'] = main_window
      router.send(:instance_variable_set, :@current_stream, 'combat')
      events = []
      event_bus.on(:stream_text) { |data| events << data }

      process('A goblin swings at you.')

      expect(events.last).to include(stream: 'combat')
    end

    it 'falls back to main stream when no dedicated window exists for a known stream' do
      router.send(:instance_variable_set, :@current_stream, 'thoughts')
      events = []
      event_bus.on(:stream_text) { |data| events << data }

      process('Someone thinks out loud.')

      expect(events.last).to include(stream: 'main')
    end

    it 'does not emit stream_text for whitespace-only text' do
      events = []
      event_bus.on(:stream_text) { |data| events << data }

      process('   ')

      expect(events).to be_empty
    end

    it 'skips duplicate text already sent to a stream window' do
      wm.stream['combat'] = main_window
      router.send(:instance_variable_set, :@current_stream, 'combat')
      process('A goblin attacks!')
      router.send(:instance_variable_set, :@current_stream, nil)

      events = []
      event_bus.on(:stream_text) { |data| events << data }
      process('A goblin attacks!')

      stream_texts = events.select { |e| e[:stream] == 'main' }
      expect(stream_texts).to be_empty
    end
  end

  # ---- Prompt emission ----

  describe 'prompt handling emits add_prompt events' do
    it 'emits add_prompt when need_prompt is true before regular text' do
      state.need_prompt = true
      events = []
      event_bus.on(:add_prompt) { |data| events << data }

      process('Hello world.')

      expect(events.last).to include(stream: 'main', text: '>')
    end

    it 'suppresses prompt after movement text' do
      state.need_prompt = true
      prompts.movement_seen
      events = []
      event_bus.on(:add_prompt) { |data| events << data }

      process('Some text after walking.')

      expect(events).to be_empty
    end

    it 'detects movement text and sets last_was_movement flag' do
      process('You walk north.')
      expect(prompts.send(:instance_variable_get, :@last_was_movement)).to be true
    end

    %w[run go swim climb crawl drag stride sneak stalk].each do |verb|
      it "detects '#{verb}' as a movement verb" do
        process("You #{verb} through the archway.")
        expect(prompts.send(:instance_variable_get, :@last_was_movement)).to be true
      end
    end

    it 'does not detect non-movement verbs as movement' do
      process('You attack the goblin.')
      expect(prompts.send(:instance_variable_get, :@last_was_movement)).to be false
    end
  end

  # ---- Stun detection ----

  describe 'stun text emits stun event' do
    it 'emits stun event with correct seconds for standard stun text' do
      events = []
      event_bus.on(:stun) { |data| events << data }

      process('You are stunned for 5 rounds!')

      expect(events.last).to include(seconds: 25)
    end

    it 'emits stun for multi-round stun' do
      events = []
      event_bus.on(:stun) { |data| events << data }

      process('  You are stunned for 12 rounds!')

      expect(events.last).to include(seconds: 60)
    end

    it 'emits stun for single round (1 round = 5 seconds)' do
      events = []
      event_bus.on(:stun) { |data| events << data }

      process('You are stunned for 1 round!')

      expect(events.last).to include(seconds: 5)
    end

    it 'does not emit stun for non-stun text containing "stunned"' do
      events = []
      event_bus.on(:stun) { |data| events << data }

      process('The goblin looks stunned.')

      expect(events).to be_empty
    end
  end

  # ---- Bracket prompt lines ----

  describe 'bracket prompt lines consume need_prompt' do
    it 'clears need_prompt on [prompt]> lines' do
      state.need_prompt = true
      process('[Cleric]>')
      expect(state.need_prompt).to be false
    end
  end

  # ---- Highlight application ----

  describe 'highlights are applied to routable streams' do
    it 'applies highlights and provides colors array with stream_text event' do
      events = []
      event_bus.on(:stream_text) { |data| events << data }

      process('Hello world.')

      expect(events.last[:colors]).to be_an(Array)
    end
  end

  # ---- Stream fallback with preset colors ----

  describe 'stream fallback applies preset colors' do
    it 'applies preset color when falling back to main for a known stream' do
      PRESET['thoughts'] = ['00ff00', '000000']
      router.send(:instance_variable_set, :@current_stream, 'thoughts')
      events = []
      event_bus.on(:stream_text) { |data| events << data }

      process('Someone thinks something.')

      colors = events.last[:colors]
      preset_color = colors.find { |c| c[:fg] == '00ff00' }
      expect(preset_color).not_to be_nil
    end
  end
end
