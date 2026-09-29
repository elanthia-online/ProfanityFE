# frozen_string_literal: true

# Tests RoomAssembler#process_room_data's room-title capture (the :title mode).
#
# The RoomWindow re-brackets whatever bare title it is handed (see
# RoomWindow#render: "[#{@title}]"), so process_room_data must hand it a title
# with ITS OWN brackets already stripped. The tricky part is that the game's
# closing bracket appears in two shapes: "[Room] (230008)" (a RealID follows the
# bracket) and "[Room - 2071]" / "[Room]" (the bracket is trailing). Missing the
# trailing case leaves a stray "]" that render then doubles into "]]".

require_relative '../../lib/event_bus'
require_relative '../../lib/pending_render'
require_relative '../../lib/room_assembler'

RSpec.describe RoomAssembler do
  # An assembler with only the collaborators #process_room_data touches in
  # :title mode: a room-window presence check and a writable room_title on
  # shared state.
  #
  # @param has_room_window [Boolean] whether the layout has a RoomWindow (only
  #   then is the pending title captured)
  def assembler(has_room_window: true)
    described_class.new(window_mgr: Struct.new(:room).new(has_room_window ? { 'room' => Object.new } : {}),
                        event_bus: EventBus.new, pending_render: PendingRender.new,
                        shared_state: Struct.new(:room_title).new(nil))
  end

  describe '#process_room_data room title capture (:title mode)' do
    subject(:host) { assembler }

    # Captures the bare (bracket-stripped) title RoomWindow#render will re-bracket.
    # @param text [String] the roomName styled text as sent by the game/Lich
    # @return [String, nil] the captured pending title
    def capture(text)
      host.start_capture(:title)
      host.process_room_data(text, nil)
      host.instance_variable_get(:@room_pending_title)
    end

    it 'strips the brackets and keeps the RealID when the game appends one' do
      expect(capture('[Bosque Deriel, Hermit\'s Shacks] (230008)'))
        .to eq('Bosque Deriel, Hermit\'s Shacks (230008)')
    end

    it 'strips a trailing bracket when the title carries a lich id but no RealID' do
      # BUG (fixed): the old ".sub(/\\]\\s*\\(/, ' (')" only removed the bracket
      # before a "(", so "[Room - 2071]" kept its "]" and render produced "]]".
      expect(capture('[Bosque Deriel, Hermit\'s Shacks - 2071]'))
        .to eq('Bosque Deriel, Hermit\'s Shacks - 2071')
    end

    it 'strips a trailing bracket for a plain title with no id at all' do
      expect(capture('[Town Square]')).to eq('Town Square')
    end

    it 'keeps both the lich id and the RealID (GS-parity title from Lich)' do
      expect(capture('[Bosque Deriel, Hermit\'s Shacks - 2071] (230008)'))
        .to eq('Bosque Deriel, Hermit\'s Shacks - 2071 (230008)')
    end

    it 'leaves no bracket that RoomWindow#render would double into "]]"' do
      %w([Room] [Room-2071] [Room](5)).each do |sample|
        expect(capture(sample)).not_to include(']')
      end
    end

    it 'preserves interior punctuation while stripping only the outer brackets' do
      expect(capture('[Warrens, Alcove - 1234]')).to eq('Warrens, Alcove - 1234')
    end

    it 'does not capture a pending title when the layout has no RoomWindow' do
      windowless = assembler(has_room_window: false)
      windowless.start_capture(:title)
      windowless.process_room_data('[Town Square]', nil)
      expect(windowless.instance_variable_get(:@room_pending_title)).to be_nil
    end
  end

  describe '#extract_styled_desc' do
    subject(:host) { assembler }

    # Which spellings of the roomDesc markers are found in a raw line.
    it 'finds roomDesc style and preset markers in either quotes, among other attributes' do
      {
        %(<style id="roomDesc"/>A <d>door</d>.<style id=""/> Obvious) => 'A <d>door</d>.',
        %(<style id='roomDesc'/>A room.<style id='' /> x)             => 'A room.',
        %(<style id='roomDesc' >A room.)                              => 'A room.',
        %(<style id="roomDesc'/>A room.)                              => nil,
        %(<style id='roomDesc' x='1'/>A room.)                        => 'A room.',
        %(<style x='1' id='roomDesc'/>A room.)                        => 'A room.',
        %(<style id='roomDesc'/>)                                     => nil,
        %(<style id='roomDesc'/><style id=''/>A room.)                => nil,
        %(<style id='roomDesc'/>A room.<style id='' x='1'/> x)        => 'A room.',
        %(<preset id='roomDesc'>A room.</preset> x)                   => 'A room.',
        %(<preset id="roomDesc'>A room.</preset>)                     => nil,
        %(<preset id='roomDesc'>A room.)                              => nil,
        %(<preset id='roomDesc'/>A room.</preset>)                    => nil,
        %(<preset id='roomDesc' x='1'>A room.</preset>)               => 'A room.',
        'A room.'                                                     => nil
      }.each do |line, desc|
        expect(host.send(:extract_styled_desc, line)).to eq(desc), line
      end
    end
  end

  describe 'inline "You also see" objects' do
    subject(:host) { assembler }

    # @param raw_line [String] the raw server line the objects text came from
    # @return [String] the objects markup kept for the room window
    def objects(raw_line)
      host.line_started(raw_line)
      host.process_room_data('You also see a box.', nil)
      host.instance_variable_get(:@room_pending_objects)
    end

    it 'drops component and compDef tags, and keeps every other tag' do
      {
        "<component id='room objs'>You also see a box.</component>" => 'You also see a box.',
        "You also see a box.</component><component id='x'>"         => 'You also see a box.',
        'You also see <pushBold/>a goblin<popBold/>.</component>'   => 'You also see <pushBold/>a goblin<popBold/>.',
        'You also see <compass>x</compass>'                         => 'You also see <compass>x</compass>',
        'You also see a </compDef >box<compDefs/>.'                 => 'You also see a box<compDefs/>.',
        # only tags named exactly component or compDef
        'You also see a <componentX>box</componentX>.'              => 'You also see a <componentX>box</componentX>.',
        # a > inside a quoted value stays inside its tag, and a tag's quoted
        # value is part of the tag
        %(You also see <component id="a>b">box</component>)         => 'You also see box',
        %(You also see <b t="<component id='x'>">box)               => %(You also see <b t="<component id='x'>">box)
      }.each do |raw, expected|
        expect(objects(raw)).to eq(expected), raw
      end
    end
  end

  describe '#extract_inline_creatures' do
    subject(:host) { assembler }

    it 'reads the text of each <pushBold/>...<popBold/> region, tags removed' do
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
      }.each do |raw, expected|
        expect(host.send(:extract_inline_creatures, raw)).to eq(expected), raw
      end
    end
  end

  describe '#structurize_text' do
    subject(:host) { assembler }

    it 'reads a player list with link markup into text and link regions' do
      text = "Also here: <a exist='1' noun='Bob'>Bob</a> and <pushBold/><d cmd='look Al'>Al</d><popBold/>."
      expect(host.send(:structurize_text, text))
        .to eq ['Also here: Bob and Al.', [{ start: 11, end: 14, cmd: 'look #1' }, { start: 19, end: 21, cmd: 'look Al' }]]
    end
  end

  describe '#parse_player_names' do
    subject(:host) { assembler }

    # @param text [String] an "Also here: ..." line
    # @return [Array<String>] the names the room-players indicator shows
    def names(text) = host.send(:parse_player_names, text)

    it 'keeps the last player when the line ends with a period' do
      expect(names('Also here: Bob and Alice.')).to eq %w[Bob Alice]
    end

    it 'keeps every player in a comma-separated list' do
      expect(names('Also here: Bob, Carol and Alice.')).to eq %w[Bob Carol Alice]
    end

    it 'keeps a lone player followed by a period' do
      expect(names('Also here: Bob.')).to eq %w[Bob]
    end

    it 'drops titles and status descriptions, keeping the bare name' do
      expect(names('Also here: Grand Lord Treeze who is sitting and Dark Summoner Vlachodimos.'))
        .to eq %w[Treeze Vlachodimos]
    end
  end
end
