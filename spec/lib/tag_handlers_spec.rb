# frozen_string_literal: true

# Tests TagHandlers, the tag parser GameTextProcessor includes: what each
# server tag does to the line being parsed (the color runs it records, the
# spans it leaves open, the text it flushes and the stream that text goes
# to) and the events it emits for the windows.
#
# TagHandlerHost (below) includes the module with the real collaborators
# GameTextProcessor gives it (SpanTracker, StreamRouter, RoomAssembler,
# PromptTracker) and records each chunk of text the parser flushes instead
# of routing it, so the examples read the parse state through those
# collaborators' public readers. Entity decoding, which happens between
# tags, goes through the real GameTextProcessor into a window on the
# virtual screen.

require 'rexml/document'
require 'stringio'
require_relative '../../lib/event_bus'
require_relative '../../lib/xml_tokenizer'
require_relative '../../lib/tag_handlers'
require_relative '../../lib/span_tracker'
require_relative '../../lib/shared_state'
require_relative '../../lib/clock'
require_relative '../../lib/pending_render'
require_relative '../../lib/prompt_tracker'
require_relative '../../lib/room_assembler'
require_relative '../../lib/stream_router'
require_relative '../../lib/window_manager'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'

# Includes TagHandlers the way GameTextProcessor does, with the same real
# collaborators, but keeps each flushed chunk of text (see #flushed_texts)
# instead of routing it to a window. Its readers delegate to the public
# readers of its own collaborators.
class TagHandlerHost
  include TagHandlers

  # @return [Array<Hash>] each chunk of text flushed mid-line, in order:
  #   its +:text+, the color runs handed off with it (+:colors+) and the
  #   stream it was on (+:stream+, nil for main)
  attr_reader :flushed_texts

  # @return [SharedState] the state the handlers update
  attr_reader :state

  # @return [EventBus] the bus the handlers emit on
  attr_reader :event_bus

  # @param window_mgr [WindowManager] asked which windows the layout has
  # @param state [SharedState] the state the handlers update
  # @param event_bus [EventBus] the bus the handlers emit on
  # @param clock [Clock] read for the server time offset at a prompt
  def initialize(window_mgr:, state:, event_bus:, clock: Clock.new)
    @state = state
    @event_bus = event_bus
    @spans = SpanTracker.new
    @pending_render = PendingRender.new
    @prompts = PromptTracker.new(shared_state: state, event_bus: event_bus, pending_render: @pending_render,
                                 window_mgr: window_mgr, clock: clock)
    @prompts.server = StringIO.new
    @room = RoomAssembler.new(window_mgr: window_mgr, event_bus: event_bus, pending_render: @pending_render,
                              shared_state: state)
    @router = StreamRouter.new(window_mgr: window_mgr, event_bus: event_bus, pending_render: @pending_render,
                               prompts: @prompts, room: @room)
    @flushed_texts = []
  end

  # Keep the flushed text (the parser's hand-off to GameTextProcessor).
  def handle_game_text(text, runs)
    @flushed_texts << { text: text.dup, colors: runs.dup, stream: current_stream }
  end

  # No line is gagged here (see LineFilter#gagged?).
  def line_gagged? = false

  # The color runs recorded since the last flush (SpanTracker#runs).
  def line_colors = @spans.runs

  # The innermost open span of a kind (SpanTracker#open_span).
  def open_span(kind) = @spans.open_span(kind)

  # What room text is being captured (RoomAssembler#capture_mode).
  def room_capture_mode = @room.capture_mode

  # The stream text goes to, nil for main (StreamRouter#current_stream).
  def current_stream = @router.current_stream

  # Whether an unrecognized tag switches to combat (StreamRouter#combat_routing?).
  def combat_routing? = @router.combat_routing?
end

