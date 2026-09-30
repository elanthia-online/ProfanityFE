# frozen_string_literal: true

# Tests what RoomAssembler hands the room window (and the room players
# indicator) for the inline room path: roomName/roomDesc styled text and
# the "You also see" / "Obvious paths:" lines, committed as one batch when
# the exits arrive. Every example reads the events the assembler emits,
# which is all the room window ever receives.
#
# The RoomWindow re-brackets whatever bare title it is handed (see
# RoomWindow#render: "[#{@title}]"), so the assembler must hand it a title
# with ITS OWN brackets already stripped. The tricky part is that the game's
# closing bracket appears in two shapes: "[Room] (230008)" (a RealID follows the
# bracket) and "[Room - 2071]" / "[Room]" (the bracket is trailing). Missing the
# trailing case leaves a stray "]" that render then doubles into "]]".

require_relative '../../lib/event_bus'
require_relative '../../lib/pending_render'
require_relative '../../lib/room_assembler'

RSpec.describe RoomAssembler do
  subject(:host) { assembler(room_windows: { 'room' => Object.new }) }

  let(:event_bus) { EventBus.new }
  let(:shared_state) { Struct.new(:room_title).new(nil) }
  # Every payload of each event the assembler emitted, oldest first.
  let(:emitted) { Hash.new { |hash, event| hash[event] = [] } }

  # The exits line that ends a room and commits what was staged for it.
  let(:exits_line) { 'Obvious paths: north.' }

  before do
    %i[room_title room_desc room_objects indicator_update].each do |event|
      event_bus.on(event) { |data| emitted[event] << data }
    end
  end

  # An assembler with only the collaborators the inline path touches: the
  # layout's room windows (the assembler only asks whether there is one)
  # and a writable room_title on shared state.
  #
  # @param room_windows [Hash] the window manager's room windows by id
  def assembler(room_windows:)
    described_class.new(window_mgr: Struct.new(:room).new(room_windows), event_bus: event_bus,
                        pending_render: PendingRender.new, shared_state: shared_state)
  end

  # Feed one server line the way the tag parser does: the raw line first,
  # then its text with the tags removed.
  def server_line(raw_line, text)
    host.line_started(raw_line)
    host.process_room_data(text, nil)
  end

  describe 'the room title' do
    # The title the room window is handed for roomName +text+, once the
    # exits commit the room.
    def title_shown_for(text)
      host.start_capture(:title)
      server_line(text, text)
      server_line(exits_line, exits_line)
      emitted[:room_title].last[:text]
    end

    it 'strips the brackets and keeps the RealID when the game appends one' do
      expect(title_shown_for('[Bosque Deriel, Hermit\'s Shacks] (230008)'))
        .to eq('Bosque Deriel, Hermit\'s Shacks (230008)')
    end

    it 'strips a trailing bracket when the title carries a lich id but no RealID' do
      # BUG (fixed): the old ".sub(/\\]\\s*\\(/, ' (')" only removed the bracket
      # before a "(", so "[Room - 2071]" kept its "]" and render produced "]]".
      expect(title_shown_for('[Bosque Deriel, Hermit\'s Shacks - 2071]'))
        .to eq('Bosque Deriel, Hermit\'s Shacks - 2071')
    end

    it 'strips a trailing bracket for a plain title with no id at all' do
      expect(title_shown_for('[Town Square]')).to eq('Town Square')
    end

    it 'keeps both the lich id and the RealID (GS-parity title from Lich)' do
      expect(title_shown_for('[Bosque Deriel, Hermit\'s Shacks - 2071] (230008)'))
        .to eq('Bosque Deriel, Hermit\'s Shacks - 2071 (230008)')
    end

    it 'leaves no bracket that RoomWindow#render would double into "]]"' do
      titles = %w([Room] [Room-2071] [Room](5)).map { |sample| title_shown_for(sample) }

      expect(titles).to eq ['Room', 'Room-2071', 'Room (5)']
    end

    it 'preserves interior punctuation while stripping only the outer brackets' do
      expect(title_shown_for('[Warrens, Alcove - 1234]')).to eq('Warrens, Alcove - 1234')
    end

    # The title still names the terminal title without a room window. It
    # must not be kept for the room window of a layout switched to later
    # (.layout), which would then show a room the player has left.
    it 'names the terminal title without a room window, and hands none to a room window added later' do
      room_windows = {}
      windowless = assembler(room_windows: room_windows)
      windowless.start_capture(:title)
      windowless.process_room_data('[Town Square]', nil)
      room_windows['room'] = Object.new

      windowless.process_room_data(exits_line, nil)

      expect(shared_state.room_title).to eq 'Town Square'
      expect(emitted[:room_title]).to be_empty
    end
  end

  describe 'the room description' do
    # The text the tag parser passes for the roomDesc line: its text with
    # the tags removed, which the room window gets when the raw line has
    # no roomDesc markers the assembler can read.
    let(:parser_text) { 'text from the tag parser' }

    # The description the room window is handed for a roomDesc capture on
    # +raw_line+, once the exits commit the room.
    def desc_shown_for(raw_line)
      host.start_capture(:desc)
      server_line(raw_line, parser_text)
      server_line(exits_line, exits_line)
      emitted[:room_desc].last
    end

    it 'reads it from roomDesc style and preset markers in either quotes, among other attributes' do
      fallback = parser_text
      {
        %(<style id="roomDesc"/>A <d>door</d>.<style id=""/> Obvious) => 'A door.',
        %(<style id='roomDesc'/>A room.<style id='' /> x)             => 'A room.',
        %(<style id='roomDesc' >A room.)                              => 'A room.',
        %(<style id="roomDesc'/>A room.)                              => fallback,
        %(<style id='roomDesc' x='1'/>A room.)                        => 'A room.',
        %(<style x='1' id='roomDesc'/>A room.)                        => 'A room.',
        %(<style id='roomDesc'/>)                                     => fallback,
        %(<style id='roomDesc'/><style id=''/>A room.)                => fallback,
        %(<style id='roomDesc'/>A room.<style id='' x='1'/> x)        => 'A room.',
        %(<preset id='roomDesc'>A room.</preset> x)                   => 'A room.',
        %(<preset id="roomDesc'>A room.</preset>)                     => fallback,
        %(<preset id='roomDesc'>A room.)                              => fallback,
        %(<preset id='roomDesc'/>A room.</preset>)                    => fallback,
        %(<preset id='roomDesc' x='1'>A room.</preset>)               => 'A room.',
        'A room.'                                                     => fallback
      }.each do |raw_line, desc|
        expect(desc_shown_for(raw_line)[:text]).to eq(desc), raw_line
      end
    end

    it 'keeps the links of the description read from the raw line' do
      shown = desc_shown_for(%(<style id="roomDesc"/>A <d cmd='go door'>door</d>.<style id=""/>))

      expect(shown).to eq(text: 'A door.', links: [{ start: 2, end: 6, cmd: 'go door' }])
    end
  end

  describe 'inline "You also see" objects' do
    # What the room window is handed for the objects on +raw_line+ (the
    # tag parser's text for it is always "You also see a box."), once the
    # exits commit the room.
    def objects_shown_for(raw_line)
      server_line(raw_line, 'You also see a box.')
      server_line(exits_line, exits_line)
      emitted[:room_objects].last
    end

    # The assembler strips component and compDef tags from the raw line
    # before handing it over, but the text then goes through the link
    # extractor, which drops every tag that isn't a link. So whether those
    # tags are stripped first can't be seen here, and no example pins it;
    # only a strip that cuts into the visible text shows (the quoted > row).
    it 'shows the text of the raw line from "You also see" on, with every tag removed' do
      {
        "<component id='room objs'>You also see a box.</component>" => 'You also see a box.',
        "You also see a box.</component><component id='x'>"         => 'You also see a box.',
        'You also see <pushBold/>a goblin<popBold/>.</component>'   => 'You also see a goblin.',
        'You also see <compass>x</compass>'                         => 'You also see x',
        # a > inside a quoted value stays inside its tag; a quoted value
        # can't hold a raw <, so that tag ends at the first > (see
        # XmlTokenizer::SINGLE_TAG_REGEX)
        %(You also see <component id="a>b">box</component>)         => 'You also see box',
        %(You also see <b t="<component id='x'>">box)               => %(You also see ">box)
      }.each do |raw_line, text|
        expect(objects_shown_for(raw_line)[:text]).to eq(text), raw_line
      end
    end

    it 'hands over the link regions of the objects\' link markup' do
      shown = objects_shown_for("You also see <a exist='1' noun='box'>a box</a> and " \
                                "<pushBold/><d cmd='look goblin'>a goblin</d><popBold/>.")

      expect(shown).to eq(text: 'You also see a box and a goblin.',
                          links: [{ start: 13, end: 18, cmd: 'look #1' }, { start: 23, end: 31, cmd: 'look goblin' }],
                          creatures: ['a goblin'])
    end

    it 'names as creatures the text of each <pushBold/>...<popBold/> region, tags removed' do
      {
        '<pushBold/>a goblin<popBold/>, <pushBold/>a troll<popBold/>'  => ['a goblin', 'a troll'],
        '<pushBold/>a goblin<popBold/>, <pushBold/>a goblin<popBold/>' => ['a goblin'],
        "<pushBold />a <d cmd='x'>goblin</d><popBold />"               => ['a goblin'],
        '<pushBold>a<popBold>'                                         => ['a'],
        '<pushBold/>a<pushBold/>b<popBold/>c<popBold/>'                => ['ab'],
        '<pushBold/><right>x</right><popBold/>'                        => ['x'],
        '<pushBold/>a'                                                 => [],
        '<popBold/>a<pushBold/><popBold/>'                             => [],
        # any tag the dispatcher reads as pushBold or popBold
        "<pushBold x='1'/>a goblin<popBold/>"                          => ['a goblin'],
        '<pushBold/ >a<popBold/>'                                      => ['a'],
        '<pushBold-x/>a<popBold/>'                                     => ['a'],
        # a > inside a quoted value stays inside its tag; <> is a tag
        "<pushBold/>a <b t='>'>b<popBold/>"                            => ['a b'],
        %(<pushBold/>a<b t="<popBold/>">b<popBold/>)                   => ['a">b'],
        '<pushBold/>a <> b<popBold/>'                                  => ['a  b']
      }.each do |objects_markup, creatures|
        raw_line = "You also see #{objects_markup}"
        expect(objects_shown_for(raw_line)[:creatures]).to eq(creatures), raw_line
      end
    end
  end

  describe 'the room players indicator' do
    # The label the room players indicator shows for an "Also here:" line.
    def indicator_label(text)
      host.update_room_players_indicator(text)
      emitted[:indicator_update].last[:label]
    end

    it 'keeps the last player when the line ends with a period' do
      expect(indicator_label('Also here: Bob and Alice.')).to eq 'Bob, Alice'
    end

    it 'keeps every player in a comma-separated list' do
      expect(indicator_label('Also here: Bob, Carol and Alice.')).to eq 'Bob, Carol, Alice'
    end

    it 'keeps a lone player followed by a period' do
      expect(indicator_label('Also here: Bob.')).to eq 'Bob'
    end

    it 'drops titles and status descriptions, keeping the bare name' do
      expect(indicator_label('Also here: Grand Lord Treeze who is sitting and Dark Summoner Vlachodimos.'))
        .to eq 'Treeze, Vlachodimos'
    end
  end
end
