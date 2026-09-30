# frozen_string_literal: true

# Tests TagHandlers, the tag parser GameTextProcessor includes, through the
# real client: each example sends server lines through GameTextProcessor#run
# into windows on the virtual screen, and checks what the user sees (the
# text each window shows, its colors and its links) or, for the tags that
# drive indicators, bars and countdowns, the events the processor emits for
# those windows.

require 'rexml/document'
require 'socket'
require_relative '../../lib/event_bus'
require_relative '../../lib/xml_tokenizer'
require_relative '../../lib/tag_handlers'
require_relative '../../lib/shared_state'
require_relative '../../lib/clock'
require_relative '../../lib/window_manager'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'

RSpec.describe TagHandlers do
  # The main window and a text window for each stream the examples route
  # to.
  let(:stream_windows) do
    <<~XML
      <layout>
        <window class='text' top='0' left='0' height='12' width='60' value='main'/>
        <window class='text' top='12' left='0' height='4' width='40' value='thoughts'/>
        <window class='text' top='12' left='40' height='4' width='40' value='combat'/>
        <window class='text' top='16' left='0' height='4' width='40' value='familiar'/>
        <window class='text' top='16' left='40' height='4' width='40' value='moonWindow'/>
        <window class='text' top='20' left='0' height='4' width='40' value='exp'/>
      </layout>
    XML
  end
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:client) { build_client(state: state) }

  # The [fg, bg] of each color pair the windows draw with, by pair number
  # (numbered as the windows ask for them), so a cell's colors can be read
  # back from its attributes.
  let(:color_pairs) { {} }

  before do
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, bg| color_pairs[[fg, bg]] ||= color_pairs.size + 1 }
    # No more server data is waiting after each line, so the reader flushes
    # the screen (and renders the room window) after every line.
    allow(IO).to receive(:select).and_return(nil)
    # A <LaunchURL> reaches the browser through the window manager's event
    # bridge: never open the user's browser from a spec.
    allow(UrlLauncher).to receive(:open)
    # The reader only logs a line it fails to process; fail the example.
    allow(ProfanityLog).to receive(:write) do |context, message, **|
      raise "#{context}: #{message}" if context == 'game_text_processor'
    end
  end

  # A client wired as Application wires one: a window manager with +layout+
  # showing the events of its own bus, and a processor reading server lines
  # into them.
  #
  # @return [Hash{Symbol => Object}] its +:window_manager+, +:event_bus+,
  #   +:state+ and +:processor+
  def build_client(state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
                   clock: Clock.new, layout: stream_windows)
    window_manager = WindowManager.new
    event_bus = EventBus.new
    LAYOUT['tags'] = REXML::Document.new(layout).root
    window_manager.load_layout('tags')
    window_manager.subscribe_to_events(event_bus)
    processor = GameTextProcessor.new(
      window_mgr: window_manager, shared_state: state, cmd_buffer: instance_double(CommandBuffer, window: nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus, clock: clock
    )
    { window_manager: window_manager, event_bus: event_bus, state: state, processor: processor }
  end

  # Send +lines+ from the game server and let the client read them all.
  def receive_from_server(*lines, into: client)
    client_end, server_end = UNIXSocket.pair
    server_end.write(lines.map { |line| "#{line}\r\n" }.join)
    server_end.close_write
    into[:processor].run(client_end)
  ensure
    client_end&.close
    server_end&.close
  end

  # @return [Hash{String => Array<String>}] the lines each window that
  #   shows any text shows, by its stream
  def screen(of: client)
    shown = of[:window_manager].stream.transform_values { |window| window.rows.reject(&:empty?) }
    shown.reject { |_stream, lines| lines.empty? }
  end

  # Each line a stream's window shows, as runs of text drawn alike: [text,
  # style], style nil for plain text, else the fg of its color pair,
  # 'on <bg>' and 'underlined' as they apply.
  #
  # @return [Array<Array(String, String)>] one list of runs per line
  def styled_lines(stream, of: client)
    window = of[:window_manager].stream[stream]
    window.rows.each_with_index.reject { |text, _y| text.empty? }.map do |text, y|
      runs_in(text) { |x| style_of(window.attrs_at(y, x)) }
    end
  end

  # Each line the main window shows, as runs of text that click the same
  # link: [text, command], nil where a click follows no link.
  def links_in_main
    window = client[:window_manager].stream['main']
    window.rows.each_with_index.reject { |text, _y| text.empty? }.map do |text, y|
      runs_in(text) { |x| window.link_cmd_at(y, x) }
    end
  end

  # +text+ cut into runs of the characters whose block value is the same.
  def runs_in(text)
    cells = text.each_char.with_index.map { |char, x| [char, yield(x)] }
    runs = cells.chunk_while { |(_, a), (_, b)| a == b }
    runs.map { |run| [run.map(&:first).join, run.first.last] }
  end

  # The style a cell was drawn in (see #styled_lines).
  def style_of(attrs)
    fg, bg = color_pairs.key((attrs & Curses::A_COLOR) >> 8)
    parts = [fg, ("on #{bg}" if bg), ('underlined' if attrs.anybits?(Curses::A_UNDERLINE))].compact
    parts.join(' ') unless parts.empty?
  end

  # @return [Array<Hash>] every event of +types+ emitted from now on, each
  #   with its +:type+
  def collect_events(*types, on: client)
    events = []
    types.each do |type|
      on[:event_bus].on(type) { |data| events << { type: type, **data } }
    end
    events
  end

  describe '#dispatch_tag' do
    it 'has a handler for every paired tag but inv, whose content is only swallowed' do
      expect(XmlTokenizer::PAIRED_TAGS - described_class::TAG_DISPATCH.keys).to eq ['inv']
    end
  end

  # After a combat stream, the text after a tag the parser doesn't know
  # goes to combat, until a popStream.
  describe 'combat routing' do
    # Combat routing on, and the thoughts component taking the text.
    let(:combat_then_thoughts) { %(<pushStream id="combat"/><component id='thoughts'>) }

    it 'shows the text before an unrecognized tag in its stream and the text after it in combat' do
      receive_from_server("#{combat_then_thoughts}You recall a song.<unknownTag/>The goblin lunges.")

      expect(screen).to eq('thoughts' => ['You recall a song.'], 'combat' => ['The goblin lunges.'])
    end

    it 'sends the text after an unrecognized tag to combat when no text came before it' do
      receive_from_server("#{combat_then_thoughts}<unknownTag/>The goblin lunges.")

      expect(screen).to eq('combat' => ['The goblin lunges.'])
    end

    it 'keeps the text in its stream at a tag it ignores on purpose, such as dialogdata' do
      receive_from_server(%(#{combat_then_thoughts}<dialogdata id="foo"/>You recall a song.))

      expect(screen).to eq('thoughts' => ['You recall a song.'])
    end

    it 'ends at a popStream naming combat, so the text after a later unrecognized tag shows in main' do
      receive_from_server('<pushStream id="combat"/><popStream id="combat"/><unknownTag/>A goblin arrives.')

      expect(screen).to eq('main' => ['A goblin arrives.'])
    end

    it 'ends at a popStream naming combat even while another stream is current' do
      receive_from_server(%(#{combat_then_thoughts}<popStream id="combat"/><unknownTag/>A goblin arrives.))

      expect(screen).to eq('main' => ['A goblin arrives.'])
    end
  end

  describe 'bold: <pushBold/> and <popBold/>, <b> and </b>' do
    before { PRESET['monsterbold'] = ['ff0000', nil] }

    it 'colors the text between them with the monsterbold preset' do
      receive_from_server('Hello <pushBold/>goblin<popBold/> flees')

      expect(styled_lines('main')).to eq [[['Hello ', nil], ['goblin', 'ff0000'], [' flees', nil]]]
    end

    it 'treats <b> and </b> the same way' do
      receive_from_server('A <b>bold</b> move')

      expect(styled_lines('main')).to eq [[['A ', nil], ['bold', 'ff0000'], [' move', nil]]]
    end

    it 'keeps the text after a nested bold in bold until the outer bold closes' do
      receive_from_server('<pushBold/>outer <pushBold/>inner<popBold/> outer<popBold/> plain')

      expect(styled_lines('main')).to eq [[['outer inner outer', 'ff0000'], [' plain', nil]]]
    end

    # The stream change hands the text before it to main with any bold
    # still open, so a bold the popBold left open would color that text.
    it 'leaves the text after a bold around no text plain' do
      receive_from_server('<pushBold/><popBold/>You see nothing.<pushStream id="thoughts"/>You recall a song.')

      expect(styled_lines('main')).to eq [[['You see nothing.', nil]]]
    end

    it 'leaves the text plain at a popBold with no bold open' do
      receive_from_server('plain<popBold/> text')

      expect(styled_lines('main')).to eq [[['plain text', nil]]]
    end
  end

  # A closing tag with nothing of its kind open changes nothing: the text
  # around it stays on one line, and the bold open around it still colors
  # all of 'goblin'.
  describe 'a stray closing tag' do
    before { PRESET['monsterbold'] = ['ff0000', nil] }

    let(:goblin_in_bold) { [[['Hello ', nil], ['goblin', 'ff0000'], [' flees', nil]]] }

    it 'leaves the line whole and the bold open at a stray </preset>' do
      receive_from_server('Hello <pushBold/>gob</preset>lin<popBold/> flees')

      expect(styled_lines('main')).to eq goblin_in_bold
    end

    it 'leaves the bold open at a stray </color>' do
      receive_from_server('Hello <pushBold/>gob</color>lin<popBold/> flees')

      expect(styled_lines('main')).to eq goblin_in_bold
    end

    it 'leaves the bold open at a stray </d>' do
      state.blue_links = true

      receive_from_server('Hello <pushBold/>gob</d>lin<popBold/> flees')

      expect(styled_lines('main')).to eq goblin_in_bold
      expect(links_in_main).to eq [[['Hello goblin flees', nil]]]
    end

    it 'leaves the bold open at a stray </a>' do
      state.blue_links = true

      receive_from_server('Hello <pushBold/>gob</a>lin<popBold/> flees')

      expect(styled_lines('main')).to eq goblin_in_bold
      expect(links_in_main).to eq [[['Hello goblin flees', nil]]]
    end
  end

  describe '<prompt>' do
    let(:prompt) { '<prompt time="1679000000">H&gt;</prompt>' }

    it 'sets the prompt text' do
      state.prompt_text = '>'

      receive_from_server(prompt)

      expect(state.prompt_text).to eq 'H>'
    end

    it 'sets the server time offset from the first prompt' do
      clock = Clock.new(now: -> { Time.at(1_679_000_010.5) })
      state.skip_server_time_offset = false

      receive_from_server(prompt, into: build_client(state: state, clock: clock))

      expect(state.skip_server_time_offset).to be true
      expect(clock.server_time_offset).to eq 10.5
    end

    it 'keeps the offset until a resync' do
      readings = [Time.at(1_679_000_010.5), Time.at(1_679_000_099.0)]
      clock = Clock.new(now: -> { readings.shift })
      state.skip_server_time_offset = false

      receive_from_server(prompt, '<prompt time="1679000001">H&gt;</prompt>', into: build_client(state: state, clock: clock))

      expect(clock.server_time_offset).to eq 10.5
    end

    it 'shows a new prompt in main and fits the prompt window to it' do
      events = collect_events(:prompt_changed)
      state.prompt_text = '>'

      receive_from_server(prompt)

      expect(screen).to eq('main' => ['H>'])
      expect(events).to eq [{ type: :prompt_changed, text: 'H>' }]
    end

    it 'shows nothing on a repeated prompt, and shows it in main at the next blank line' do
      state.prompt_text = 'H>'
      events = collect_events(:add_prompt, :prompt_changed)

      receive_from_server(prompt)

      expect(screen).to be_empty
      expect(events).to be_empty

      receive_from_server('')

      expect(screen).to eq('main' => ['H>'])
    end

    it 'puts a new prompt in the terminal title' do
      allow(Process).to receive(:setproctitle)
      allow($stdout).to receive(:write)
      state.char_name = 'Mahtra'

      receive_from_server(prompt)

      # OSC 0 sets the terminal title (a screen or tmux TERM appends the
      # window name after it).
      expect($stdout).to have_received(:write).with(a_string_starting_with("\e]0;Mahtra [H]\a"))
    end
  end

  describe '<spell>' do
    it 'shows the spell being prepared on the spell indicator' do
      events = collect_events(:indicator_update)

      receive_from_server('<spell>Fire Ball</spell>')

      expect(events).to eq [{ type: :indicator_update, id: 'spell', label: 'Fire Ball', value: 1 }]
    end

    it 'turns the spell indicator off for None' do
      events = collect_events(:indicator_update)

      receive_from_server('<spell>None</spell>')

      expect(events).to eq [{ type: :indicator_update, id: 'spell', label: 'None', value: 0 }]
    end

    it 'passes an empty spell name through as the label' do
      events = collect_events(:indicator_update)

      receive_from_server('<spell></spell>')

      expect(events).to eq [{ type: :indicator_update, id: 'spell', label: '', value: 1 }]
    end
  end

  describe '<right> and <left>' do
    it 'shows what the hand holds on its indicator' do
      events = collect_events(:indicator_update)

      receive_from_server('<right>a steel sword</right>')

      expect(events).to eq [{ type: :indicator_update, id: 'right', label: 'a steel sword', value: 1 }]
    end

    it 'turns the hand indicator off for Empty' do
      events = collect_events(:indicator_update)

      receive_from_server('<left>Empty</left>')

      expect(events).to eq [{ type: :indicator_update, id: 'left', label: 'Empty', value: 0 }]
    end
  end

  describe '<compass>' do
    it 'lists the directions of the room exits' do
      events = collect_events(:compass_update)

      receive_from_server('<compass><dir value="n"/><dir value="e"/></compass>')

      expect(events.last[:dirs]).to contain_exactly('n', 'e')
    end
  end

  describe '<roundTime> and <castTime>' do
    it 'sets the roundtime end time from <roundTime>' do
      events = collect_events(:countdown_update)

      receive_from_server("<roundTime value='1679000010'/>")

      expect(events).to eq [{ type: :countdown_update, id: 'roundtime', end_time: 1_679_000_010 }]
    end

    it 'sets the secondary end time from <castTime>' do
      events = collect_events(:countdown_update)

      receive_from_server("<castTime value='1679000020'/>")

      expect(events).to eq [{ type: :countdown_update, id: 'roundtime', secondary_end_time: 1_679_000_020 }]
    end
  end

  describe 'opening a stream: <pushStream>, <component>, <compDef>' do
    it 'shows the text before it in the stream it was on, and the text after it in the new stream' do
      receive_from_server('Text before the stream.<pushStream id="combat"/>A goblin lunges.')

      expect(screen).to eq('main' => ['Text before the stream.'], 'combat' => ['A goblin lunges.'])
    end

    it 'routes an exp stream to the exp window and names its skill' do
      events = collect_events(:exp_set_current)

      receive_from_server('<pushStream id="exp Athletics"/>Athletics: 5 34% clear')

      expect(screen).to eq('exp' => ['Athletics: 5 34% clear'])
      expect(events).to eq [{ type: :exp_set_current, skill: 'Athletics' }]
    end

    it 'takes the room title from the subtitle of a room component' do
      events = collect_events(:room_title)

      receive_from_server(%q{<component id="room" subtitle=" - [Town Square]"></component>})

      expect(events).to eq [{ type: :room_title, text: '[Town Square]' }]
      expect(state.room_title).to eq '[Town Square]'
    end

    it 'ignores a pushStream or component without an id, keeping the text around it on one line in main' do
      receive_from_server('Hello <component/>there<pushStream/> friend')

      expect(screen).to eq('main' => ['Hello there friend'])
    end

    it 'switches to each stream opened, even without a close between them' do
      receive_from_server('<pushStream id="combat"/>A goblin lunges.<pushStream id="thoughts"/>You recall a song.')

      expect(screen).to eq('combat' => ['A goblin lunges.'], 'thoughts' => ['You recall a song.'])
    end
  end

  describe 'closing a stream: <popStream>, </component>, </compDef>' do
    it 'shows the text before it in the stream, and the text after it in main' do
      receive_from_server('<pushStream id="combat"/>A goblin lunges.<popStream id="combat"/>You duck.')

      expect(screen).to eq('combat' => ['A goblin lunges.'], 'main' => ['You duck.'])
    end

    it 'closes the current exp skill when an exp component closes' do
      events = collect_events(:exp_delete_skill)

      receive_from_server("<component id='exp Athletics'></component>")

      expect(events).to eq [{ type: :exp_delete_skill }]
    end
  end

  # Only pushStream/popStream nest; a <prompt> closes anything left open.
  describe 'nested streams' do
    let(:prompt) { '<prompt time="1787778964">&gt;</prompt>' }

    it 'sends the outer stream the text that follows a nested push and pop' do
      receive_from_server('<pushStream id="combat"/><pushStream id="moonWindow"/>Katamba is up.<popStream/>' \
                          'The moradu staggers.<popStream id="combat"/>You feel fine.')

      expect(screen).to eq('moonWindow' => ['Katamba is up.'], 'combat' => ['The moradu staggers.'],
                           'main' => ['You feel fine.'])
    end

    it 'unwinds three levels one bare pop at a time' do
      receive_from_server('<pushStream id="thoughts"/><pushStream id="familiar"/><pushStream id="moonWindow"/>',
                          '<popStream/>Your familiar purrs.', '<popStream/>You recall a song.', '<popStream/>You duck.')

      expect(screen).to eq('familiar' => ['Your familiar purrs.'], 'thoughts' => ['You recall a song.'],
                           'main' => ['You duck.'])
    end

    it 'closes the named stream and anything opened after it on popStream id=' do
      receive_from_server('<pushStream id="thoughts"/><pushStream id="combat"/><pushStream id="moonWindow"/>',
                          '<popStream id="combat"/>You recall a song.', '<popStream/>You duck.')

      expect(screen).to eq('thoughts' => ['You recall a song.'], 'main' => ['You duck.'])
    end

    it 'closes the innermost stream with that id when the id is open twice' do
      receive_from_server('<pushStream id="familiar"/><pushStream id="thoughts"/><pushStream id="familiar"/>',
                          '<popStream id="familiar"/>You recall a song.')

      expect(screen).to eq('thoughts' => ['You recall a song.'])
    end

    it 'closes one level when popStream names a stream that is not open' do
      receive_from_server('<pushStream id="thoughts"/><pushStream id="familiar"/>',
                          '<popStream id="combat"/>You recall a song.')

      expect(screen).to eq('thoughts' => ['You recall a song.'])
    end

    it 'stays on main when a pop arrives with nothing open' do
      receive_from_server('<popStream/><popStream id="combat"/>You duck.')

      expect(screen).to eq('main' => ['You duck.'])
    end

    it 'handles the empath-touch double familiar push and double pop from a real log' do
      receive_from_server('<pushStream id="familiar"/><pushStream id="familiar" ifClosedStyle="watching"/>You touch Fidon.',
                          '<popStream/>Fidon is unhurt.', '<popStream/>You duck.')

      expect(screen).to eq('familiar' => ['You touch Fidon.', 'Fidon is unhurt.'], 'main' => ['You duck.'])
    end

    context 'with components' do
      it 'returns to the enclosing pushStream when a component closes inside it, leaving that push open' do
        receive_from_server("<pushStream id='familiar'/><component id='thoughts'>You recall a song.</component>" \
                            'Your familiar purrs.<popStream/>You duck.')

        expect(screen).to eq('thoughts' => ['You recall a song.'], 'familiar' => ['Your familiar purrs.'],
                             'main' => ['You duck.'])
      end

      it 'records nothing a later pop could return to for a self-closing component' do
        receive_from_server("<component id='familiar'/>Your familiar purrs.",
                            '<pushStream id="thoughts"/>You recall a song.<popStream/>You duck.')

        expect(screen).to eq('familiar' => ['Your familiar purrs.'], 'thoughts' => ['You recall a song.'],
                             'main' => ['You duck.'])
      end

      it 'records nothing a later pop could return to for a compDef pair' do
        receive_from_server("<pushStream id='thoughts'/><compDef id='exp Bow'></compDef>You recall a song.<popStream/>You duck.")

        expect(screen).to eq('thoughts' => ['You recall a song.'], 'main' => ['You duck.'])
      end
    end

    context 'at a <prompt>' do
      it 'sends text to main after a push that never got its pop' do
        receive_from_server('<pushStream id="moonWindow"/>', prompt, 'Katamba sets.<popStream/>')

        expect(screen).to eq('main' => ['>', 'Katamba sets.'])
      end

      it 'shows text collected for the stale stream in that stream first' do
        receive_from_server("<pushStream id='moonWindow'/>Katamba is rising.#{prompt}")

        # The prompt is unchanged, so it shows before the next text in main.
        expect(screen).to eq('moonWindow' => ['Katamba is rising.'])
      end

      it 'sends text to main after a self-closing component' do
        receive_from_server("<component id='familiar'/>", "#{prompt}You duck.")

        expect(screen).to eq('main' => ['>', 'You duck.'])
      end

      it 'ends combat routing left on by an unclosed combat push' do
        receive_from_server('<pushStream id="combat"/>', "#{prompt}<unknownTag/>A goblin arrives.")

        expect(screen).to eq('main' => ['>', 'A goblin arrives.'])
      end

      it 'keeps the text before the prompt on its line when no stream is open' do
        receive_from_server("Text before the prompt.#{prompt} after it.")

        expect(screen).to eq('main' => ['>', 'Text before the prompt. after it.'])
      end

      it 'does not stop a later push and pop from nesting' do
        receive_from_server('<pushStream id="moonWindow"/>', prompt,
                            '<pushStream id="thoughts"/><pushStream id="familiar"/><popStream/>You recall a song.<popStream/>You duck.')

        expect(screen).to eq('main' => ['>', 'You duck.'], 'thoughts' => ['You recall a song.'])
      end
    end

    context 'with a window for each of eleven streams' do
      let(:streams) { (1..11).map { |n| "s#{n}" } }
      let(:client) do
        windows = streams.each_with_index.map do |stream, column|
          "<window class='text' top='12' left='#{column * 7}' height='3' width='7' value='#{stream}'/>"
        end
        build_client(layout: <<~XML)
          <layout>
            <window class='text' top='0' left='0' height='12' width='60' value='main'/>
            #{windows.join("\n")}
          </layout>
        XML
      end

      it 'keeps only the 8 most recent unmatched pushes' do
        pops = (1..8).map { |n| "<popStream/>pop#{n}" }

        receive_from_server(streams.map { |stream| "<pushStream id='#{stream}'/>" }.join, *pops)

        # s11 was current; s1, s2 and s3 were dropped, so the 8th pop is back on main.
        expect(screen).to eq('s10' => ['pop1'], 's9' => ['pop2'], 's8' => ['pop3'], 's7' => ['pop4'],
                             's6' => ['pop5'], 's5' => ['pop6'], 's4' => ['pop7'], 'main' => ['pop8'])
      end
    end
  end

  describe '<color> and </color>' do
    it 'colors the text between them with the fg and bg it names' do
      receive_from_server('<color fg="ff0000" bg="000000">red on black</color> plain')

      expect(styled_lines('main')).to eq [[['red on black', 'ff0000 on 000000'], [' plain', nil]]]
    end

    it 'underlines the text between them for ul="true"' do
      receive_from_server('<color ul="true">underlined</color> plain')

      expect(styled_lines('main')).to eq [[['underlined', 'underlined'], [' plain', nil]]]
    end

    it 'colors back-to-back colors each over its own text' do
      receive_from_server('<color fg="ff0000">red</color><color fg="00ff00">green</color>')

      expect(styled_lines('main')).to eq [[%w[red ff0000], %w[green 00ff00]]]
    end
  end

  describe '<preset> and </preset>' do
    it 'colors the text between them with the preset' do
      PRESET['speech'] = ['00ff00', '000000']

      receive_from_server('<preset id="speech">Someone says hello</preset>, to you.')

      expect(styled_lines('main')).to eq [[['Someone says hello', '00ff00 on 000000'], [', to you.', nil]]]
    end

    it 'colors the text of nested presets each in its own color, back to the outer one after the inner closes' do
      PRESET['speech'] = ['00ff00', nil]
      PRESET['whisper'] = ['0000ff', nil]

      receive_from_server('<preset id="speech">outer <preset id="whisper">inner</preset> outer</preset>')

      expect(styled_lines('main')).to eq [[['outer ', '00ff00'], %w[inner 0000ff], [' outer', '00ff00']]]
    end

    it 'colors nothing for a preset id the settings do not define' do
      receive_from_server('<preset id="nonexistent">plain</preset> text')

      expect(styled_lines('main')).to eq [[['plain text', nil]]]
    end

    context 'with a room window' do
      let(:client) do
        build_client(state: state, layout: <<~XML)
          <layout>
            <window class='text' top='0' left='0' height='12' width='60' value='main'/>
            <window class='room' top='12' left='0' height='6' width='60'/>
          </layout>
        XML
      end

      it 'shows the text before a roomDesc preset on its own line, and the description in the room window' do
        receive_from_server("Text before the description.<preset id='roomDesc'>The square is busy.</preset>",
                            'Obvious paths: north.')

        room_window = client[:window_manager].room['room']
        expect(screen).to eq('main' => ['Text before the description.', 'The square is busy.', 'Obvious paths: north.'])
        expect(room_window.rows.reject(&:empty?)).to eq ['The square is busy.', 'Obvious paths: north.']
      end
    end
  end

  describe '<style>' do
    before { PRESET['roomName'] = ['00ff00', nil] }

    it 'colors a roomName style and takes the room title from it' do
      receive_from_server("<style id='roomName'/>[Town Square]<style id=''/>")

      expect(styled_lines('main')).to eq [[['[Town Square]', '00ff00']]]
      expect(state.room_title).to eq '[Town Square]'
    end

    it 'closes the style at a style with an empty id, showing the title on its own line' do
      receive_from_server("<style id='roomName'/>[Town Square]<style id=''/>A cat sleeps here.")

      expect(styled_lines('main')).to eq [[['[Town Square]', '00ff00']], [['A cat sleeps here.', nil]]]
      expect(state.room_title).to eq '[Town Square]'
    end

    it 'leaves an open style and its room title alone at a style without an id' do
      receive_from_server("<style id='roomName'/>[Town <style/>Square]<style id=''/>")

      expect(styled_lines('main')).to eq [[['[Town Square]', '00ff00']]]
      expect(state.room_title).to eq '[Town Square]'
    end
  end

  describe 'links: <d> and <a>' do
    before { state.blue_links = true }

    it 'follows the cmd attribute when the link text is clicked' do
      receive_from_server("Go through <d cmd='go door'>the door</d>.")

      expect(links_in_main).to eq [[['Go through ', nil], ['the door', 'go door'], ['.', nil]]]
    end

    it 'sends the link text as the command when there is no cmd attribute' do
      receive_from_server('Exits: <d>north</d>.')

      expect(links_in_main).to eq [[['Exits: ', nil], %w[north north], ['.', nil]]]
    end

    it 'looks at a GemStone <a> item by its exist id' do
      receive_from_server('<a exist="12345" noun="sword">a sword</a>')

      expect(links_in_main).to eq [[['a sword', 'look #12345']]]
    end

    it 'drags a GemStone <a> item with an exist id but no noun' do
      receive_from_server('<a exist="99999">an item</a>')

      expect(links_in_main).to eq [[['an item', '_drag #99999']]]
    end

    it 'keeps a cmd with special characters as sent' do
      receive_from_server("<d cmd='go #12345 door'>the door</d>")

      expect(links_in_main).to eq [[['the door', 'go #12345 door']]]
    end

    it 'makes nothing clickable or link-colored while links are off' do
      state.blue_links = false

      receive_from_server("<d cmd='go'>door</d>")

      expect(links_in_main).to eq [[['door', nil]]]
      expect(styled_lines('main')).to eq [[['door', nil]]]
    end
  end

  describe '<indicator>' do
    it 'turns the icon indicator on for a visible icon' do
      events = collect_events(:indicator_update)

      receive_from_server("<indicator id='IconSTUNNED' visible='y'/>")

      expect(events).to eq [{ type: :indicator_update, id: 'stunned', value: true }]
    end

    it 'turns the countdown of the same name on' do
      events = collect_events(:countdown_active)

      receive_from_server("<indicator id='IconSTUNNED' visible='y'/>")

      expect(events).to eq [{ type: :countdown_active, id: 'stunned', active: true }]
    end
  end

  describe '<image>' do
    it 'sets the nerve damage rank from an nsys image' do
      events = collect_events(:indicator_update)

      receive_from_server("<image id='nsys' name='nsys3'/>")

      expect(events).to eq [{ type: :indicator_update, id: 'nsys', value: 3 }]
    end

    it 'sets the injury level of a body part' do
      events = collect_events(:indicator_update)

      receive_from_server("<image id='chest' name='Injury2'/>")

      expect(events).to eq [{ type: :indicator_update, id: 'chest', value: 2 }]
    end
  end

  # UrlLauncher.open is stubbed for every example (see the top-level
  # before block), so these read what would have been opened from it.
  describe '<LaunchURL>' do
    it 'opens the src as a path on www.play.net in the browser' do
      events = collect_events(:launch_url)

      receive_from_server('<LaunchURL src="/path/to/page"/>')

      expect(events).to eq [{ type: :launch_url, url: 'https://www.play.net/path/to/page', remote: false }]
      expect(UrlLauncher).to have_received(:open).with('https://www.play.net/path/to/page').once
    end

    it 'ignores a src that turns play.net into userinfo for another host' do
      events = collect_events(:launch_url)

      receive_from_server('<LaunchURL src="@evil.example/x"/>')

      expect(events).to be_empty
      expect(UrlLauncher).not_to have_received(:open)
    end

    it 'ignores a src that extends the play.net host name' do
      events = collect_events(:launch_url)

      receive_from_server('<LaunchURL src=".evil.example/x"/>')

      expect(events).to be_empty
      expect(UrlLauncher).not_to have_received(:open)
    end
  end

  describe '<streamWindow>' do
    it 'takes the room title from the subtitle of the room streamWindow' do
      events = collect_events(:indicator_update, :room_title)

      receive_from_server(%q{<streamWindow id='room' subtitle=" - [Town Square]"/>})

      expect(state.room_title).to eq '[Town Square]'
      expect(events).to eq [{ type: :indicator_update, id: 'room', label: 'Town Square', value: 1 },
                            { type: :room_title, text: '[Town Square]' }]
    end

    it 'keeps the DragonRealms room number after the title' do
      receive_from_server(%q{<streamWindow id='room' subtitle=" - [Bosque Deriel] (230008)"/>})

      expect(state.room_title).to eq '[Bosque Deriel] (230008)'
    end

    it 'ignores a streamWindow other than room' do
      receive_from_server(%q{<streamWindow id='main' subtitle="test"/>})

      expect(state.room_title).to eq ''
    end
  end

  describe '<clearStream>' do
    it 'clears the spell window for percWindow' do
      events = collect_events(:clear_spells)

      receive_from_server('<clearStream id="percWindow"/>')

      expect(events).to eq [{ type: :clear_spells }]
    end

    it 'clears nothing for another stream' do
      events = collect_events(:clear_spells)

      receive_from_server('<clearStream id="other"/>')

      expect(events).to be_empty
    end
  end

  describe '<progressBar>' do
    it 'shows DragonRealms health at 0%' do
      events = collect_events(:progress_update)

      receive_from_server("<progressBar id='health' value='0' text='health 0%'/>")

      expect(events).to eq [{ type: :progress_update, id: 'health', value: 0, max: 100 }]
    end

    it 'fills the encumbrance bar past full for Overloaded' do
      events = collect_events(:progress_update)

      receive_from_server("<progressBar id='encumlevel' value='100' text='Overloaded'/>")

      expect(events).to eq [{ type: :progress_update, id: 'encumbrance', value: 110, max: 110 }]
    end

    it 'fills the mind bar past full for saturated' do
      events = collect_events(:progress_update)

      receive_from_server("<progressBar id='mindState' value='100' text='saturated'/>")

      expect(events).to eq [{ type: :progress_update, id: 'mind', value: 110, max: 110 }]
    end

    it 'shows a negative current GemStone vital' do
      events = collect_events(:progress_update)

      receive_from_server("<progressBar id='health' value='0' text='health -5/100'/>")

      expect(events).to eq [{ type: :progress_update, id: 'health', value: -5, max: 100 }]
    end

    it 'ignores a progressBar without a value, even when its text has numbers' do
      events = collect_events(:progress_update)

      receive_from_server("<progressBar id='health' text='health 456/456'/>")

      expect(events).to be_empty
    end
  end

  # Which spellings of each tag a handler accepts: quote style, attribute
  # order, spacing, attribute names that merely contain the one read, extra
  # attributes. Each row is what a new client does with a line holding that
  # exact tag. A failure lists every row that fails, not only the first.
  describe 'attribute acceptance', :aggregate_failures do
    # @param tags [Hash{String => Object}] tag => expected result
    # @yieldparam fresh [Hash] a new client for each tag (see #build_client)
    # @yieldparam tag [String] the tag
    # @yieldreturn [Object] what the client did with it
    def expect_each(tags)
      tags.each do |tag, expected|
        actual = yield(build_client, tag)
        expect(actual).to eq(expected), "#{tag} gave #{actual.inspect}, expected #{expected.inspect}"
      end
    end

    # @return [Array<Hash>] every event of +type+ emitted for a line holding +line+
    def events_of(fresh, line, type)
      events = collect_events(type, on: fresh)
      receive_from_server(line, into: fresh)
      events
    end

    # @return [Array<String>] the streams whose windows show text
    def windows_showing_text(fresh, *lines)
      receive_from_server(*lines, into: fresh)
      screen(of: fresh).keys
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
      ) { |fresh, tag| events_of(fresh, tag, :prompt_changed).last&.fetch(:text) }
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
      expect_each(tags.transform_keys { |t| t.gsub('TAG', 'roundTime') }) { |fresh, tag| events_of(fresh, tag, :countdown_update).last&.fetch(:end_time) }
      expect_each(tags.transform_keys { |t| t.gsub('TAG', 'castTime') }) { |fresh, tag| events_of(fresh, tag, :countdown_update).last&.fetch(:secondary_end_time) }
    end

    it 'reads the style id in either quotes, anywhere among the attributes, taking the room title only for roomName' do
      expect_each(
        "<style id='roomName'/>"       => '[Hall]',
        '<style id="roomName"/>'       => '[Hall]',
        "<style id='roomName' x='1'/>" => '[Hall]',
        "<style x='1' id='roomName'/>" => '[Hall]',
        "<style  id='roomName'/>"      => '[Hall]',
        "<style pid='roomName'/>"      => ''
      ) do |fresh, tag|
        receive_from_server("#{tag}[Hall]<style id=''/>", into: fresh)
        fresh[:state].room_title
      end
    end

    it 'reads LaunchURL src in either quotes, anywhere among the attributes' do
      expect_each(
        '<LaunchURL src="/p"/>'              => 'https://www.play.net/p',
        "<LaunchURL src='/p'/>"              => 'https://www.play.net/p',
        %(<LaunchURL x="1" src="/p"/>)       => 'https://www.play.net/p',
        '<LaunchURL  src="/p"/>'             => 'https://www.play.net/p',
        "<LaunchURL src='@evil.example/x'/>" => nil,
        '<LaunchURL src=""/>'                => nil
      ) { |fresh, tag| events_of(fresh, tag, :launch_url).last&.fetch(:url) }
    end

    # The compass draws each direction in its own place, so the order the
    # dirs arrive in is nothing the user sees: they are compared sorted.
    it 'reads compass dir values in either quotes, anywhere among the attributes' do
      expect_each(
        %(<compass><dir value="n"/><dir value="s"/></compass>)  => %w[n s],
        "<compass><dir value='n'/><dir value=\"s\"/></compass>" => %w[n s],
        %(<compass><dir x="1" value="n"/></compass>)            => %w[n],
        %(<compass><dir  value="n"/></compass>)                 => %w[n],
        %(<compass><dir value=""/></compass>)                   => [''],
        %(<compass><dirx value="n"/></compass>)                 => []
      ) { |fresh, tag| events_of(fresh, tag, :compass_update).last[:dirs].sort }
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
      ) { |fresh, tag| events_of(fresh, tag, :countdown_active).last&.values_at(:id, :active) }
    end

    it 'reads image id and name in either quotes and either order' do
      expect_each(
        "<image id='chest' name='Injury2'/>"  => ['chest', 2],
        %(<image id="chest" name='Injury2'/>) => ['chest', 2],
        "<image name='Injury2' id='chest'/>"  => ['chest', 2],
        "<image id='chest'  name='Injury2'/>" => ['chest', 2],
        "<image id='elbow' name='Injury2'/>"  => nil
      ) { |fresh, tag| events_of(fresh, tag, :indicator_update).last&.values_at(:id, :value) }
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
      ) { |fresh, tag| events_of(fresh, tag, :progress_update).last&.except(:type) }
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
      ) { |fresh, tag| events_of(fresh, tag, :progress_update).last&.except(:type) }
    end

    it 'reads the preset id in either quotes, among other attributes, but not self-closing' do
      PRESET['speech'] = ['aa', nil]
      PRESET["a'b"] = ['bb', nil]
      expect_each(
        "<preset id='speech'>"       => [%w[Hi aa]],
        '<preset id="speech">'       => [%w[Hi aa]],
        "<preset id='speech' x='1'>" => [%w[Hi aa]],
        "<preset x='1' id='speech'>" => [%w[Hi aa]],
        "<preset id='speech'/>"      => [['Hi', nil]],
        "<preset id='a'b'>"          => [['Hi', nil]]
      ) do |fresh, tag|
        receive_from_server("#{tag}Hi</preset>", into: fresh)
        styled_lines('main', of: fresh).first
      end
    end

    it 'reads a stream id only from an attribute named id' do
      expect_each(
        "<pushStream id='combat'/>"                     => %w[combat],
        '<pushStream id="combat"/>'                     => %w[combat],
        "<pushStream x='1' id='combat'/>"               => %w[combat],
        "<pushStream pid='combat'/>"                    => %w[main],
        "<component x-id='combat' id='thoughts'/>"      => %w[thoughts],
        %(<compDef title="id='combat'" id='thoughts'/>) => %w[thoughts],
        "<pushStream junk id='combat'/>"                => %w[main]
      ) { |fresh, tag| windows_showing_text(fresh, "#{tag}Some text.") }
    end

    it 'reads a room subtitle only from an attribute named subtitle' do
      expect_each(
        "<component id='room' subtitle=' - [Hall]'/>"  => '[Hall]',
        "<component subtitle=' - [Hall]' id='room'/>"  => '[Hall]',
        "<component id='room' xsubtitle=' - [Hall]'/>" => ''
      ) do |fresh, tag|
        receive_from_server(tag, into: fresh)
        fresh[:state].room_title
      end
    end

    it 'closes a named stream only for an attribute named id' do
      expect_each(
        "<popStream id='combat'/>"          => %w[thoughts],
        %(<popStream id="combat"/>)         => %w[thoughts],
        "<popStream x-id='combat'/>"        => %w[combat],
        "<popStream pid='combat'/>"         => %w[combat],
        %(<popStream title="id='combat'"/>) => %w[combat]
      ) do |fresh, tag|
        windows_showing_text(fresh, "<pushStream id='thoughts'/><pushStream id='combat'/><pushStream id='familiar'/>#{tag}Some text.")
      end
    end

    it 'clears the spell window only for an id of exactly percWindow' do
      expect_each(
        '<clearStream id="percWindow"/>'  => 1,
        "<clearStream id='percWindow'/>"  => 1,
        %(<clearStream id="percWindow'/>) => 0,
        "<clearStream xid='percWindow'/>" => 0,
        "<clearStream id='percWindowX'/>" => 0
      ) { |fresh, tag| events_of(fresh, tag, :clear_spells).size }
    end

    it 'reads color fg, bg and ul in either quotes and any order, lowercased' do
      expect_each(
        %(<color fg="FF0000" bg='00FF00' ul="true">) => [['Hi', 'ff0000 on 00ff00 underlined']],
        "<color bg='B' fg='A'>"                      => [['Hi', 'a on b']],
        "<color  fg='a'>"                            => [%w[Hi a]],
        "<color\tfg='a'>"                            => [%w[Hi a]],
        "<color fg=''>"                              => [['Hi', '']],
        "<color fg='a>b'>"                           => [['Hi', 'a>b']],
        %(<color fg="a'b">)                          => [['Hi', "a'b"]],
        "<color fg='a' fg='b'>"                      => [%w[Hi a]],
        "<color fg='x' />"                           => [%w[Hi x]],
        "<color xfg='a'>"                            => [['Hi', nil]],
        %(<color fg="a'>)                            => [['Hi', nil]],
        '<color fg=a>'                               => [['Hi', nil]],
        # A value ends at its closing quote; what follows isn't an attribute.
        "<color fg='a'b'>"                           => [%w[Hi a]],
        "<color fg='a'b' bg='c'>"                    => [%w[Hi a]],
        "<color fg='a'x fg='b'>"                     => [%w[Hi a]],
        "<color fg='x'/>"                            => [%w[Hi x]],
        # Only attributes are read: not after junk, inside another value, or
        # after a longer element name.
        "<color junk fg='a'>"                        => [['Hi', nil]],
        %(<color title=" fg='a' ">)                  => [['Hi', nil]],
        "<color-x fg='a'>"                           => [['Hi', nil]]
      ) do |fresh, tag|
        receive_from_server("#{tag}Hi</color>", into: fresh)
        styled_lines('main', of: fresh).first
      end
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
      ) { |fresh, tag| events_of(fresh, tag, :compass_update).last[:dirs] }
    end

    # Each row: where the text after an unrecognized tag goes, once the
    # thoughts component has the text: combat while combat routing is on,
    # thoughts once it ended.
    it 'ends combat routing at a tag named popStream' do
      expect_each(
        '<popStream/>'              => %w[thoughts],
        "<popStream id='x'/>"       => %w[thoughts],
        '<popStream-x/>'            => %w[thoughts],
        '<popStreams id="combat"/>' => %w[combat],
        '</popStream>'              => %w[combat],
        '<pushStream/>'             => %w[combat]
      ) do |fresh, tag|
        windows_showing_text(fresh, "<pushStream id='combat'/>#{tag}<component id='thoughts'><unknownTag/>Some text.")
      end
    end

    # Each row: the windows showing the text after the tag and the text
    # after a later push and pop (back on the combat push, if the tag left
    # it open).
    it 'resyncs streams at a tag named prompt, not at its end tag' do
      expect_each(
        "<prompt time='1'>&gt;</prompt>" => { 'main' => ['>', 'After the tag.', 'After the pop.'], 'thoughts' => ['You recall a song.'] },
        '<prompt>'                       => { 'main' => ['After the tag.', 'After the pop.'], 'thoughts' => ['You recall a song.'] },
        '<prompt-x>'                     => { 'main' => ['After the tag.', 'After the pop.'], 'thoughts' => ['You recall a song.'] },
        '<promptX>'                      => { 'combat' => ['After the tag.', 'After the pop.'], 'thoughts' => ['You recall a song.'] },
        '</prompt>'                      => { 'combat' => ['After the tag.', 'After the pop.'], 'thoughts' => ['You recall a song.'] }
      ) do |fresh, tag|
        receive_from_server("<pushStream id='combat'/>#{tag}After the tag.",
                            "<pushStream id='thoughts'/>You recall a song.<popStream/>After the pop.", into: fresh)
        screen(of: fresh)
      end
    end

    # Each row: the windows showing the text after the tag and the text
    # after a later bare pop (back on the thoughts push, if the tag left it
    # open below a new push).
    it 'records only a pushStream as open, and closes one only at a popStream' do
      expect_each(
        "<pushStream id='familiar'/>"  => { 'familiar' => ['After the tag.'], 'thoughts' => ['After the pop.'] },
        "<component id='familiar'/>"   => { 'familiar' => ['After the tag.'], 'main' => ['After the pop.'] },
        "<compDef id='familiar'/>"     => { 'familiar' => ['After the tag.'], 'main' => ['After the pop.'] },
        "<popStream id='thoughts'/>"   => { 'main' => ['After the tag.', 'After the pop.'] },
        "<popStream-x id='thoughts'/>" => { 'main' => ['After the tag.', 'After the pop.'] },
        '</component>'                 => { 'thoughts' => ['After the tag.'], 'main' => ['After the pop.'] },
        '</compDef>'                   => { 'thoughts' => ['After the tag.'], 'main' => ['After the pop.'] }
      ) do |fresh, tag|
        receive_from_server("<pushStream id='thoughts'/>#{tag}After the tag.<popStream/>After the pop.", into: fresh)
        screen(of: fresh)
      end
    end

    it 'reads a room streamWindow in either quotes and any order' do
      expect_each(
        %(<streamWindow id='room' subtitle=" - [Hall]"/>)              => '[Hall]',
        %(<streamWindow id='room' title='Room' subtitle=' - [Hall]'/>) => '[Hall]',
        %(<streamWindow id="room" subtitle=" - [Hall]"/>)              => '[Hall]',
        %(<streamWindow subtitle=" - [Hall]" id='room'/>)              => '[Hall]',
        %(<streamWindow id='room' xsubtitle=" - [Hall]"/>)             => '',
        %(<streamWindow id='room' title="subtitle=' - [Hall]'"/>)      => ''
      ) do |fresh, tag|
        receive_from_server(tag, into: fresh)
        fresh[:state].room_title
      end
    end
  end

  # The text between tags is decoded before the tags that follow it take
  # their positions.
  describe 'entities in the text between tags' do
    it 'shows each entity as the character it stands for, wherever it is in the line' do
      receive_from_server('&lt;&gt; &lt;tag&gt; &amp; &quot;q&quot; &apos;a&apos; end&gt;')

      expect(screen).to eq('main' => [%(<> <tag> & "q" 'a' end>)])
    end

    it 'decodes one layer only, so &amp;lt; shows as &lt;' do
      receive_from_server('Type &amp;lt; or &amp;amp;.')

      expect(screen).to eq('main' => ['Type &lt; or &amp;.'])
    end

    it 'colors the decoded text, not the length of its entities' do
      PRESET['monsterbold'] = ['ff0000', nil]

      receive_from_server('<pushBold/>a&lt;b<popBold/> cd')

      expect(styled_lines('main')).to eq [[['a<b', 'ff0000'], [' cd', nil]]]
    end
  end
end
