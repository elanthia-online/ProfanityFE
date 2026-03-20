# frozen_string_literal: true

# Tests GameTextProcessor#handle_game_text event emissions: indicator
# updates (empty hands, nsys), stream routing (main, dedicated, fallback),
# prompt handling (emit/suppress after movement), stun detection, combat
# gag, and highlight application.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
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
  let(:state) do
    Struct.new(:need_prompt, :prompt_text, :skip_server_time_offset,
               :room_title, :blue_links, :room_window_only, :server_time_offset) do
      def update_terminal_title = nil
    end.new(false, '>', true, '', false, false, 0.0)
  end
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

  # Send text through handle_game_text via the private method
  def process(text)
    processor.send(:handle_game_text, text)
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

    it 'sets need_update after emitting empty hands events' do
      process('You glance down at your empty hands.')
      expect(processor.send(:instance_variable_get, :@need_update)).to be true
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
      processor.send(:instance_variable_set, :@current_stream, 'combat')
      events = []
      event_bus.on(:stream_text) { |data| events << data }

      process('A goblin swings at you.')

      expect(events.last).to include(stream: 'combat')
    end

    it 'falls back to main stream when no dedicated window exists for a known stream' do
      processor.send(:instance_variable_set, :@current_stream, 'thoughts')
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
      processor.send(:instance_variable_set, :@current_stream, 'combat')
      process('A goblin attacks!')
      processor.send(:instance_variable_set, :@current_stream, nil)

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
      processor.send(:instance_variable_set, :@last_was_movement, true)
      events = []
      event_bus.on(:add_prompt) { |data| events << data }

      process('Some text after walking.')

      expect(events).to be_empty
    end

    it 'detects movement text and sets last_was_movement flag' do
      process('You walk north.')
      expect(processor.send(:instance_variable_get, :@last_was_movement)).to be true
    end

    %w[run go swim climb crawl drag stride sneak stalk].each do |verb|
      it "detects '#{verb}' as a movement verb" do
        process("You #{verb} through the archway.")
        expect(processor.send(:instance_variable_get, :@last_was_movement)).to be true
      end
    end

    it 'does not detect non-movement verbs as movement' do
      process('You attack the goblin.')
      expect(processor.send(:instance_variable_get, :@last_was_movement)).to be false
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

  # ---- Standalone room component updates ----

  describe 'standalone room component updates (not full room entry)' do
    before do
      wm.room['room'] = main_window
    end

    def process_line(line)
      processor.send(:instance_variable_set, :@current_raw_line, line)
      processor.send(:process_line_tags, line)
    end

    it 'emits :room_players when a standalone players component arrives' do
      events = []
      event_bus.on(:room_players) { |data| events << data }

      process_line("<component id='room players'>Also here: Quilsilgas and Dark Summoner Vlachodimos.</component>")

      expect(events.last).to include(text: a_string_matching(/Quilsilgas/))
    end

    it 'emits :room_objects when a standalone objects component arrives' do
      events = []
      event_bus.on(:room_objects) { |data| events << data }

      process_line("<component id='room objs'>You also see <pushBold/>a goblin<popBold/> and a sword.</component>")

      expect(events.last).to include(text: a_string_matching(/goblin/))
    end

    it 'sets need_room_render for non-exit room components' do
      process_line("<component id='room players'>Also here: Mahtra.</component>")

      expect(processor.send(:instance_variable_get, :@need_room_render)).to be true
    end

    it 'sets need_update for room components' do
      process_line("<component id='room players'>Also here: Mahtra.</component>")

      expect(processor.send(:instance_variable_get, :@need_update)).to be true
    end

    it 'subscriber receives room_players event and calls update_players on window' do
      room_spy = Object.new
      def room_spy.calls = @calls ||= []
      def room_spy.update_title(t)  = calls << [:update_title, t]
      def room_spy.update_desc(t, **) = calls << [:update_desc, t]
      def room_spy.update_objects(t, **) = calls << [:update_objects, t]
      def room_spy.update_players(t, **) = calls << [:update_players, t]
      def room_spy.update_exits(t, **) = calls << [:update_exits, t]
      def room_spy.render = calls << [:render]
      def room_spy.clear_supplemental = calls << [:clear_supplemental]
      def room_spy.update_room_number(t) = calls << [:update_room_number, t]
      def room_spy.update_stringprocs(t) = calls << [:update_stringprocs, t]

      # Wire the spy through WindowManager subscription
      test_wm = WindowManager.new
      test_wm.instance_variable_set(:@room, { 'room' => room_spy })
      test_wm.instance_variable_set(:@stream, { 'main' => main_window })
      test_wm.subscribe_to_events(event_bus)

      # Re-create processor with this wm
      test_processor = GameTextProcessor.new(
        window_mgr: test_wm, shared_state: state,
        cmd_buffer: cmd_buffer, xml_escapes: xml_escapes, event_bus: event_bus
      )

      test_processor.send(:instance_variable_set, :@current_raw_line,
                          "<component id='room players'>Also here: Mahtra.</component>")
      test_processor.send(:process_line_tags,
                          "<component id='room players'>Also here: Mahtra.</component>")

      expect(room_spy.calls).to include([:update_players, a_string_matching(/Mahtra/)])
    end

    it 'emits :room_players with empty text when an empty players component arrives' do
      events = []
      event_bus.on(:room_players) { |data| events << data }

      process_line("<component id='room players'></component>")

      expect(events.last).to include(text: '')
    end

    it 'clears room players indicator when an empty players component arrives' do
      indicator_events = []
      event_bus.on(:indicator_update) { |data| indicator_events << data if data[:id] == 'room players' }

      process_line("<component id='room players'></component>")

      expect(indicator_events.last).to include(id: 'room players', value: false)
    end

    it 'sets need_room_render for empty room components' do
      process_line("<component id='room players'></component>")

      expect(processor.send(:instance_variable_get, :@need_room_render)).to be true
    end

    it 'room_render event triggers render on the room window' do
      room_spy = Object.new
      def room_spy.calls = @calls ||= []
      def room_spy.render = calls << [:render]

      test_wm = WindowManager.new
      test_wm.instance_variable_set(:@room, { 'room' => room_spy })
      test_wm.instance_variable_set(:@stream, { 'main' => main_window })
      test_wm.subscribe_to_events(event_bus)

      event_bus.emit(:room_render)

      expect(room_spy.calls).to include([:render])
    end
  end

  # ---- Room players indicator without RoomWindow ----

  describe 'room players indicator without a RoomWindow' do
    # No wm.room['room'] set -- the default wm has an empty room hash

    def process_line(line)
      processor.send(:instance_variable_set, :@current_raw_line, line)
      processor.send(:process_line_tags, line)
    end

    it 'updates indicator from room players component stream' do
      indicator_events = []
      event_bus.on(:indicator_update) { |data| indicator_events << data if data[:id] == 'room players' }

      process_line("<component id='room players'>Also here: Cithrin</component>")

      expect(indicator_events.last).to include(id: 'room players', label: 'Cithrin', value: true)
    end

    it 'clears indicator from empty room players component' do
      indicator_events = []
      event_bus.on(:indicator_update) { |data| indicator_events << data if data[:id] == 'room players' }

      process_line("<component id='room players'></component>")

      expect(indicator_events.last).to include(id: 'room players', value: false)
    end

    it 'maps highlight colors from full text to name positions' do
      HIGHLIGHT[/Cithrin/] = ['ff0000', nil, nil]

      indicator_events = []
      event_bus.on(:indicator_update) { |data| indicator_events << data if data[:id] == 'room players' }

      process_line("<component id='room players'>Also here: Cithrin</component>")

      colors = indicator_events.last[:label_colors]
      expect(colors).to include(a_hash_including(start: 0, end: 7, fg: 'ff0000'))
    ensure
      HIGHLIGHT.delete(/Cithrin/)
    end

    it 'maps highlight colors correctly for multiple names' do
      HIGHLIGHT[/Navesi/] = ['00ff00', nil, nil]

      indicator_events = []
      event_bus.on(:indicator_update) { |data| indicator_events << data if data[:id] == 'room players' }

      process_line("<component id='room players'>Also here: Cithrin and Navesi</component>")

      label = indicator_events.last[:label]
      colors = indicator_events.last[:label_colors]
      expect(label).to eq('Cithrin, Navesi')
      # "Navesi" starts at position 9 in "Cithrin, Navesi"
      expect(colors).to include(a_hash_including(start: 9, end: 15, fg: '00ff00'))
    ensure
      HIGHLIGHT.delete(/Navesi/)
    end

    it 'excludes partial highlight matches from indicator colors' do
      HIGHLIGHT[/ith/] = ['ff0000', nil, nil]

      indicator_events = []
      event_bus.on(:indicator_update) { |data| indicator_events << data if data[:id] == 'room players' }

      process_line("<component id='room players'>Also here: Cithrin</component>")

      colors = indicator_events.last[:label_colors]
      expect(colors).to be_empty
    ensure
      HIGHLIGHT.delete(/ith/)
    end
  end

  # ---- Stream fallback with preset colors ----

  describe 'stream fallback applies preset colors' do
    it 'applies preset color when falling back to main for a known stream' do
      PRESET['thoughts'] = ['00ff00', '000000']
      processor.send(:instance_variable_set, :@current_stream, 'thoughts')
      events = []
      event_bus.on(:stream_text) { |data| events << data }

      process('Someone thinks something.')

      colors = events.last[:colors]
      preset_color = colors.find { |c| c[:fg] == '00ff00' }
      expect(preset_color).not_to be_nil
    end
  end

  # ---- Structured room data from real game XML ----

  describe 'structured room data from SAX parsing' do
    before do
      wm.room['room'] = main_window
      PRESET['monsterbold'] = ['ff0000', nil]
    end

    def process_line(line)
      processor.send(:instance_variable_set, :@current_raw_line, line)
      processor.send(:process_line_tags, line)
    end

    describe 'room objs with monsterbold creature and links' do
      let(:raw_xml) do
        <<~'XML'.chomp
          <component id='room objs'>  You also see the <a exist="173594154" noun="disk">Pandin disk</a>, a <a exist="26164" noun="fissure">narrow fissure</a>, the <a exist="-2078" noun="Lodge">Wayside Lodge</a> and<b> <pushBold/>a <a exist="-477668" noun="assistant">dwarven blacksmith assistant</a><popBold/></b>.</component>
        XML
      end

      it 'emits clean text with no XML tags' do
        events = []
        event_bus.on(:room_objects) { |data| events << data }
        process_line(raw_xml)

        text = events.last[:text]
        expect(text).not_to include('<')
        expect(text).to include('You also see the Pandin disk')
        expect(text).to include('dwarven blacksmith assistant')
        expect(text).to include('Wayside Lodge')
      end

      it 'emits pre-computed link regions with correct positions' do
        events = []
        event_bus.on(:room_objects) { |data| events << data }
        process_line(raw_xml)

        text = events.last[:text]
        links = events.last[:links]

        expect(links.length).to be >= 3

        # Verify each link's position matches the actual text
        links.each do |link|
          linked_text = text[link[:start]...link[:end]]
          expect(linked_text).not_to be_nil
          expect(linked_text).not_to be_empty
          expect(link[:cmd]).to be_a(String)
        end

        # Check specific links
        pandin_link = links.find { |l| l[:cmd] == 'look #173594154' }
        expect(pandin_link).not_to be_nil
        expect(text[pandin_link[:start]...pandin_link[:end]]).to eq 'Pandin disk'

        lodge_link = links.find { |l| l[:cmd] == 'look #-2078' }
        expect(lodge_link).not_to be_nil
        expect(text[lodge_link[:start]...lodge_link[:end]]).to eq 'Wayside Lodge'

        assistant_link = links.find { |l| l[:cmd] == 'look #-477668' }
        expect(assistant_link).not_to be_nil
        expect(text[assistant_link[:start]...assistant_link[:end]]).to eq 'dwarven blacksmith assistant'
      end

      it 'emits creature names extracted from monsterbold regions' do
        events = []
        event_bus.on(:room_objects) { |data| events << data }
        process_line(raw_xml)

        creatures = events.last[:creatures]
        expect(creatures).to include(a_string_matching(/dwarven blacksmith assistant/))
      end

      it 'links remain correct even when blue_links is off' do
        state.blue_links = false
        events = []
        event_bus.on(:room_objects) { |data| events << data }
        process_line(raw_xml)

        text = events.last[:text]
        links = events.last[:links]

        # Links are always pre-computed for room components
        expect(links).not_to be_empty
        links.each do |link|
          expect(text[link[:start]...link[:end]]).not_to be_empty
        end
      end
    end

    describe 'room players with links' do
      let(:raw_xml) do
        <<~'XML'.chomp
          <component id='room players'>Also here: <a exist="-10987185" noun="Pandin">Pandin</a>, <a exist="-11184851" noun="Nexuspickbot">Nexuspickbot</a>, Grand Lord <a exist="-10995777" noun="Treeze">Treeze</a></component>
        XML
      end

      it 'emits clean text and link regions for player names' do
        events = []
        event_bus.on(:room_players) { |data| events << data }
        process_line(raw_xml)

        text = events.last[:text]
        links = events.last[:links]

        expect(text).to eq 'Also here: Pandin, Nexuspickbot, Grand Lord Treeze'
        expect(links.length).to eq 3

        pandin_link = links.find { |l| l[:cmd] == 'look #-10987185' }
        expect(text[pandin_link[:start]...pandin_link[:end]]).to eq 'Pandin'

        treeze_link = links.find { |l| l[:cmd] == 'look #-10995777' }
        expect(text[treeze_link[:start]...treeze_link[:end]]).to eq 'Treeze'
      end
    end

    describe 'empty room players component' do
      it 'emits empty text and empty links' do
        events = []
        event_bus.on(:room_players) { |data| events << data }
        process_line("<component id='room players'></component>")

        expect(events.last[:text]).to eq ''
        expect(events.last[:links]).to eq []
      end
    end

    describe 'room exits with direction links' do
      let(:raw_xml) do
        <<~'XML'.chomp
          <component id='room exits'>Obvious paths: <a exist="-11230837" coord="2524,1864" noun="out">out</a><compass><dir value="out"/></compass></component>
        XML
      end

      it 'emits clean exits text and link for direction' do
        events = []
        event_bus.on(:room_exits) { |data| events << data }
        process_line(raw_xml)

        text = events.last[:text]
        links = events.last[:links]

        # compass block is stripped by extract_links pre-strip
        expect(text).not_to include('compass')
        expect(text).to include('Obvious paths:')
        expect(text).to include('out')

        out_link = links.find { |l| l[:cmd] == 'look #-11230837' }
        expect(out_link).not_to be_nil
        expect(text[out_link[:start]...out_link[:end]]).to eq 'out'
      end
    end
  end
end