RSpec.describe TagHandlers do
  let(:event_bus) { EventBus.new }
  let(:window_manager) { WindowManager.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:host) { build_host }

  # A host with its own state and bus, reading +clock+.
  def build_host(clock: Clock.new, state: self.state, event_bus: self.event_bus)
    TagHandlerHost.new(window_mgr: window_manager, state: state, event_bus: event_bus, clock: clock)
  end

  # Give the layout a room window (the room description is captured only
  # with one).
  def load_layout_with_room_window
    LAYOUT['tags'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='4' width='40' value='main'/>
        <window class='room' top='4' left='0' height='4' width='40'/>
      </layout>
    XML
    window_manager.load_layout('tags')
  end

  # @return [Array<Hash>] every event of +types+ emitted from now on, each
  #   with its +:type+
  def collect_events(*types)
    events = []
    types.each do |type|
      event_bus.on(type) { |data| events << { type: type, **data } }
    end
    events
  end

  # Send bare <popStream/> tags until text goes to main.
  #
  # @return [Array<String>] the streams text went to in between: the
  #   pushStreams still open below the current stream, innermost first
  def streams_popped_back_to(tag_host = host)
    streams = []
    10.times do
      tag_host.dispatch_tag('<popStream/>', String.new)
      break unless tag_host.current_stream

      streams << tag_host.current_stream
    end
    streams
  end

  describe '#dispatch_tag' do
    it 'has a handler for every paired tag but inv, whose content is only swallowed' do
      expect(XmlTokenizer::PAIRED_TAGS - described_class::TAG_DISPATCH.keys).to eq ['inv']
    end

    describe 'combat routing' do
      # A combat stream turns combat routing on; the component then sends
      # the text to +stream+ while routing stays on.
      def start_combat_routing_in(stream)
        host.dispatch_tag('<pushStream id="combat"/>', String.new)
        host.dispatch_tag("<component id='#{stream}'>", String.new)
      end

      it 'flushes the text so far to its stream and switches to combat at an unrecognized tag' do
        start_combat_routing_in('room players')

        host.dispatch_tag('<unknownTag/>', +'Also here: Fidon.')

        expect(host.flushed_texts.map { |f| f.values_at(:text, :stream) }).to eq [['Also here: Fidon.', 'room players']]
        expect(host.current_stream).to eq 'combat'
      end

      it 'switches to combat without flushing anything when no text was collected' do
        start_combat_routing_in('room players')

        host.dispatch_tag('<unknownTag/>', String.new)

        expect(host.current_stream).to eq 'combat'
        expect(host.flushed_texts).to be_empty
      end

      it 'does not switch to combat at a tag it ignores on purpose, such as dialogdata' do
        start_combat_routing_in('room players')

        host.dispatch_tag('<dialogdata id="foo"/>', String.new)

        expect(host.current_stream).to eq 'room players'
      end

      it 'ends at a popStream naming combat, so a later unrecognized tag stays on main' do
        host.dispatch_tag('<pushStream id="combat"/>', String.new)

        host.dispatch_tag('<popStream id="combat" />', String.new)
        host.dispatch_tag('<unknownTag/>', String.new)

        expect(host.combat_routing?).to be false
        expect(host.current_stream).to be_nil
      end

      it 'ends at a popStream naming combat even while another stream is current' do
        start_combat_routing_in('thoughts')

        host.dispatch_tag('<popStream id="combat" />', String.new)

        expect(host.combat_routing?).to be false
        expect(host.current_stream).to be_nil
      end
    end
  end

  describe 'bold: <pushBold/> and <popBold/>, <b> and </b>' do
    before { PRESET['monsterbold'] = ['ff0000', nil] }

    it 'colors the text between them with the monsterbold preset' do
      buf = +'Hello '
      host.dispatch_tag('<pushBold/>', buf)
      buf << 'goblin'
      host.dispatch_tag('<popBold/>', buf)

      expect(host.line_colors).to eq [{ start: 6, fg: 'ff0000', bg: nil, end: 12 }]
    end

    it 'treats <b> and </b> the same way' do
      buf = +''
      host.dispatch_tag('<b>', buf)
      buf << 'bold'
      host.dispatch_tag('</b>', buf)

      expect(host.line_colors).to eq [{ start: 0, fg: 'ff0000', bg: nil, end: 4 }]
    end

    it 'records an inner and an outer run for nested bold, the inner one first' do
      buf = +''
      host.dispatch_tag('<pushBold/>', buf)
      buf << 'outer '
      host.dispatch_tag('<pushBold/>', buf)
      buf << 'inner'
      host.dispatch_tag('<popBold/>', buf)
      buf << ' outer'
      host.dispatch_tag('<popBold/>', buf)

      expect(host.line_colors.map { |run| run.values_at(:start, :end) }).to eq [[6, 11], [0, 17]]
    end

    it 'records an empty run for bold around no text' do
      buf = +''
      host.dispatch_tag('<pushBold/>', buf)
      host.dispatch_tag('<popBold/>', buf)

      expect(host.line_colors).to eq [{ start: 0, fg: 'ff0000', bg: nil, end: 0 }]
    end

    it 'records nothing for a popBold with no bold open' do
      host.dispatch_tag('<popBold/>', +'text')

      expect(host.line_colors).to be_empty
    end
  end

  # A closing tag with nothing of its kind open changes nothing: the text
  # stays in the line and a span of another kind stays open.
  describe 'a stray closing tag' do
    before { PRESET['monsterbold'] = ['ff0000', nil] }

    # A line with 'goblin' in an open bold span.
    let(:buf) do
      (+'Hello ').tap do |text|
        host.dispatch_tag('<pushBold/>', text)
        text << 'goblin'
      end
    end

    it 'leaves the line whole and the bold open at a stray </preset>' do
      host.dispatch_tag('</preset>', buf)

      expect([buf, host.flushed_texts]).to eq ['Hello goblin', []]
      expect(host.open_span(:bold)).to eq(start: 6, fg: 'ff0000', bg: nil)
    end

    it 'leaves the bold open at a stray </color>' do
      host.dispatch_tag('</color>', buf)

      expect(host.open_span(:bold)).to eq(start: 6, fg: 'ff0000', bg: nil)
      expect(host.line_colors).to be_empty
    end

    it 'leaves the bold open at a stray </d>' do
      state.blue_links = true

      host.dispatch_tag('</d>', buf)

      expect(host.open_span(:bold)).to eq(start: 6, fg: 'ff0000', bg: nil)
      expect(host.line_colors).to be_empty
    end

    it 'leaves the bold open at a stray </a>' do
      state.blue_links = true

      host.dispatch_tag('</a>', buf)

      expect(host.open_span(:bold)).to eq(start: 6, fg: 'ff0000', bg: nil)
      expect(host.line_colors).to be_empty
    end
  end

  describe '<prompt>' do
    let(:prompt) { '<prompt time="1679000000">H&gt;</prompt>' }

    it 'sets the prompt text' do
      state.prompt_text = '>'

      host.dispatch_tag(prompt, String.new)

      expect(state.prompt_text).to eq 'H>'
    end

    it 'sets the server time offset from the first prompt' do
      clock = Clock.new(now: -> { Time.at(1_679_000_010.5) })
      state.skip_server_time_offset = false

      build_host(clock: clock).dispatch_tag(prompt, String.new)

      expect(state.skip_server_time_offset).to be true
      expect(clock.server_time_offset).to eq 10.5
    end

    it 'keeps the offset until a resync' do
      readings = [Time.at(1_679_000_010.5), Time.at(1_679_000_099.0)]
      clock = Clock.new(now: -> { readings.shift })
      state.skip_server_time_offset = false
      clocked_host = build_host(clock: clock)

      clocked_host.dispatch_tag(prompt, String.new)
      clocked_host.dispatch_tag('<prompt time="1679000001">H&gt;</prompt>', String.new)

      expect(clock.server_time_offset).to eq 10.5
    end

    it 'shows a new prompt in main and fits the prompt window to it' do
      events = collect_events(:add_prompt, :prompt_changed)
      state.prompt_text = '>'

      host.dispatch_tag(prompt, String.new)

      expect(events).to eq [{ type: :add_prompt, stream: 'main', text: 'H>' }, { type: :prompt_changed, text: 'H>' }]
    end

    it 'emits nothing and leaves the prompt pending on a repeated prompt' do
      state.prompt_text = 'H>'
      events = collect_events(:add_prompt, :prompt_changed)

      host.dispatch_tag(prompt, String.new)

      expect(events).to be_empty
      expect(state.consume_prompt!).to be true
    end

    it 'puts a new prompt in the terminal title' do
      allow(Process).to receive(:setproctitle)
      allow($stdout).to receive(:write)
      state.char_name = 'Mahtra'

      host.dispatch_tag(prompt, String.new)
      state.update_terminal_title

      expect(Process).to have_received(:setproctitle).with('Mahtra [H]')
    end
  end

  describe '<spell>' do
    it 'shows the spell being prepared on the spell indicator' do
      events = collect_events(:indicator_update)

      host.dispatch_tag('<spell>Fire Ball</spell>', String.new)

      expect(events).to eq [{ type: :indicator_update, id: 'spell', label: 'Fire Ball', value: 1 }]
    end

    it 'turns the spell indicator off for None' do
      events = collect_events(:indicator_update)

      host.dispatch_tag('<spell>None</spell>', String.new)

      expect(events.last).to include(id: 'spell', value: 0)
    end

    it 'passes an empty spell name through as the label' do
      events = collect_events(:indicator_update)

      host.dispatch_tag('<spell></spell>', String.new)

      expect(events.last).to include(id: 'spell', label: '')
    end
  end

  describe '<right> and <left>' do
    it 'shows what the hand holds on its indicator' do
      events = collect_events(:indicator_update)

      host.dispatch_tag('<right>a steel sword</right>', String.new)

      expect(events.last).to include(id: 'right', label: 'a steel sword', value: 1)
    end

    it 'turns the hand indicator off for Empty' do
      events = collect_events(:indicator_update)

      host.dispatch_tag('<left>Empty</left>', String.new)

      expect(events.last).to include(id: 'left', label: 'Empty', value: 0)
    end
  end

  describe '<compass>' do
    it 'lists the directions of the room exits' do
      events = collect_events(:compass_update)

      host.dispatch_tag('<compass><dir value="n"/><dir value="e"/></compass>', String.new)

      expect(events.last[:dirs]).to contain_exactly('n', 'e')
    end
  end

  describe '<roundTime> and <castTime>' do
    it 'sets the roundtime end time from <roundTime>' do
      events = collect_events(:countdown_update)

      host.dispatch_tag("<roundTime value='1679000010'/>", String.new)

      expect(events.last).to eq(type: :countdown_update, id: 'roundtime', end_time: 1_679_000_010)
    end

    it 'sets the secondary end time from <castTime>' do
      events = collect_events(:countdown_update)

      host.dispatch_tag("<castTime value='1679000020'/>", String.new)

      expect(events.last).to eq(type: :countdown_update, id: 'roundtime', secondary_end_time: 1_679_000_020)
    end
  end

  describe 'opening a stream: <pushStream>, <component>, <compDef>' do
    it 'flushes the text before it to the stream it was on, then switches' do
      buf = +'text before stream'

      host.dispatch_tag('<pushStream id="combat" />', buf)

      expect(host.flushed_texts.map { |f| f.values_at(:text, :stream) }).to eq [['text before stream', nil]]
      expect(host.current_stream).to eq 'combat'
      expect(buf).to eq ''
    end

    it 'turns combat routing on for the combat stream' do
      host.dispatch_tag('<pushStream id="combat" />', String.new)

      expect(host.combat_routing?).to be true
    end

    it 'routes an exp stream to the exp window and names its skill' do
      events = collect_events(:exp_set_current)

      host.dispatch_tag('<pushStream id="exp Athletics" />', String.new)

      expect(host.current_stream).to eq 'exp'
      expect(events.last).to include(skill: 'Athletics')
    end

    it 'takes the room title from the subtitle of a room component' do
      events = collect_events(:room_title)

      host.dispatch_tag(%q{<component id="room" subtitle=" - [Town Square]">}, String.new)

      expect(events.last).to include(text: 'Town Square')
      expect(state.room_title).to eq 'Town Square'
    end

    it 'ignores a pushStream or component without an id, keeping the text before it in the line' do
      buf = +'Hello '

      host.dispatch_tag('<component/>', buf)
      host.dispatch_tag('<pushStream/>', buf)

      expect([buf, host.flushed_texts, host.current_stream]).to eq ['Hello ', [], nil]
    end

    it 'switches to each stream opened, even without a close between them' do
      host.dispatch_tag('<pushStream id="combat" />', String.new)
      expect(host.current_stream).to eq 'combat'

      host.dispatch_tag('<pushStream id="thoughts" />', String.new)
      expect(host.current_stream).to eq 'thoughts'
    end
  end

  describe 'closing a stream: <popStream>, </component>, </compDef>' do
    it 'flushes the text before it to the stream, then returns to main' do
      host.dispatch_tag('<pushStream id="combat" />', String.new)
      buf = +'combat text'

      host.dispatch_tag('<popStream id="combat" />', buf)

      expect(host.flushed_texts.map { |f| f.values_at(:text, :stream) }).to eq [['combat text', 'combat']]
      expect(host.current_stream).to be_nil
    end

    it 'closes the current exp skill when an exp component closes' do
      events = collect_events(:exp_delete_skill)
      host.dispatch_tag("<component id='exp Athletics'>", String.new)

      host.dispatch_tag('</component>', String.new)

      expect(events.length).to eq 1
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

      expect(streams_popped_back_to).to eq %w[familiar thoughts]
    end

    it 'closes the named stream and anything opened after it on popStream id=' do
      receive_tags('<pushStream id="thoughts"/>', '<pushStream id="combat" />', '<pushStream id="moonWindow"/>')

      host.dispatch_tag('<popStream id="combat" />', String.new)

      expect(host.current_stream).to eq 'thoughts'
      expect(streams_popped_back_to).to be_empty
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
      receive_tags('<popStream/>', '<popStream id="combat" />')

      expect(host.current_stream).to be_nil
    end

    it 'handles the empath-touch double familiar push and double pop from a real log' do
      receive_tags('<pushStream id="familiar" />', '<pushStream id="familiar" ifClosedStyle="watching"/>')
      expect(host.current_stream).to eq 'familiar'

      host.dispatch_tag('<popStream/>', String.new)
      expect(host.current_stream).to eq 'familiar'
      host.dispatch_tag('<popStream/>', String.new)
      expect(host.current_stream).to be_nil
    end

    context 'with components' do
      it 'returns to the enclosing pushStream when a component closes inside it' do
        receive_tags('<pushStream id="familiar"/>', "<component id='room players'>")

        expect(flush_before('</component>', 'Also here: Fidon.')).to eq ['Also here: Fidon.', 'room players']
        expect(host.current_stream).to eq 'familiar'
      end

      it 'leaves the open pushStreams alone for a component pair' do
        receive_tags('<pushStream id="thoughts"/>', "<component id='room objs'>", '</component>', '<popStream/>')

        expect(host.current_stream).to be_nil
      end

      it 'records nothing a later pop could return to for a self-closing component' do
        receive_tags("<component id='x'/>", '<pushStream id="thoughts"/>', '<popStream/>')

        expect(host.current_stream).to be_nil
      end

      it 'records nothing a later pop could return to for a compDef pair' do
        receive_tags('<pushStream id="thoughts"/>', "<compDef id='exp Bow'>", '</compDef>')

        expect(host.current_stream).to eq 'thoughts'
        expect(streams_popped_back_to).to be_empty
      end
    end

    context 'at a <prompt>' do
      it 'sends text to main after a push that never got its pop' do
        receive_tags('<pushStream id="moonWindow"/>', prompt)

        expect(host.current_stream).to be_nil
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

      it 'ends combat routing left on by an unclosed combat push' do
        receive_tags('<pushStream id="combat" />', prompt, '<unknownTag/>')

        expect(host.combat_routing?).to be false
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
        expect(streams_popped_back_to).to be_empty
      end
    end

    it 'keeps only the 8 most recent unmatched pushes' do
      receive_tags(*(1..11).map { |n| %(<pushStream id="s#{n}"/>) })

      # s11 is current; s1, s2 and s3 were dropped.
      expect(streams_popped_back_to).to eq %w[s10 s9 s8 s7 s6 s5 s4]
    end
  end

  describe '<color> and </color>' do
    it 'colors the text between them with the fg and bg it names' do
      buf = +''
      host.dispatch_tag('<color fg="ff0000" bg="000000">', buf)
      buf << 'red on black'
      host.dispatch_tag('</color>', buf)

      expect(host.line_colors).to eq [{ start: 0, fg: 'ff0000', bg: '000000', end: 12 }]
    end

    it 'passes the underline attribute on' do
      buf = +''
      host.dispatch_tag('<color ul="true">', buf)
      buf << 'underlined'
      host.dispatch_tag('</color>', buf)

      expect(host.line_colors).to eq [{ start: 0, ul: 'true', end: 10 }]
    end

    it 'records back-to-back colors as adjacent runs' do
      buf = +''
      host.dispatch_tag('<color fg="ff0000">', buf)
      buf << 'red'
      host.dispatch_tag('</color>', buf)
      host.dispatch_tag('<color fg="00ff00">', buf)
      buf << 'green'
      host.dispatch_tag('</color>', buf)

      expect(host.line_colors).to eq [{ start: 0, fg: 'ff0000', end: 3 }, { start: 3, fg: '00ff00', end: 8 }]
    end
  end

  describe '<preset> and </preset>' do
    it 'colors the text between them with the preset' do
      PRESET['speech'] = ['00ff00', '000000']
      buf = +''
      host.dispatch_tag('<preset id="speech">', buf)
      buf << 'Someone says hello'
      host.dispatch_tag('</preset>', buf)

      expect(host.line_colors).to eq [{ start: 0, fg: '00ff00', bg: '000000', end: 18 }]
    end

    it 'records an inner and an outer run for nested presets, each in its own color' do
      PRESET['speech'] = ['00ff00', nil]
      PRESET['whisper'] = ['0000ff', nil]
      buf = +''
      host.dispatch_tag('<preset id="speech">', buf)
      buf << 'outer '
      host.dispatch_tag('<preset id="whisper">', buf)
      buf << 'inner'
      host.dispatch_tag('</preset>', buf)
      host.dispatch_tag('</preset>', buf)

      expect(host.line_colors).to eq [{ start: 6, fg: '0000ff', bg: nil, end: 11 },
                                      { start: 0, fg: '00ff00', bg: nil, end: 11 }]
    end

    it 'colors nothing for a preset id the settings do not define' do
      buf = +''
      host.dispatch_tag('<preset id="nonexistent">', buf)
      buf << 'plain'
      host.dispatch_tag('</preset>', buf)

      expect(host.line_colors).to be_empty
    end

    it 'flushes the text before a roomDesc preset and captures the description, with a room window' do
      load_layout_with_room_window
      buf = +'text before desc'

      host.dispatch_tag('<preset id="roomDesc">', buf)

      expect(host.flushed_texts.map { |f| f[:text] }).to eq ['text before desc']
      expect(host.room_capture_mode).to eq :desc
    end
  end

  describe '<style>' do
    before { PRESET['roomName'] = ['00ff00', nil] }

    it 'opens a style span and captures the room title at a roomName style' do
      host.dispatch_tag('<style id="roomName"/>', String.new)

      expect(host.open_span(:style)).to eq(start: 0, fg: '00ff00', bg: nil)
      expect(host.room_capture_mode).to eq :title
    end

    it 'closes the style and flushes the captured title at a style with an empty id' do
      buf = +''
      host.dispatch_tag('<style id="roomName"/>', buf)
      buf << 'Town Square'

      host.dispatch_tag('<style id=""/>', buf)

      expect(host.open_span(:style)).to be_nil
      expect(host.flushed_texts.map { |f| f[:text] }).to eq ['Town Square']
    end

    it 'leaves an open style and its room capture alone at a style without an id' do
      buf = +''
      host.dispatch_tag('<style id="roomName"/>', buf)
      buf << 'Town Square'

      host.dispatch_tag('<style/>', buf)

      expect(host.open_span(:style)).to eq(start: 0, fg: '00ff00', bg: nil)
      expect([host.room_capture_mode, host.flushed_texts]).to eq [:title, []]
    end
  end

  describe 'links: <d> and <a>' do
    before { state.blue_links = true }

    it 'records the cmd attribute as the link command' do
      buf = +'Go through '
      host.dispatch_tag("<d cmd='go door'>", buf)
      buf << 'the door'
      host.dispatch_tag('</d>', buf)

      expect(host.line_colors.find { |c| c[:cmd] }).to include(start: 11, end: 19, cmd: 'go door')
    end

    it 'uses the link text as the command when there is no cmd attribute' do
      buf = +'Exit: '
      host.dispatch_tag('<d>', buf)
      buf << 'north'
      host.dispatch_tag('</d>', buf)

      expect(host.line_colors.find { |c| c[:cmd] }).to include(cmd: 'north')
    end

    it 'looks at a GemStone <a> item by its exist id' do
      buf = +''
      host.dispatch_tag('<a exist="12345" noun="sword">', buf)
      buf << 'a sword'
      host.dispatch_tag('</a>', buf)

      expect(host.line_colors.find { |c| c[:cmd] }).to include(cmd: 'look #12345')
    end

    it 'drags a GemStone <a> item with an exist id but no noun' do
      buf = +''
      host.dispatch_tag('<a exist="99999">', buf)
      buf << 'an item'
      host.dispatch_tag('</a>', buf)

      expect(host.line_colors.find { |c| c[:cmd] }).to include(cmd: '_drag #99999')
    end

    it 'keeps a cmd with special characters as sent' do
      buf = +''
      host.dispatch_tag("<d cmd='go #12345 door'>", buf)
      buf << 'the door'
      host.dispatch_tag('</d>', buf)

      expect(host.line_colors.find { |c| c[:cmd] }).to include(cmd: 'go #12345 door')
    end

    it 'records no link command around no text' do
      buf = +''
      host.dispatch_tag('<d>', buf)
      host.dispatch_tag('</d>', buf)

      expect(host.line_colors.filter_map { |c| c[:cmd] }).to be_empty
    end

    it 'records nothing while links are off' do
      state.blue_links = false
      buf = +''
      host.dispatch_tag("<d cmd='go'>", buf)
      buf << 'door'
      host.dispatch_tag('</d>', buf)

      expect(host.line_colors).to be_empty
    end
  end

  describe '<indicator>' do
    it 'turns the icon indicator on for a visible icon' do
      events = collect_events(:indicator_update)

      host.dispatch_tag("<indicator id='IconSTUNNED' visible='y'/>", String.new)

      expect(events).to eq [{ type: :indicator_update, id: 'stunned', value: true }]
    end

    it 'turns the countdown of the same name on' do
      events = collect_events(:countdown_active)

      host.dispatch_tag("<indicator id='IconSTUNNED' visible='y'/>", String.new)

      expect(events).to eq [{ type: :countdown_active, id: 'stunned', active: true }]
    end
  end

  describe '<image>' do
    it 'sets the nerve damage rank from an nsys image' do
      events = collect_events(:indicator_update)

      host.dispatch_tag("<image id='nsys' name='nsys3'/>", String.new)

      expect(events.last).to include(id: 'nsys', value: 3)
    end

    it 'sets the injury level of a body part' do
      events = collect_events(:indicator_update)

      host.dispatch_tag("<image id='chest' name='Injury2'/>", String.new)

      expect(events.last).to include(id: 'chest', value: 2)
    end
  end

  describe '<LaunchURL>' do
    it 'opens the src as a path on www.play.net' do
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

  describe '<streamWindow>' do
    it 'takes the room title from the subtitle of the room streamWindow' do
      events = collect_events(:indicator_update, :room_title)

      host.dispatch_tag(%q{<streamWindow id='room' subtitle=" - [Town Square]"/>}, String.new)

      expect(state.room_title).to eq 'Town Square'
      expect(events).to include(a_hash_including(type: :room_title, text: 'Town Square'))
      expect(events).to include(a_hash_including(type: :indicator_update, id: 'room', label: 'Town Square'))
    end

    it 'keeps the DragonRealms room number after the title' do
      host.dispatch_tag(%q{<streamWindow id='room' subtitle=" - [Bosque Deriel] (230008)"/>}, String.new)

      expect(state.room_title).to eq 'Bosque Deriel (230008)'
    end

    it 'ignores a streamWindow other than room' do
      host.dispatch_tag(%q{<streamWindow id='main' subtitle="test"/>}, String.new)

      expect(state.room_title).to eq ''
    end
  end

  describe '<clearStream>' do
    it 'clears the spell window for percWindow' do
      events = collect_events(:clear_spells)

      host.dispatch_tag('<clearStream id="percWindow"/>', String.new)

      expect(events.length).to eq 1
    end

    it 'clears nothing for another stream' do
      events = collect_events(:clear_spells)

      host.dispatch_tag('<clearStream id="other"/>', String.new)

      expect(events).to be_empty
    end
  end

  describe '<progressBar>' do
    it 'shows DragonRealms health at 0%' do
      events = collect_events(:progress_update)

      host.dispatch_tag("<progressBar id='health' value='0' text='health 0%'/>", String.new)

      expect(events.last).to include(id: 'health', value: 0, max: 100)
    end

    it 'fills the encumbrance bar past full for Overloaded' do
      events = collect_events(:progress_update)

      host.dispatch_tag("<progressBar id='encumlevel' value='100' text='Overloaded'/>", String.new)

      expect(events.last).to include(id: 'encumbrance', value: 110, max: 110)
    end

    it 'fills the mind bar past full for saturated' do
      events = collect_events(:progress_update)

      host.dispatch_tag("<progressBar id='mindState' value='100' text='saturated'/>", String.new)

      expect(events.last).to include(id: 'mind', value: 110, max: 110)
    end

    it 'shows a negative current GemStone vital' do
      events = collect_events(:progress_update)

      host.dispatch_tag("<progressBar id='health' value='0' text='health -5/100'/>", String.new)

      expect(events.last).to include(id: 'health', value: -5, max: 100)
    end

    it 'ignores a progressBar without a value, even when its text has numbers' do
      events = collect_events(:progress_update)

      host.dispatch_tag("<progressBar id='health' text='health 456/456'/>", String.new)

      expect(events).to be_empty
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
        fresh = build_host(state: SharedState.new.tap { |s| s.skip_server_time_offset = true }, event_bus: EventBus.new)
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

    it 'reads prompt time in either quotes, anywhere among the attributes' do
      expect_each(
        '<prompt time="1">H&gt;</prompt>'       => 'H>',
        "<prompt time='1'>H&gt;</prompt>"       => 'H>',
        "<prompt time='1' x='y'>H&gt;</prompt>" => 'H>',
        "<prompt x='y' time='1'>H&gt;</prompt>" => 'H>',
        "<prompt  time='1'>H&gt;</prompt>"      => 'H>',
        "<prompt ptime='1'>H&gt;</prompt>"      => nil,
        "<prompt time='1a'>H&gt;</prompt>"      => nil,
        "<prompt time=''>H&gt;</prompt>"        => nil
      ) { |h, tag| events_of(h, tag, :prompt_changed).last&.fetch(:text) }
    end

    it 'reads roundTime and castTime values in either quotes, anywhere among the attributes' do
      tags = {
        "<TAG value='5'/>"           => 5,
        '<TAG value="5"/>'           => 5,
        "<TAG value='5' value='6'/>" => 5,
        "<TAG x='1' value='5'/>"     => 5,
        "<TAG  value='5'/>"          => 5,
        "<TAG pvalue='5'/>"          => nil,
        "<TAG value='-5'/>"          => nil,
        "<TAG value=''/>"            => nil
      }
      expect_each(tags.transform_keys { |t| t.gsub('TAG', 'roundTime') }) { |h, tag| events_of(h, tag, :countdown_update).last&.fetch(:end_time) }
      expect_each(tags.transform_keys { |t| t.gsub('TAG', 'castTime') }) { |h, tag| events_of(h, tag, :countdown_update).last&.fetch(:secondary_end_time) }
    end

    it 'reads the style id in either quotes, anywhere among the attributes' do
      expect_each(
        "<style id='roomName'/>"       => :title,
        '<style id="roomName"/>'       => :title,
        "<style id='roomName' x='1'/>" => :title,
        "<style x='1' id='roomName'/>" => :title,
        "<style  id='roomName'/>"      => :title,
        "<style pid='roomName'/>"      => nil
      ) { |h, tag| h.dispatch_tag(tag, String.new).then { h.room_capture_mode } }
    end

    it 'reads LaunchURL src in either quotes, anywhere among the attributes' do
      expect_each(
        '<LaunchURL src="/p"/>'              => 'https://www.play.net/p',
        "<LaunchURL src='/p'/>"              => 'https://www.play.net/p',
        %(<LaunchURL x="1" src="/p"/>)       => 'https://www.play.net/p',
        '<LaunchURL  src="/p"/>'             => 'https://www.play.net/p',
        "<LaunchURL src='@evil.example/x'/>" => nil,
        '<LaunchURL src=""/>'                => nil
      ) { |h, tag| events_of(h, tag, :launch_url).last&.fetch(:url) }
    end

    it 'reads compass dir values in either quotes, anywhere among the attributes' do
      expect_each(
        %(<compass><dir value="n"/><dir value="s"/></compass>)  => %w[n s],
        "<compass><dir value='n'/><dir value=\"s\"/></compass>" => %w[n s],
        %(<compass><dir x="1" value="n"/></compass>)            => %w[n],
        %(<compass><dir  value="n"/></compass>)                 => %w[n],
        %(<compass><dir value=""/></compass>)                   => [''],
        %(<compass><dirx value="n"/></compass>)                 => []
      ) { |h, tag| events_of(h, tag, :compass_update).last[:dirs] }
    end

    it 'reads indicator id and visible in either quotes and either order' do
      expect_each(
        "<indicator id='IconSTUNNED' visible='y'/>"       => ['stunned', true],
        %(<indicator id="IconSTUNNED" visible='n'/>)      => ['stunned', false],
        "<indicator visible='y' id='IconSTUNNED'/>"       => ['stunned', true],
        "<indicator id='IconSTUNNED'  visible='y'/>"      => ['stunned', true],
        "<indicator x='1' id='IconSTUNNED' visible='y'/>" => ['stunned', true],
        "<indicator id='Iconstunned' visible='y'/>"       => nil,
        "<indicator id='BadFormat' visible='y'/>"         => nil,
        "<indicator id='IconSTUNNED' visible='yes'/>"     => nil
      ) { |h, tag| events_of(h, tag, :countdown_active).last&.values_at(:id, :active) }
    end

    it 'reads image id and name in either quotes and either order' do
      expect_each(
        "<image id='chest' name='Injury2'/>"  => ['chest', 2],
        %(<image id="chest" name='Injury2'/>) => ['chest', 2],
        "<image name='Injury2' id='chest'/>"  => ['chest', 2],
        "<image id='chest'  name='Injury2'/>" => ['chest', 2],
        "<image id='elbow' name='Injury2'/>"  => nil
      ) { |h, tag| events_of(h, tag, :indicator_update).last&.values_at(:id, :value) }
    end

    it 'reads progressBar attributes in either quotes and any order' do
      expect_each(
        "<progressBar id='health' value='75' text='health 75%'/>"       => { id: 'health', value: 75, max: 100 },
        %(<progressBar id="health" value="75" text="health 75%"/>)      => { id: 'health', value: 75, max: 100 },
        "<progressBar value='75' id='health' text='health 75%'/>"       => { id: 'health', value: 75, max: 100 },
        "<progressBar id='health'  value='75' text='health 75%'/>"      => { id: 'health', value: 75, max: 100 },
        "<progressBar id='pbarStance' value='80'/>"                     => { id: 'stance', value: 80, max: 100 },
        "<progressBar id='encumlevel' value='20' text='Overloaded'/>"   => { id: 'encumbrance', value: 110, max: 110 },
        "<progressBar id='mindState' value='5' text='x'/>"              => { id: 'mind', value: 5, max: 110 },
        "<progressBar id='health' value='9' text='health 456/456'/>"    => { id: 'health', value: 456, max: 456 },
        # A value ends at its closing quote; what follows isn't an attribute.
        "<progressBar id='mindState' value='5' b' text='x'/>"           => nil,
        "<progressBar id='a' b' value='9' text='x 1/2'/>"               => nil,
        # Of two ids, the first counts.
        "<progressBar id='x' id='health' value='9' text='health 4/5'/>" => { id: 'x', value: 4, max: 5 }
      ) { |h, tag| events_of(h, tag, :progress_update).last }
    end

    it 'reads arbProgress attributes in either quotes and any order' do
      full = { id: 'bar', value: 5, max: 10, label: 'Foo', bg: ['red'], fg: ['blue'] }
      expect_each(
        "<arbProgress id='bar' max='10' current='5' label='Foo' colors='red,blue'/>" => full,
        %(<arbProgress id="bar" max='10' current='5'/>)                              => { id: 'bar', value: 5, max: 10 },
        "<arbProgress max='10' id='bar' current='5'/>"                               => { id: 'bar', value: 5, max: 10 },
        "<arbProgress id='bar' max='10' current='5' colors='red,blue' label='Foo'/>" => full,
        %(<arbProgress id='bar' max='10' current='5' label="Foo"/>)                  => { id: 'bar', value: 5, max: 10, label: 'Foo' },
        %(<arbProgress id='bar' max='10' current='5' colors="red,blue"/>)            => { id: 'bar', value: 5, max: 10, bg: ['red'], fg: ['blue'] },
        # An empty label is no label.
        "<arbProgress id='bar' max='10' current='5' label='' colors='red,blue'/>"    => { id: 'bar', value: 5, max: 10, bg: ['red'], fg: ['blue'] }
      ) { |h, tag| events_of(h, tag, :progress_update).last }
    end

    it 'reads the preset id in either quotes, among other attributes, but not self-closing' do
      PRESET['speech'] = ['aa', nil]
      PRESET["a'b"] = ['bb', nil]
      expect_each(
        "<preset id='speech'>"       => { start: 0, fg: 'aa', bg: nil },
        '<preset id="speech">'       => { start: 0, fg: 'aa', bg: nil },
        "<preset id='speech' x='1'>" => { start: 0, fg: 'aa', bg: nil },
        "<preset x='1' id='speech'>" => { start: 0, fg: 'aa', bg: nil },
        "<preset id='speech'/>"      => nil,
        "<preset id='a'b'>"          => { start: 0 }
      ) { |h, tag| h.dispatch_tag(tag, String.new).then { h.open_span(:preset) } }
    end

    it 'reads a stream id only from an attribute named id' do
      expect_each(
        "<pushStream id='combat'/>"                    => 'combat',
        '<pushStream id="combat"/>'                    => 'combat',
        "<pushStream x='1' id='combat'/>"              => 'combat',
        "<pushStream pid='combat'/>"                   => nil,
        "<component x-id='room objs' id='room desc'/>" => 'room desc',
        %(<compDef title="id='exp'" id='room'/>)       => 'room',
        "<pushStream junk id='combat'/>"               => nil
      ) { |h, tag| h.dispatch_tag(tag, String.new).then { h.current_stream } }
    end

    it 'reads a room subtitle only from an attribute named subtitle' do
      expect_each(
        "<component id='room' subtitle=' - [Hall]'/>"  => 'Hall',
        "<component subtitle=' - [Hall]' id='room'/>"  => 'Hall',
        "<component id='room' xsubtitle=' - [Hall]'/>" => ''
      ) { |h, tag| h.dispatch_tag(tag, String.new).then { h.state.room_title } }
    end

    it 'closes a named stream only for an attribute named id' do
      expect_each(
        "<popStream id='combat'/>"          => 'percWindow',
        %(<popStream id="combat"/>)         => 'percWindow',
        "<popStream x-id='combat'/>"        => 'combat',
        "<popStream pid='combat'/>"         => 'combat',
        %(<popStream title="id='combat'"/>) => 'combat'
      ) do |h, tag|
        %w[percWindow combat familiar].each { |id| h.dispatch_tag("<pushStream id='#{id}'/>", String.new) }
        h.dispatch_tag(tag, String.new)
        h.current_stream
      end
    end

    it 'clears the spell window only for an id of exactly percWindow' do
      expect_each(
        '<clearStream id="percWindow"/>'  => 1,
        "<clearStream id='percWindow'/>"  => 1,
        %(<clearStream id="percWindow'/>) => 0,
        "<clearStream xid='percWindow'/>" => 0,
        "<clearStream id='percWindowX'/>" => 0
      ) { |h, tag| events_of(h, tag, :clear_spells).size }
    end

    it 'reads color fg, bg and ul in either quotes and any order, lowercased' do
      expect_each(
        %(<color fg="FF0000" bg='00FF00' ul="true">) => { start: 0, fg: 'ff0000', bg: '00ff00', ul: 'true' },
        "<color bg='B' fg='A'>"                      => { start: 0, fg: 'a', bg: 'b' },
        "<color  fg='a'>"                            => { start: 0, fg: 'a' },
        "<color\tfg='a'>"                            => { start: 0, fg: 'a' },
        "<color fg=''>"                              => { start: 0, fg: '' },
        "<color fg='a>b'>"                           => { start: 0, fg: 'a>b' },
        %(<color fg="a'b">)                          => { start: 0, fg: "a'b" },
        "<color fg='a' fg='b'>"                      => { start: 0, fg: 'a' },
        "<color fg='x' />"                           => { start: 0, fg: 'x' },
        "<color xfg='a'>"                            => { start: 0 },
        %(<color fg="a'>)                            => { start: 0 },
        '<color fg=a>'                               => { start: 0 },
        # A value ends at its closing quote; what follows isn't an attribute.
        "<color fg='a'b'>"                           => { start: 0, fg: 'a' },
        "<color fg='a'b' bg='c'>"                    => { start: 0, fg: 'a' },
        "<color fg='a'x fg='b'>"                     => { start: 0, fg: 'a' },
        "<color fg='x'/>"                            => { start: 0, fg: 'x' },
        # Only attributes are read: not after junk, inside another value, or
        # after a longer element name.
        "<color junk fg='a'>"                        => { start: 0 },
        %(<color title=" fg='a' ">)                  => { start: 0 },
        "<color-x fg='a'>"                           => { start: 0 }
      ) { |h, tag| h.dispatch_tag(tag, String.new).then { h.open_span(:color) } }
    end

    it 'reads compass dirs from the dir tags inside the compass' do
      expect_each(
        %(<compass><dir value='a>b'/></compass>)              => ['a>b'],
        %(<compass><dir value='n'</compass>)                  => ['n'],
        %(<compass><dir-x value="n"/></compass>)              => [],
        %(<compass></dir value='n'></compass>)                => [],
        # not from a quoted value, or after an unclosed <
        %(<compass x="<dir value='n'/>"></compass>)           => [],
        %(<compass><b t='<dir value="n"/>'/></compass>)       => [],
        %(<compass><x <dir value='n'/></compass>)             => [],
        %(<compass><dir value="<dir value='n'/>"/></compass>) => []
      ) { |h, tag| events_of(h, tag, :compass_update).last[:dirs] }
    end

    it 'ends combat routing at a tag named popStream' do
      expect_each(
        '<popStream/>'              => false,
        "<popStream id='x'/>"       => false,
        '<popStream-x/>'            => false,
        '<popStreams id="combat"/>' => true,
        '</popStream>'              => true,
        '<pushStream/>'             => true
      ) do |h, tag|
        h.dispatch_tag("<pushStream id='combat'/>", String.new)
        h.dispatch_tag(tag, String.new)
        h.combat_routing?
      end
    end

    # Each row: the stream after the tag, then the stream a later push and
    # pop returns to (the combat push, if the tag left it open).
    it 'resyncs streams at a tag named prompt, not at its end tag' do
      expect_each(
        "<prompt time='1'>&gt;</prompt>" => [nil, nil],
        '<prompt>'                       => [nil, nil],
        '<prompt-x>'                     => [nil, nil],
        '<promptX>'                      => %w[combat combat],
        '</prompt>'                      => %w[combat combat]
      ) do |h, tag|
        h.dispatch_tag("<pushStream id='combat'/>", String.new)
        h.dispatch_tag(tag, String.new)
        after_tag = h.current_stream
        h.dispatch_tag("<pushStream id='thoughts'/>", String.new)
        h.dispatch_tag('<popStream/>', String.new)
        [after_tag, h.current_stream]
      end
    end

    # Each row: the stream after the tag, then the streams bare pops return
    # to on the way back to main (the pushStreams still open below it).
    it 'records only a pushStream as open, and closes one only at a popStream' do
      expect_each(
        "<pushStream id='a'/>"  => ['a', %w[x]],
        "<component id='a'/>"   => ['a', []],
        "<compDef id='a'/>"     => ['a', []],
        "<popStream id='x'/>"   => [nil, []],
        "<popStream-x id='x'/>" => [nil, []],
        '</component>'          => ['x', []],
        '</compDef>'            => ['x', []]
      ) do |h, tag|
        h.dispatch_tag("<pushStream id='x'/>", String.new)
        h.dispatch_tag(tag, String.new)
        [h.current_stream, streams_popped_back_to(h)]
      end
    end

    it 'reads a room streamWindow in either quotes and any order' do
      expect_each(
        %(<streamWindow id='room' subtitle=" - [Hall]"/>)              => 'Hall',
        %(<streamWindow id='room' title='Room' subtitle=' - [Hall]'/>) => 'Hall',
        %(<streamWindow id="room" subtitle=" - [Hall]"/>)              => 'Hall',
        %(<streamWindow subtitle=" - [Hall]" id='room'/>)              => 'Hall',
        %(<streamWindow id='room' xsubtitle=" - [Hall]"/>)             => '',
        %(<streamWindow id='room' title="subtitle=' - [Hall]'"/>)      => ''
      ) { |h, tag| h.dispatch_tag(tag, String.new).then { h.state.room_title } }
    end
  end

  # The text between tags is decoded before the tags that follow it take
  # their positions, so these go through GameTextProcessor#process_line into
  # the main window.
  describe 'entities in the text between tags' do
    # The map Application hands GameTextProcessor.
    let(:xml_escapes) { { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' } }
    # Color pair number per foreground color, so a cell's color can be read
    # back from its attributes.
    let(:pairs) { { 'ff0000' => 1 } }
    let(:main) { window_manager.stream['main'] }
    let(:processor) do
      GameTextProcessor.new(window_mgr: window_manager, shared_state: state, cmd_buffer: instance_double(CommandBuffer),
                            xml_escapes: xml_escapes, event_bus: event_bus)
    end

    before do
      LAYOUT['entities'] = REXML::Document.new(<<~XML).root
        <layout><window class='text' top='0' left='0' height='3' width='60' value='main'/></layout>
      XML
      window_manager.load_layout('entities')
      window_manager.subscribe_to_events(event_bus)
      allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    end

    # @return [Array<String, nil>] the foreground color of each cell of row +y+
    #   from column 0 up to +width+, nil where uncolored
    def colors_in_row(y, width)
      (0...width).map { |x| pairs.key(main.attrs_at(y, x) >> 8) }
    end

    it 'shows each entity as the character it stands for, wherever it is in the line' do
      processor.process_line('&lt;&gt; &lt;tag&gt; &amp; &quot;q&quot; &apos;a&apos; end&gt;')

      expect(main.rows.first).to eq %(<> <tag> & "q" 'a' end>)
    end

    it 'decodes one layer only, so &amp;lt; shows as &lt;' do
      processor.process_line('Type &amp;lt; or &amp;amp;.')

      expect(main.rows.first).to eq 'Type &lt; or &amp;.'
    end

    it 'colors the decoded text, not the length of its entities' do
      PRESET['monsterbold'] = ['ff0000', nil]

      processor.process_line('<pushBold/>a&lt;b<popBold/> cd')

      expect(main.rows.first).to eq 'a<b cd'
      expect(colors_in_row(0, 6)).to eq ['ff0000', 'ff0000', 'ff0000', nil, nil, nil]
    end
  end
end
