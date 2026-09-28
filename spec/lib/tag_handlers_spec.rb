# frozen_string_literal: true

# Tests TagHandlers module dispatch and individual tag handlers: prompt,
# spell, hand, roundtime, casttime, compass, progressBar, arbProgress,
# bold, preset, color, style, stream open/close, links, indicator, image,
# LaunchURL, streamWindow. Uses a minimal host class with event recording.

require_relative '../../lib/event_bus'
require_relative '../../lib/xml_tokenizer'
require_relative '../../lib/tag_handlers'
require_relative '../../lib/shared_state'

# Minimal host class that includes TagHandlers, providing the instance
# variables and helper methods the module expects.
class TagHandlerHost
  include TagHandlers

  attr_accessor :line_colors, :open_monsterbold, :open_preset, :open_style,
                :open_color, :open_link, :current_stream, :combat_next_line,
                :need_update, :need_room_render, :room_capture_mode

  attr_reader :flushed_texts, :wm, :state, :cmd_buffer, :event_bus, :stream_stack

  def initialize(wm:, state:, event_bus:)
    @wm = wm
    @state = state
    @event_bus = event_bus
    @cmd_buffer = Struct.new(:window).new(nil)
    @xml_escapes = { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' }
    @line_colors = []
    @open_monsterbold = []
    @open_preset = []
    @open_style = nil
    @open_color = []
    @open_link = []
    @current_stream = nil
    @stream_stack = []
    @combat_next_line = nil
    @need_update = false
    @need_room_render = false
    @room_capture_mode = nil
    @flushed_texts = []
  end

  # Capture flushed text instead of processing it
  def handle_game_text(text)
    @flushed_texts << { text: text.dup, colors: @line_colors.dup, stream: @current_stream }
    @line_colors = []
    @open_monsterbold.clear
    @open_preset.clear
    @open_color.clear
    @open_link.clear
  end

  # Stubs for methods defined in GameTextProcessor
  def parse_room_subtitle(subtitle)
    text = subtitle.sub(/^\s*-\s*/, '')
    text.sub(/^\[(.+?)\]/, '\1').strip
  end

  def new_stun(_seconds) = nil
end

# Mock window that records route_string / add_string calls
class SpyWindow
  attr_reader :calls

  def initialize
    @calls = []
  end

  def route_string(text, colors, stream, **_opts)
    @calls << { method: :route_string, text: text, colors: colors, stream: stream }
  end

  def add_string(text, colors = [])
    @calls << { method: :add_string, text: text, colors: colors }
  end
end

# Mock indicator with label and update tracking
class SpyIndicator
  attr_accessor :label, :label_colors, :active, :end_time, :secondary_end_time
  attr_reader :updates

  def initialize
    @label = nil
    @updates = []
  end

  def update(*args)
    @updates << args
    true
  end

  def value = 0
  def secondary_value = 0
  def layout = %w[1 10 0 0]
  def resize(*) = nil
  def move(*) = nil
end

RSpec.describe TagHandlers do
  let(:main_window) { SpyWindow.new }
  let(:event_bus) { EventBus.new }
  let(:wm) do
    Struct.new(:stream, :indicator, :progress, :countdown, :room,
               :command_window, :command_window_layout).new(
                 { 'main' => main_window }, {}, {}, {}, {}, nil, nil
               )
  end
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:host) { TagHandlerHost.new(wm: wm, state: state, event_bus: event_bus) }

  # Helper to collect events of a given type
  def collect_events(*types)
    events = []
    types.each do |type|
      event_bus.on(type) { |data| events << { type: type, **data } }
    end
    events
  end

  # ---- dispatch_tag ----

  describe '#dispatch_tag' do
    it 'dispatches to the correct handler based on tag name' do
      buf = String.new
      expect(host).to receive(:handle_push_bold).with('<pushBold/>', buf)
      host.dispatch_tag('<pushBold/>', buf)
    end

    it 'has a handler for every paired tag but inv, whose content is only swallowed' do
      expect(XmlTokenizer::PAIRED_TAGS - described_class::TAG_DISPATCH.keys).to eq ['inv']
    end

    it 'dispatches closing tags to CLOSING_TAG_DISPATCH' do
      buf = String.new
      expect(host).to receive(:handle_close_preset).with('</preset>', buf)
      host.dispatch_tag('</preset>', buf)
    end

    it 'resets combat_next_line on popStream combat tag' do
      host.combat_next_line = true
      host.dispatch_tag('<popStream id="combat" />', String.new)
      expect(host.combat_next_line).to be false
    end

    it 'activates combat stream on unrecognized tag when combat_next_line is true' do
      host.combat_next_line = true
      buf = +'some text'
      host.dispatch_tag('<unknownTag/>', buf)
      expect(host.current_stream).to eq 'combat'
    end

    it 'ignores dialogdata tags without activating combat' do
      host.combat_next_line = true
      host.dispatch_tag('<dialogdata id="foo"/>', String.new)
      expect(host.current_stream).to be_nil
    end
  end

  # ---- Bold handlers ----

  describe '#handle_push_bold / #handle_pop_bold' do
    it 'creates a color region for bold text' do
      PRESET['monsterbold'] = ['ff0000', nil]
      buf = +'Hello '
      host.dispatch_tag('<pushBold/>', buf)
      buf << 'goblin'
      host.dispatch_tag('<popBold/>', buf)

      expect(host.line_colors).to include(
        a_hash_including(start: 6, end: 12, fg: 'ff0000')
      )
    end

    it 'handles <b> and </b> tags the same way' do
      PRESET['monsterbold'] = ['ff0000', nil]
      buf = +''
      host.dispatch_tag('<b>', buf)
      buf << 'bold'
      host.dispatch_tag('</b>', buf)

      expect(host.line_colors).to include(
        a_hash_including(start: 0, end: 4, fg: 'ff0000')
      )
    end
  end

  # ---- Prompt handler ----

  describe '#handle_prompt_tag' do
    # SharedState#server_time_offset= also sets the $server_time_offset
    # global that countdown windows read; restore it for later examples.
    around do |example|
      saved_offset = $server_time_offset
      example.run
    ensure
      $server_time_offset = saved_offset
    end

    it 'updates shared state prompt_text' do
      state.skip_server_time_offset = false
      state.prompt_text = '>'
      host.dispatch_tag('<prompt time="1679000000">H&gt;</prompt>', String.new)
      expect(state.prompt_text).to eq 'H>'
    end

    it 'syncs server time offset on first prompt' do
      state.skip_server_time_offset = false
      host.dispatch_tag('<prompt time="1679000000">H&gt;</prompt>', String.new)
      expect(state.skip_server_time_offset).to be true
      expect(state.server_time_offset).to be_a(Float)
    end

    it 'sets need_prompt to true on repeated same prompt' do
      state.prompt_text = 'H>'
      host.dispatch_tag('<prompt time="1679000000">H&gt;</prompt>', String.new)
      expect(state.need_prompt).to be true
    end

    it 'emits :add_prompt and :prompt_changed events on new prompt' do
      events = collect_events(:add_prompt, :prompt_changed)
      state.prompt_text = '>'
      host.dispatch_tag('<prompt time="1679000000">H&gt;</prompt>', String.new)

      prompt_event = events.find { |e| e[:type] == :add_prompt }
      expect(prompt_event).to include(stream: 'main', text: 'H>')

      changed_event = events.find { |e| e[:type] == :prompt_changed }
      expect(changed_event).to include(text: 'H>')
    end

    it 'emits nothing and leaves the prompt pending on a repeated prompt' do
      state.prompt_text = 'H>'
      events = collect_events(:add_prompt, :prompt_changed)
      host.dispatch_tag('<prompt time="1679000000">H&gt;</prompt>', String.new)
      expect(events).to be_empty
      expect(state.consume_prompt!).to be true
    end

    it 'puts a new prompt in the terminal title' do
      allow(Process).to receive(:setproctitle)
      allow($stdout).to receive(:write)
      state.char_name = 'Mahtra'
      host.dispatch_tag('<prompt time="1679000000">H&gt;</prompt>', String.new)
      state.update_terminal_title
      expect(Process).to have_received(:setproctitle).with('Mahtra [H]')
    end
  end

  # ---- Spell handler ----

  describe '#handle_spell_tag' do
    it 'emits indicator_update for spell' do
      events = collect_events(:indicator_update)
      host.dispatch_tag('<spell>Fire Ball</spell>', String.new)
      expect(events.last).to include(id: 'spell', label: 'Fire Ball', value: 1)
    end

    it 'emits value 0 when spell is None' do
      events = collect_events(:indicator_update)
      host.dispatch_tag('<spell>None</spell>', String.new)
      expect(events.last).to include(id: 'spell', value: 0)
    end
  end

  # ---- Hand handler ----

  describe '#handle_hand_tag' do
    it 'emits indicator_update for right hand' do
      events = collect_events(:indicator_update)
      host.dispatch_tag('<right>a steel sword</right>', String.new)
      expect(events.last).to include(id: 'right', label: 'a steel sword', value: 1)
    end

    it 'emits value 0 for Empty hand' do
      events = collect_events(:indicator_update)
      host.dispatch_tag('<left>Empty</left>', String.new)
      expect(events.last).to include(id: 'left', label: 'Empty', value: 0)
    end
  end

  # ---- Compass handler ----

  describe '#handle_compass_tag' do
    it 'emits compass_update with active directions' do
      events = collect_events(:compass_update)
      host.dispatch_tag('<compass><dir value="n"/><dir value="e"/></compass>', String.new)
      expect(events.last[:dirs]).to contain_exactly('n', 'e')
    end
  end

  # ---- Roundtime/Casttime handlers ----

  describe '#handle_roundtime_tag' do
    it 'emits countdown_update with end_time' do
      events = collect_events(:countdown_update)
      host.dispatch_tag("<roundTime value='1679000010'/>", String.new)
      expect(events.last).to include(id: 'roundtime', end_time: 1_679_000_010)
    end
  end

  describe '#handle_casttime_tag' do
    it 'emits countdown_update with secondary_end_time' do
      events = collect_events(:countdown_update)
      host.dispatch_tag("<castTime value='1679000020'/>", String.new)
      expect(events.last).to include(id: 'roundtime', secondary_end_time: 1_679_000_020)
    end
  end

  # ---- Stream handlers ----

  describe '#handle_stream_open' do
    it 'flushes text buffer and sets current_stream' do
      buf = +'text before stream'
      host.dispatch_tag('<pushStream id="combat" />', buf)

      expect(host.flushed_texts.last[:text]).to eq 'text before stream'
      expect(host.current_stream).to eq 'combat'
      expect(buf).to eq ''
    end

    it 'sets combat_next_line for combat streams' do
      host.dispatch_tag('<pushStream id="combat" />', String.new)
      expect(host.combat_next_line).to be true
    end

    it 'handles exp stream with skill name' do
      events = collect_events(:exp_set_current)
      host.dispatch_tag('<pushStream id="exp Athletics" />', String.new)
      expect(host.current_stream).to eq 'exp'
      expect(events.last).to include(skill: 'Athletics')
    end

    it 'emits room_title for room stream with subtitle' do
      events = collect_events(:room_title)
      host.dispatch_tag(%q{<component id="room" subtitle=" - [Town Square]">}, String.new)
      expect(events.last).to include(text: 'Town Square')
      expect(state.room_title).to eq 'Town Square'
    end
  end

  describe '#handle_stream_close' do
    it 'flushes text buffer and clears current_stream' do
      host.current_stream = 'combat'
      buf = +'combat text'
      host.dispatch_tag('<popStream id="combat" />', buf)

      expect(host.flushed_texts.last[:text]).to eq 'combat text'
      expect(host.current_stream).to be_nil
    end

    it 'emits exp_delete_skill when closing exp stream' do
      events = collect_events(:exp_delete_skill)
      host.current_stream = 'exp'
      host.dispatch_tag('<popStream/>', String.new)
      expect(events.length).to eq 1
    end
  end

  # ---- Color handlers ----

  describe '#handle_open_color / #handle_close_color' do
    it 'creates a color region with fg and bg' do
      buf = +''
      host.dispatch_tag('<color fg="ff0000" bg="000000">', buf)
      buf << 'red on black'
      host.dispatch_tag('</color>', buf)

      expect(host.line_colors).to include(
        a_hash_including(start: 0, end: 12, fg: 'ff0000', bg: '000000')
      )
    end

    it 'handles underline attribute' do
      buf = +''
      host.dispatch_tag('<color ul="true">', buf)
      buf << 'underlined'
      host.dispatch_tag('</color>', buf)

      expect(host.line_colors).to include(
        a_hash_including(ul: 'true')
      )
    end
  end

  # ---- Preset handlers ----

  describe '#handle_open_preset / #handle_close_preset' do
    it 'creates a color region from the preset lookup' do
      PRESET['speech'] = ['00ff00', '000000']
      buf = +''
      host.dispatch_tag('<preset id="speech">', buf)
      buf << 'Someone says hello'
      host.dispatch_tag('</preset>', buf)

      expect(host.line_colors).to include(
        a_hash_including(start: 0, end: 18, fg: '00ff00', bg: '000000')
      )
    end

    it 'flushes text buffer when entering roomDesc preset' do
      wm.room['room'] = SpyWindow.new
      buf = +'text before desc'
      host.dispatch_tag('<preset id="roomDesc">', buf)

      expect(host.flushed_texts.last[:text]).to eq 'text before desc'
      expect(host.room_capture_mode).to eq :desc
    end
  end

  # ---- Style handler ----

  describe '#handle_style_tag' do
    it 'opens a style with non-empty id' do
      PRESET['roomName'] = ['00ff00', nil]
      host.dispatch_tag('<style id="roomName"/>', String.new)
      expect(host.open_style).to include(start: 0, fg: '00ff00')
      expect(host.room_capture_mode).to eq :title
    end

    it 'closes a style with empty id and flushes when in room capture' do
      PRESET['roomName'] = ['00ff00', nil]
      buf = +''
      host.dispatch_tag('<style id="roomName"/>', buf)
      buf << 'Town Square'
      host.dispatch_tag('<style id=""/>', buf)

      expect(host.open_style).to be_nil
      flushed = host.flushed_texts.find { |f| f[:text] == 'Town Square' }
      expect(flushed).not_to be_nil
    end
  end

  # ---- Link handlers ----

  describe '#handle_open_link / #handle_close_link' do
    before { state.blue_links = true }

    it 'creates a link color region with cmd from attribute' do
      buf = +'Go through '
      host.dispatch_tag("<d cmd='go door'>", buf)
      buf << 'the door'
      host.dispatch_tag('</d>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      expect(link).to include(start: 11, end: 19, cmd: 'go door')
    end

    it 'uses link text as cmd when no cmd attribute' do
      buf = +'Exit: '
      host.dispatch_tag('<d>', buf)
      buf << 'north'
      host.dispatch_tag('</d>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      expect(link[:cmd]).to eq 'north'
    end

    it 'handles GS <a> tags with exist/noun attributes' do
      buf = +''
      host.dispatch_tag('<a exist="12345" noun="sword">', buf)
      buf << 'a sword'
      host.dispatch_tag('</a>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      expect(link[:cmd]).to eq 'look #12345'
    end

    it 'does nothing when blue_links is false' do
      state.blue_links = false
      buf = +''
      host.dispatch_tag("<d cmd='go'>", buf)
      buf << 'door'
      host.dispatch_tag('</d>', buf)

      expect(host.line_colors).to be_empty
    end
  end

  # ---- Indicator handler ----

  describe '#handle_indicator_tag' do
    it 'emits indicator_update for visible icon' do
      events = collect_events(:indicator_update)
      host.dispatch_tag("<indicator id='IconSTUNNED' visible='y'/>", String.new)
      expect(events).to include(a_hash_including(id: 'stunned', value: true))
    end

    it 'emits countdown_active event' do
      events = collect_events(:countdown_active)
      host.dispatch_tag("<indicator id='IconSTUNNED' visible='y'/>", String.new)
      expect(events.last).to include(id: 'stunned', active: true)
    end
  end

  # ---- Image handler ----

  describe '#handle_image_tag' do
    it 'emits indicator_update for nsys with rank' do
      events = collect_events(:indicator_update)
      host.dispatch_tag("<image id='nsys' name='nsys3'/>", String.new)
      expect(events.last).to include(id: 'nsys', value: 3)
    end

    it 'emits indicator_update for body part injury' do
      events = collect_events(:indicator_update)
      host.dispatch_tag("<image id='chest' name='Injury2'/>", String.new)
      expect(events.last).to include(id: 'chest', value: 2)
    end
  end

  # ---- Launch URL handler ----

  describe '#handle_launch_url' do
    it 'emits launch_url event' do
      events = collect_events(:launch_url)
      host.dispatch_tag('<LaunchURL src="/path/to/page"/>', String.new)
      expect(events.last).to include(url: 'https://www.play.net/path/to/page')
    end

    it 'ignores a src that turns play.net into userinfo for another host' do
      events = collect_events(:launch_url)
      host.dispatch_tag('<LaunchURL src="@evil.example/x"/>', String.new)
      expect(events).to be_empty
    end

    it 'ignores a src that extends the play.net host name' do
      events = collect_events(:launch_url)
      host.dispatch_tag('<LaunchURL src=".evil.example/x"/>', String.new)
      expect(events).to be_empty
    end
  end

  # ---- Stream window handler ----

  describe '#handle_stream_window' do
    it 'updates room title from subtitle attribute' do
      events = collect_events(:indicator_update, :room_title)
      host.dispatch_tag(%q{<streamWindow id='room' subtitle=" - [Town Square]"/>}, String.new)

      expect(state.room_title).to eq 'Town Square'
      expect(events).to include(a_hash_including(type: :room_title, text: 'Town Square'))
      expect(events).to include(a_hash_including(type: :indicator_update, id: 'room', label: 'Town Square'))
    end

    it 'handles DR subtitle with room number' do
      host.dispatch_tag(%q{<streamWindow id='room' subtitle=" - [Bosque Deriel] (230008)"/>}, String.new)
      expect(state.room_title).to eq 'Bosque Deriel (230008)'
    end
  end

  # ---- Clear stream handler ----

  describe '#handle_clear_stream' do
    it 'emits clear_spells for percWindow' do
      events = collect_events(:clear_spells)
      host.dispatch_tag('<clearStream id="percWindow"/>', String.new)
      expect(events.length).to eq 1
    end

    it 'does not emit for non-percWindow' do
      events = collect_events(:clear_spells)
      host.dispatch_tag('<clearStream id="other"/>', String.new)
      expect(events).to be_empty
    end
  end

  # ---- Entity unescaping ----

  describe '#unescape_entities' do
    it 'converts &lt; to <' do
      expect(host.send(:unescape_entities, '&lt;')).to eq '<'
    end

    it 'converts &gt; to >' do
      expect(host.send(:unescape_entities, '&gt;')).to eq '>'
    end

    it 'converts &amp; to &' do
      expect(host.send(:unescape_entities, '&amp;')).to eq '&'
    end

    it 'converts &quot; to "' do
      expect(host.send(:unescape_entities, '&quot;')).to eq '"'
    end

    it 'handles multiple entities in one string' do
      expect(host.send(:unescape_entities, '&lt;tag&gt; &amp; more')).to eq '<tag> & more'
    end

    it 'returns unchanged text when no entities present' do
      expect(host.send(:unescape_entities, 'plain text')).to eq 'plain text'
    end

    it 'handles empty string' do
      expect(host.send(:unescape_entities, '')).to eq ''
    end

    it 'handles &amp;amp; (double-encoded) — only decodes one layer' do
      expect(host.send(:unescape_entities, '&amp;amp;')).to eq '&amp;'
    end

    it 'handles entity at start of string' do
      expect(host.send(:unescape_entities, '&lt;start')).to eq '<start'
    end

    it 'handles entity at end of string' do
      expect(host.send(:unescape_entities, 'end&gt;')).to eq 'end>'
    end

    it 'handles adjacent entities' do
      expect(host.send(:unescape_entities, '&lt;&gt;')).to eq '<>'
    end
  end

  # ==================================================================
  # Adversarial edge cases
  # ==================================================================

  describe 'adversarial: unmatched tags' do
    it 'popBold without pushBold does not crash' do
      expect { host.dispatch_tag('<popBold/>', String.new) }.not_to raise_error
      expect(host.line_colors).to be_empty
    end

    it '</preset> without <preset> does not crash' do
      expect { host.dispatch_tag('</preset>', String.new) }.not_to raise_error
    end

    it '</color> without <color> does not crash' do
      expect { host.dispatch_tag('</color>', String.new) }.not_to raise_error
    end

    it '</d> without <d> does not crash' do
      state.blue_links = true
      expect { host.dispatch_tag('</d>', String.new) }.not_to raise_error
    end

    it '</a> without <a> does not crash' do
      state.blue_links = true
      expect { host.dispatch_tag('</a>', String.new) }.not_to raise_error
    end

    it 'popStream without pushStream does not crash' do
      expect { host.dispatch_tag('<popStream id="combat" />', String.new) }.not_to raise_error
      expect(host.current_stream).to be_nil
    end
  end

  describe 'adversarial: nested tags' do
    it 'nested pushBold tags create stacked color regions' do
      PRESET['monsterbold'] = ['ff0000', nil]
      buf = +''
      host.dispatch_tag('<pushBold/>', buf)
      buf << 'outer '
      host.dispatch_tag('<pushBold/>', buf)
      buf << 'inner'
      host.dispatch_tag('<popBold/>', buf)
      buf << ' outer'
      host.dispatch_tag('<popBold/>', buf)

      # Should have two color regions, inner one is 6..11
      expect(host.line_colors.length).to eq 2
    end

    it 'nested presets stack correctly' do
      PRESET['speech'] = ['00ff00', nil]
      PRESET['roomDesc'] = ['0000ff', nil]
      buf = +''
      host.dispatch_tag('<preset id="speech">', buf)
      buf << 'outer '
      host.dispatch_tag('<preset id="speech">', buf)
      buf << 'inner'
      host.dispatch_tag('</preset>', buf)
      host.dispatch_tag('</preset>', buf)

      # Two color regions
      expect(host.line_colors.length).to eq 2
    end
  end

  describe 'adversarial: malformed tag attributes' do
    it 'prompt without time attribute does not crash' do
      expect { host.dispatch_tag('<prompt>H&gt;</prompt>', String.new) }.not_to raise_error
    end

    it 'spell with empty content' do
      events = collect_events(:indicator_update)
      host.dispatch_tag('<spell></spell>', String.new)
      expect(events.last).to include(id: 'spell', label: '')
    end

    it 'preset with unknown id does not crash' do
      expect { host.dispatch_tag('<preset id="nonexistent">', String.new) }.not_to raise_error
    end

    it 'progressBar with missing value attribute does not crash' do
      expect { host.dispatch_tag('<progressBar id="health"/>', String.new) }.not_to raise_error
    end

    it 'style with no id attribute does not crash' do
      expect { host.dispatch_tag('<style/>', String.new) }.not_to raise_error
    end

    it 'streamWindow for non-room id is ignored' do
      host.dispatch_tag(%q{<streamWindow id='main' subtitle="test"/>}, String.new)
      expect(state.room_title).to eq ''
    end

    it 'indicator with malformed id does not crash' do
      expect { host.dispatch_tag("<indicator id='BadFormat' visible='y'/>", String.new) }.not_to raise_error
    end

    it 'image with unknown body part does not crash' do
      expect { host.dispatch_tag("<image id='unknown' name='test'/>", String.new) }.not_to raise_error
    end
  end

  describe 'adversarial: color position tracking' do
    it 'bold region with zero-length text has start == end' do
      PRESET['monsterbold'] = ['ff0000', nil]
      buf = +''
      host.dispatch_tag('<pushBold/>', buf)
      host.dispatch_tag('<popBold/>', buf)
      expect(host.line_colors).to contain_exactly(a_hash_including(start: 0, end: 0, fg: 'ff0000'))
    end

    it 'color region positions are correct after entity unescaping in text' do
      PRESET['monsterbold'] = ['ff0000', nil]
      buf = +''
      host.dispatch_tag('<pushBold/>', buf)
      buf << host.send(:unescape_entities, 'a&lt;b')
      host.dispatch_tag('<popBold/>', buf)

      region = host.line_colors.find { |c| c[:fg] == 'ff0000' }
      expect(region[:start]).to eq 0
      expect(region[:end]).to eq 3 # "a<b" is 3 chars after unescape
    end

    it 'multiple color regions do not overlap incorrectly' do
      buf = +''
      host.dispatch_tag('<color fg="ff0000">', buf)
      buf << 'red'
      host.dispatch_tag('</color>', buf)
      host.dispatch_tag('<color fg="00ff00">', buf)
      buf << 'green'
      host.dispatch_tag('</color>', buf)

      red = host.line_colors.find { |c| c[:fg] == 'ff0000' }
      green = host.line_colors.find { |c| c[:fg] == '00ff00' }
      expect(red[:end]).to be <= green[:start]
    end
  end

  describe 'adversarial: stream handling' do
    it 'stream open without id attribute does not crash' do
      expect { host.dispatch_tag('<pushStream/>', String.new) }.not_to raise_error
      expect(host.current_stream).to be_nil
    end

    it 'component without id attribute does not crash' do
      expect { host.dispatch_tag('<component/>', String.new) }.not_to raise_error
    end

    it 'multiple stream opens without close accumulate correctly' do
      host.dispatch_tag('<pushStream id="combat" />', String.new)
      expect(host.current_stream).to eq 'combat'
      host.dispatch_tag('<pushStream id="thoughts" />', String.new)
      expect(host.current_stream).to eq 'thoughts'
    end

    it 'returns to the outer stream when a nested stream closes' do
      host.dispatch_tag('<pushStream id="thoughts" />', String.new)
      host.dispatch_tag('<pushStream id="familiar" />', String.new)
      host.dispatch_tag('<popStream/>', String.new)
      expect(host.current_stream).to eq 'thoughts'
    end

    it 'clearStream for non-percWindow id does not crash' do
      expect { host.dispatch_tag('<clearStream id="other"/>', String.new) }.not_to raise_error
    end
  end

  # Only pushStream/popStream nest; a <prompt> closes anything left open.
  describe 'nested streams' do
    def receive_tags(*tags)
      tags.each { |tag| host.dispatch_tag(tag, String.new) }
    end

    # Text collected before +tag+, and the stream it was flushed to.
    def flush_before(tag, text)
      host.dispatch_tag(tag, +text)
      host.flushed_texts.last.values_at(:text, :stream)
    end

    let(:prompt) { '<prompt time="1787778964">&gt;</prompt>' }

    it 'sends the outer stream the text that follows a nested push and pop' do
      receive_tags('<pushStream id="combat" />', '<pushStream id="moonWindow"/>', '<popStream/>')

      expect(flush_before('<popStream id="combat" />', 'The moradu staggers.')).to eq ['The moradu staggers.', 'combat']
      expect(host.current_stream).to be_nil
    end

    it 'unwinds three levels one bare pop at a time' do
      receive_tags('<pushStream id="thoughts"/>', '<pushStream id="familiar"/>', '<pushStream id="moonWindow"/>')

      streams = 3.times.map do
        host.dispatch_tag('<popStream/>', String.new)
        host.current_stream
      end
      expect(streams).to eq ['familiar', 'thoughts', nil]
    end

    it 'closes the named stream and anything opened after it on popStream id=' do
      receive_tags('<pushStream id="thoughts"/>', '<pushStream id="combat" />', '<pushStream id="moonWindow"/>')

      host.dispatch_tag('<popStream id="combat" />', String.new)

      expect(host.current_stream).to eq 'thoughts'
      expect(host.stream_stack).to eq ['thoughts']
    end

    it 'closes the innermost stream with that id when the id is open twice' do
      receive_tags('<pushStream id="familiar" />', '<pushStream id="thoughts"/>', '<pushStream id="familiar" />')

      host.dispatch_tag('<popStream id="familiar"/>', String.new)

      expect(host.current_stream).to eq 'thoughts'
    end

    it 'closes one level when popStream names a stream that is not open' do
      receive_tags('<pushStream id="thoughts"/>', '<pushStream id="familiar"/>')

      host.dispatch_tag('<popStream id="combat" />', String.new)

      expect(host.current_stream).to eq 'thoughts'
    end

    it 'stays on main when a pop arrives with nothing open' do
      receive_tags('<popStream id="combat" />', '<popStream/>')

      expect(host.current_stream).to be_nil
      expect(host.stream_stack).to be_empty
    end

    it 'handles the empath-touch double familiar push and double pop from a real log' do
      receive_tags('<pushStream id="familiar" />', '<pushStream id="familiar" ifClosedStyle="watching"/>')
      expect(host.current_stream).to eq 'familiar'

      host.dispatch_tag('<popStream/>', String.new)
      expect(host.current_stream).to eq 'familiar'
      host.dispatch_tag('<popStream/>', String.new)
      expect(host.current_stream).to be_nil
      expect(host.stream_stack).to be_empty
    end

    context 'with components' do
      it 'returns to the enclosing pushStream when a component closes inside it' do
        receive_tags('<pushStream id="familiar"/>', "<component id='room players'>")

        expect(flush_before('</component>', 'Also here: Fidon.')).to eq ['Also here: Fidon.', 'room players']
        expect(host.current_stream).to eq 'familiar'
      end

      it 'leaves the stack alone for a component pair' do
        receive_tags('<pushStream id="thoughts"/>', "<component id='room objs'>", '</component>', '<popStream/>')

        expect(host.current_stream).to be_nil
        expect(host.stream_stack).to be_empty
      end

      it 'pushes nothing for a self-closing component that a later pop could restore' do
        receive_tags("<component id='x'/>", '<pushStream id="thoughts"/>', '<popStream/>')

        expect(host.current_stream).to be_nil
        expect(host.stream_stack).to be_empty
      end

      it 'pushes nothing for a compDef pair' do
        receive_tags('<pushStream id="thoughts"/>', "<compDef id='exp Bow'>", '</compDef>')

        expect(host.stream_stack).to eq ['thoughts']
        expect(host.current_stream).to eq 'thoughts'
      end
    end

    context 'at a <prompt>' do
      it 'sends text to main after a push that never got its pop' do
        receive_tags('<pushStream id="moonWindow"/>', prompt)

        expect(host.current_stream).to be_nil
        expect(host.stream_stack).to be_empty
        expect(flush_before('<popStream/>', 'You sense nothing wrong with Fidon.')).to eq ['You sense nothing wrong with Fidon.', nil]
      end

      it 'flushes text collected for the stale stream to that stream first' do
        host.dispatch_tag('<pushStream id="moonWindow"/>', String.new)

        expect(flush_before(prompt, 'Katamba is rising.')).to eq ['Katamba is rising.', 'moonWindow']
      end

      it 'sends text to main after a self-closing component' do
        receive_tags("<component id='x'/>", prompt)

        expect(host.current_stream).to be_nil
      end

      it 'clears a combat flag left by an unclosed combat push' do
        receive_tags('<pushStream id="combat" />', prompt, '<unknownTag/>')

        expect(host.combat_next_line).to be false
        expect(host.current_stream).to be_nil
      end

      it 'changes nothing and flushes nothing when no stream is open' do
        buf = +'text before the prompt'
        host.dispatch_tag(prompt, buf)

        expect(buf).to eq 'text before the prompt'
        expect(host.flushed_texts).to be_empty
      end

      it 'does not stop a later push and pop from nesting' do
        receive_tags('<pushStream id="moonWindow"/>', prompt, '<pushStream id="thoughts"/>',
                     '<pushStream id="familiar"/>', '<popStream/>')

        expect(host.current_stream).to eq 'thoughts'
        expect(host.stream_stack).to eq ['thoughts']
      end
    end

    it 'keeps only the 8 most recent unmatched pushes' do
      ids = (1..11).map { |n| "s#{n}" }
      receive_tags(*ids.map { |id| %(<pushStream id="#{id}"/>) })

      expect(host.stream_stack).to eq ids.last(8)
      8.times { host.dispatch_tag('<popStream/>', String.new) }
      expect(host.current_stream).to be_nil
    end
  end

  describe 'adversarial: combat_next_line edge cases' do
    it 'combat_next_line with empty text buffer does not flush' do
      host.combat_next_line = true
      host.dispatch_tag('<unknownTag/>', String.new)
      expect(host.current_stream).to eq 'combat'
      expect(host.flushed_texts).to be_empty
    end

    it 'popStream combat resets flag even when current_stream is different' do
      host.combat_next_line = true
      host.current_stream = 'thoughts'
      host.dispatch_tag('<popStream id="combat" />', String.new)
      expect(host.combat_next_line).to be false
      expect(host.current_stream).to be_nil
    end
  end

  describe 'adversarial: link edge cases' do
    before { state.blue_links = true }

    it 'creates no link for a link with no text' do
      buf = +''
      host.dispatch_tag('<d>', buf)
      host.dispatch_tag('</d>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      expect(link).to be_nil
    end

    it 'GS link with exist but no noun uses _drag prefix' do
      buf = +''
      host.dispatch_tag('<a exist="99999">', buf)
      buf << 'an item'
      host.dispatch_tag('</a>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      expect(link[:cmd]).to eq '_drag #99999'
    end

    it 'link cmd with special characters is preserved verbatim' do
      buf = +''
      host.dispatch_tag("<d cmd='go #12345 door'>", buf)
      buf << 'the door'
      host.dispatch_tag('</d>', buf)

      link = host.line_colors.find { |c| c[:cmd] }
      expect(link[:cmd]).to eq 'go #12345 door'
    end
  end

  # Which spellings of each tag a handler accepts: quote style, attribute
  # order, spacing, attribute names that merely contain the one read, extra
  # attributes. Each row is what the handler does with that exact tag.
  describe 'attribute acceptance' do
    # @param tags [Hash{String => Object}] tag => expected result
    # @yieldparam host [TagHandlerHost] a fresh host for each tag
    # @yieldparam tag [String] the tag to dispatch
    # @yieldreturn [Object] what the handler did
    def expect_each(tags)
      tags.each do |tag, expected|
        fresh = TagHandlerHost.new(wm: wm, state: SharedState.new.tap { |s| s.skip_server_time_offset = true }, event_bus: EventBus.new)
        actual = yield(fresh, tag)
        expect(actual).to eq(expected), "#{tag} gave #{actual.inspect}, expected #{expected.inspect}"
      end
    end

    # @return [Array<Hash>] every event of +type+ emitted while dispatching +tag+
    def events_of(host, tag, type)
      events = []
      host.event_bus.on(type) { |data| events << data }
      host.dispatch_tag(tag, String.new)
      events
    end

    it 'reads prompt time only as the first attribute, after one space' do
      expect_each(
        '<prompt time="1">H&gt;</prompt>'       => 'H>',
        "<prompt time='1'>H&gt;</prompt>"       => 'H>',
        "<prompt time='1' x='y'>H&gt;</prompt>" => 'H>',
        "<prompt x='y' time='1'>H&gt;</prompt>" => nil,
        "<prompt  time='1'>H&gt;</prompt>"      => nil,
        "<prompt ptime='1'>H&gt;</prompt>"      => nil,
        "<prompt time='1a'>H&gt;</prompt>"      => nil,
        "<prompt time=''>H&gt;</prompt>"        => nil
      ) { |h, tag| events_of(h, tag, :prompt_changed).last&.fetch(:text) }
    end

    it 'reads roundTime and castTime values only as the first attribute, after one space' do
      tags = {
        "<TAG value='5'/>"           => 5,
        '<TAG value="5"/>'           => 5,
        "<TAG value='5' value='6'/>" => 5,
        "<TAG x='1' value='5'/>"     => nil,
        "<TAG  value='5'/>"          => nil,
        "<TAG pvalue='5'/>"          => nil,
        "<TAG value='-5'/>"          => nil,
        "<TAG value=''/>"            => nil
      }
      expect_each(tags.transform_keys { |t| t.gsub('TAG', 'roundTime') }) { |h, tag| events_of(h, tag, :countdown_update).last&.fetch(:end_time) }
      expect_each(tags.transform_keys { |t| t.gsub('TAG', 'castTime') }) { |h, tag| events_of(h, tag, :countdown_update).last&.fetch(:secondary_end_time) }
    end

    it 'reads the style id only as the first attribute, after one space' do
      expect_each(
        "<style id='roomName'/>"       => :title,
        '<style id="roomName"/>'       => :title,
        "<style id='roomName' x='1'/>" => :title,
        "<style x='1' id='roomName'/>" => nil,
        "<style  id='roomName'/>"      => nil,
        "<style pid='roomName'/>"      => nil
      ) { |h, tag| h.dispatch_tag(tag, String.new).then { h.room_capture_mode } }
    end

    it 'reads LaunchURL src only double-quoted, as the first attribute, after one space' do
      expect_each(
        '<LaunchURL src="/p"/>'        => 'https://www.play.net/p',
        "<LaunchURL src='/p'/>"        => nil,
        %(<LaunchURL x="1" src="/p"/>) => nil,
        '<LaunchURL  src="/p"/>'       => nil,
        '<LaunchURL src=""/>'          => nil
      ) { |h, tag| events_of(h, tag, :launch_url).last&.fetch(:url) }
    end

    it 'reads compass dir values only double-quoted, as the first attribute, after one space' do
      expect_each(
        %(<compass><dir value="n"/><dir value="s"/></compass>)  => %w[n s],
        "<compass><dir value='n'/><dir value=\"s\"/></compass>" => %w[s],
        %(<compass><dir x="1" value="n"/></compass>)            => [],
        %(<compass><dir  value="n"/></compass>)                 => [],
        %(<compass><dir value=""/></compass>)                   => [''],
        %(<compass><dirx value="n"/></compass>)                 => []
      ) { |h, tag| events_of(h, tag, :compass_update).last[:dirs] }
    end

    it 'reads indicator id and visible only in that order, one space apart' do
      expect_each(
        "<indicator id='IconSTUNNED' visible='y'/>"       => ['stunned', true],
        %(<indicator id="IconSTUNNED" visible='n'/>)      => ['stunned', false],
        "<indicator visible='y' id='IconSTUNNED'/>"       => nil,
        "<indicator id='IconSTUNNED'  visible='y'/>"      => nil,
        "<indicator x='1' id='IconSTUNNED' visible='y'/>" => nil,
        "<indicator id='Iconstunned' visible='y'/>"       => nil,
        "<indicator id='IconSTUNNED' visible='yes'/>"     => nil
      ) { |h, tag| events_of(h, tag, :countdown_active).last&.values_at(:id, :active) }
    end

    it 'reads image id and name only in that order, one space apart' do
      expect_each(
        "<image id='chest' name='Injury2'/>"  => ['chest', 2],
        %(<image id="chest" name='Injury2'/>) => ['chest', 2],
        "<image name='Injury2' id='chest'/>"  => nil,
        "<image id='chest'  name='Injury2'/>" => nil,
        "<image id='elbow' name='Injury2'/>"  => nil
      ) { |h, tag| events_of(h, tag, :indicator_update).last&.values_at(:id, :value) }
    end

    it 'reads progressBar attributes only single-quoted, in id/value/text order, one space apart' do
      expect_each(
        "<progressBar id='health' value='75' text='health 75%'/>"       => { id: 'health', value: 75, max: 100 },
        %(<progressBar id="health" value="75" text="health 75%"/>)      => nil,
        "<progressBar value='75' id='health' text='health 75%'/>"       => nil,
        "<progressBar id='health'  value='75' text='health 75%'/>"      => nil,
        "<progressBar id='pbarStance' value='80'/>"                     => { id: 'stance', value: 80, max: 100 },
        "<progressBar id='encumlevel' value='20' text='Overloaded'/>"   => { id: 'encumbrance', value: 110, max: 110 },
        "<progressBar id='mindState' value='5' text='x'/>"              => { id: 'mind', value: 5, max: 110 },
        "<progressBar id='health' value='9' text='health 456/456'/>"    => { id: 'health', value: 456, max: 456 },
        # A value can run past its closing quote to reach the next attribute.
        "<progressBar id='mindState' value='5' b' text='x'/>"           => { id: 'mind', value: 5, max: 110 },
        "<progressBar id='a' b' value='9' text='x 1/2'/>"               => { id: "a' b", value: 1, max: 2 },
        # Of two ids, the value runs from the first to the second.
        "<progressBar id='x' id='health' value='9' text='health 4/5'/>" => { id: "x' id='health", value: 4, max: 5 }
      ) { |h, tag| events_of(h, tag, :progress_update).last }
    end

    it 'reads arbProgress attributes only single-quoted, in id/max/current/label/colors order' do
      expect_each(
        "<arbProgress id='bar' max='10' current='5' label='Foo' colors='red,blue'/>" =>
          { id: 'bar', value: 5, max: 10, label: 'Foo', bg: ['red'], fg: ['blue'] },
        %(<arbProgress id="bar" max='10' current='5'/>) => nil,
        "<arbProgress max='10' id='bar' current='5'/>" => nil,
        "<arbProgress id='bar' max='10' current='5' colors='red,blue' label='Foo'/>" => { id: 'bar', value: 5, max: 10, bg: ['red'], fg: ['blue'] },
        %(<arbProgress id='bar' max='10' current='5' label="Foo"/>) => { id: 'bar', value: 5, max: 10 },
        %(<arbProgress id='bar' max='10' current='5' colors="red,blue"/>) => { id: 'bar', value: 5, max: 10 },
        # An empty label swallows the next attribute.
        "<arbProgress id='bar' max='10' current='5' label='' colors='red,blue'/>" => { id: 'bar', value: 5, max: 10, label: "' colors=" }
      ) { |h, tag| events_of(h, tag, :progress_update).last }
    end

    it 'reads the preset id only as the only attribute, running to the last quote' do
      PRESET['speech'] = ['aa', nil]
      PRESET["a'b"] = ['bb', nil]
      expect_each(
        "<preset id='speech'>"       => { start: 0, fg: 'aa', bg: nil },
        '<preset id="speech">'       => { start: 0, fg: 'aa', bg: nil },
        "<preset id='speech' x='1'>" => { start: 0 },
        "<preset x='1' id='speech'>" => nil,
        "<preset id='speech'/>"      => nil,
        "<preset id='a'b'>"          => { start: 0, fg: 'bb', bg: nil }
      ) { |h, tag| h.dispatch_tag(tag, String.new).then { h.open_preset.last } }
    end

    it 'reads a stream id wherever id= appears, even inside another name or value' do
      expect_each(
        "<pushStream id='combat'/>"                    => 'combat',
        '<pushStream id="combat"/>'                    => 'combat',
        "<pushStream x='1' id='combat'/>"              => 'combat',
        "<pushStream pid='combat'/>"                   => 'combat',
        "<component x-id='room objs' id='room desc'/>" => 'room objs',
        %(<compDef title="id='exp'" id='room'/>)       => 'exp',
        "<pushStream junk id='combat'/>"               => 'combat'
      ) { |h, tag| h.dispatch_tag(tag, String.new).then { h.current_stream } }
    end

    it 'reads a room subtitle wherever subtitle= appears' do
      expect_each(
        "<component id='room' subtitle=' - [Hall]'/>"  => 'Hall',
        "<component subtitle=' - [Hall]' id='room'/>"  => 'Hall',
        "<component id='room' xsubtitle=' - [Hall]'/>" => 'Hall'
      ) { |h, tag| h.dispatch_tag(tag, String.new).then { h.state.room_title } }
    end

    it 'reads a popStream id after any non-word character' do
      expect_each(
        "<popStream id='combat'/>"          => 'percWindow',
        %(<popStream id="combat"/>)         => 'percWindow',
        "<popStream x-id='combat'/>"        => 'percWindow',
        "<popStream pid='combat'/>"         => 'combat',
        %(<popStream title="id='combat'"/>) => 'percWindow'
      ) do |h, tag|
        %w[percWindow combat familiar].each { |id| h.dispatch_tag("<pushStream id='#{id}'/>", String.new) }
        h.dispatch_tag(tag, String.new)
        h.current_stream
      end
    end

    it 'clears the spell window for id=percWindow in any quotes, even mismatched' do
      expect_each(
        '<clearStream id="percWindow"/>'  => 1,
        "<clearStream id='percWindow'/>"  => 1,
        %(<clearStream id="percWindow'/>) => 1,
        "<clearStream xid='percWindow'/>" => 1,
        "<clearStream id='percWindowX'/>" => 0
      ) { |h, tag| events_of(h, tag, :clear_spells).size }
    end

    it 'reads a room streamWindow only with id first and single-quoted' do
      expect_each(
        %(<streamWindow id='room' subtitle=" - [Hall]"/>)              => 'Hall',
        %(<streamWindow id='room' title='Room' subtitle=' - [Hall]'/>) => 'Hall',
        %(<streamWindow id="room" subtitle=" - [Hall]"/>)              => '',
        %(<streamWindow subtitle=" - [Hall]" id='room'/>)              => '',
        %(<streamWindow id='room' xsubtitle=" - [Hall]"/>)             => 'Hall',
        %(<streamWindow id='room' title="subtitle=' - [Hall]'"/>)      => 'Hall'
      ) { |h, tag| h.dispatch_tag(tag, String.new).then { h.state.room_title } }
    end
  end

  describe 'adversarial: progress bar edge cases' do
    it 'emits health at 0%' do
      events = collect_events(:progress_update)
      host.dispatch_tag("<progressBar id='health' value='0' text='health 0%'/>", String.new)
      expect(events.last).to include(id: 'health', value: 0, max: 100)
    end

    it 'emits encumbrance Overloaded as 110' do
      events = collect_events(:progress_update)
      host.dispatch_tag("<progressBar id='encumlevel' value='100' text='Overloaded'/>", String.new)
      expect(events.last).to include(id: 'encumbrance', value: 110, max: 110)
    end

    it 'emits mind saturated as 110' do
      events = collect_events(:progress_update)
      host.dispatch_tag("<progressBar id='mindState' value='100' text='saturated'/>", String.new)
      expect(events.last).to include(id: 'mind', value: 110, max: 110)
    end

    it 'emits GS vitals with negative current' do
      events = collect_events(:progress_update)
      host.dispatch_tag("<progressBar id='health' value='0' text='health -5/100'/>", String.new)
      expect(events.last).to include(id: 'health', value: -5, max: 100)
    end
  end
end
