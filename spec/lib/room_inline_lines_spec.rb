# frozen_string_literal: true

# What the room window shows for the inline room lines: the roomName
# style's title, the roomDesc style's or preset's description and the
# "You also see" objects, committed with the room at the "Obvious paths:"
# line. The lines go through the real server loop (GameTextProcessor#run)
# into windows built from layout XML; the assertions read the room
# window's rows, the colors of its cells and the command a click on each
# sends (RoomWindow#link_cmd_at), and the terminal title
# (SharedState#room_title).
#
# These examples were unit examples of RoomAssembler fed a raw line and a
# made-up parsed text. The tag parser now gives the text, as it does for
# the user, so each shows what a real line gives.
#
# The room window shows the title it is handed as it is (see RoomTitle):
# the name in its brackets and whatever the game sent after the closing
# bracket. The game's closing bracket appears in two shapes: "[Room]
# (230008)" (a RealID follows the bracket) and "[Room - 2071]" / "[Room]"
# (the bracket is trailing); neither may lose or double a bracket.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Inline room lines' do
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  # Color pair number per foreground color: ff0000 is the monsterbold
  # color below, 5555ff the color links are drawn in without a 'links'
  # preset.
  let(:pairs) { { 'ff0000' => 1, '5555ff' => 2 } }
  # The exits line that ends a room and commits what was staged for it.
  let(:exits_line) { 'Obvious paths: north.' }

  before do
    allow(IO).to receive(:select).and_return(nil)
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, _bg| pairs.fetch(fg, 0) }
    PRESET['monsterbold'] = ['ff0000', nil]
    state.blue_links = true
    load_layout
  end

  # Build the windows from layout XML and a processor that feeds them.
  #
  # @param room_window [Boolean] whether the layout has a room window
  def load_layout(room_window: true)
    define_layout('inline-lines', room_window: room_window)
    event_bus = EventBus.new
    @window_manager = WindowManager.new(shared_state: state)
    @window_manager.load_layout('inline-lines')
    @window_manager.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @window_manager, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # A layout named +name+: a main window, and a room window if asked.
  def define_layout(name, room_window:)
    LAYOUT[name] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='10' width='100' value='main'/>
        #{"<window class='room' top='10' left='0' height='10' width='100' value='room'/>" if room_window}
      </layout>
    XML
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would. The first prompt sends a LOOK to the server, which takes it.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |_command| nil }
    server.define_singleton_method(:flush) { nil }
    @processor.run(server)
  end

  def room = @window_manager.room['room']

  # The room window's rows, blank rows and trailing blanks left out.
  def room_rows = room.rows.map(&:rstrip).reject(&:empty?)

  # The main window's rows, blank rows and trailing blanks left out.
  def main_rows = @window_manager.stream['main'].rows.map(&:rstrip).reject(&:empty?)

  # The room window's row showing +text+, and the column it starts at.
  def locate(text)
    y = room.rows.index { |row| row.include?(text) }
    raise "#{text.inspect} not shown: #{room_rows.inspect}" unless y

    [y, room.row(y).index(text)]
  end

  # The words of the room window's row starting with +prefix+ that are
  # drawn in the monsterbold color, each run of such cells as one string.
  def red_runs(prefix)
    y, = locate(prefix)
    row = room.row(y)
    row.each_char.with_index.chunk_while { |(_, a), (_, b)| red?(y, a) == red?(y, b) }
                            .select { |chars| red?(y, chars.first.last) }
                            .map { |chars| chars.map(&:first).join }
  end

  def red?(y, x) = room.attrs_at(y, x) >> 8 == 1

  # The command a click on each character of +text+ sends, without repeats.
  def commands_under(text)
    command_runs(text).uniq
  end

  # The command a click on each character of +text+ sends, once for each
  # run of characters that send the same one.
  def command_runs(text)
    y, x = locate(text)
    (x...(x + text.length)).map { |col| room.link_cmd_at(y, col) }.chunk_while { |a, b| a == b }.map(&:first)
  end

  describe 'the room title' do
    # The title row the room window shows for roomName +text+, once the
    # exits commit the room.
    def title_shown_for(text)
      receive_from_server(%(<style id="roomName" />#{text}), exits_line)
      room_rows.first
    end

    it 'keeps the brackets and the RealID when the game appends one' do
      expect(title_shown_for("[Bosque Deriel, Hermit's Shacks] (230008)")).to eq("[Bosque Deriel, Hermit's Shacks] (230008)")
    end

    it 'keeps one closing bracket when the title carries a lich id but no RealID' do
      # BUG (fixed): an old bracket strip only removed the bracket before a
      # "(", so "[Room - 2071]" kept its "]" and the window showed "]]".
      expect(title_shown_for("[Bosque Deriel, Hermit's Shacks - 2071]")).to eq("[Bosque Deriel, Hermit's Shacks - 2071]")
    end

    it 'keeps a plain title with no id at all as it is' do
      expect(title_shown_for('[Town Square]')).to eq('[Town Square]')
    end

    it 'keeps both the lich id and the RealID (GS-parity title from Lich)' do
      expect(title_shown_for("[Bosque Deriel, Hermit's Shacks - 2071] (230008)"))
        .to eq("[Bosque Deriel, Hermit's Shacks - 2071] (230008)")
    end

    it 'neither doubles nor drops a bracket' do
      titles = %w([Room] [Room-2071] [Room](5)).map do |sample|
        load_layout
        title_shown_for(sample)
      end

      expect(titles).to eq ['[Room]', '[Room-2071]', '[Room](5)']
    end

    it 'preserves interior punctuation' do
      expect(title_shown_for('[Warrens, Alcove - 1234]')).to eq('[Warrens, Alcove - 1234]')
    end

    # The title still names the terminal title without a room window. It
    # must not be kept for the room window of a layout switched to later
    # (.layout), which would then show a room the player has left.
    it 'names the terminal title without a room window, and hands none to a room window added later' do
      load_layout(room_window: false)
      receive_from_server('<style id="roomName" />[Town Square]')
      define_layout('with-room', room_window: true)
      @window_manager.load_layout('with-room')

      receive_from_server(exits_line)

      expect(state.room_title).to eq 'Town Square'
      expect(room_rows).to eq [exits_line]
    end
  end

  describe 'the room description' do
    # The description row(s) the room window shows for +line+ (a roomDesc
    # line), once the exits commit the room: the rows above the exits.
    def desc_shown_for(line)
      load_layout
      receive_from_server(line, exits_line)
      room_rows[0...-1]
    end

    it 'reads it from roomDesc style and preset markers in either quotes, among other attributes' do
      shown = {
        %(<style id="roomDesc"/>A <d>door</d>.<style id=""/> Obvious) => ['A door.'],
        %(<style id='roomDesc'/>A room.<style id='' /> x)             => ['A room.'],
        %(<style id='roomDesc' >A room.)                              => ['A room.'],
        %(<style id='roomDesc' x='1'/>A room.)                        => ['A room.'],
        %(<style x='1' id='roomDesc'/>A room.)                        => ['A room.'],
        %(<style id='roomDesc'/>A room.<style id='' x='1'/> x)        => ['A room.'],
        %(<preset id='roomDesc'>A room.</preset> x)                   => ['A room.'],
        %(<preset id='roomDesc' x='1'>A room.</preset>)               => ['A room.'],
        # a preset left open still ends the capture at the line's text
        %(<preset id='roomDesc'>A room.)                              => ['A room.'],
        # a style with no text on its line takes the next line's text
        %(<style id='roomDesc'/>)                                     => [exits_line]
      }
      expect(shown.keys.to_h { |line| [line, desc_shown_for(line)] }).to eq shown
    end

    it 'shows no description for markers the tag parser does not read as a roomDesc, or with no text' do
      lines = [
        %(<style id="roomDesc'/>A room.),
        %(<style id='roomDesc'/><style id=''/>A room.),
        %(<preset id="roomDesc'>A room.</preset>),
        %(<preset id='roomDesc'/>A room.</preset>),
        'A room.'
      ]
      expect(lines.to_h { |line| [line, desc_shown_for(line)] }).to eq(lines.to_h { |line| [line, []] })
    end

    it 'keeps the links of the description' do
      desc_shown_for(%(<style id="roomDesc"/>A <d cmd='go door'>door</d>.<style id=""/>))

      expect(room_rows.first).to eq 'A door.'
      expect(commands_under('door')).to eq ['go door']
      expect(commands_under('A ')).to eq [nil]
    end

    it 'keeps the links of a description after other text on its line, and not the links before it' do
      desc_shown_for(%(Before <d cmd='x'>x</d>. <style id="roomDesc"/>A <d cmd='go door'>door</d>.<style id=""/>))

      expect(room_rows.first).to eq 'A door.'
      expect(command_runs('A door.')).to eq [nil, 'go door', nil]
      expect(main_rows.first).to eq 'Before x. A door.'
    end

    # Characterization: a link that opens before the roomDesc style is not
    # the description's, even where it goes on into it.
    it 'shows no link that opens before the roomDesc style' do
      desc_shown_for(%(<d cmd='look x'>X <style id="roomDesc"/>dark</d> room.<style id=""/>))

      expect(room_rows.first).to eq 'dark room.'
      expect(commands_under('dark room.')).to eq [nil]
      expect(main_rows.first).to eq 'X dark room.'
    end

    it 'decodes entities in the description' do
      desc_shown_for(%(<preset id='roomDesc'>A &lt;red&gt; door &amp; a gate.</preset>))

      expect(room_rows.first).to eq 'A <red> door & a gate.'
    end

    it 'pairs nested links in the description by nesting, the innermost winning' do
      desc_shown_for(%(<preset id='roomDesc'>A <d cmd='a'>x<d cmd='b'>y</d>z</d>.</preset>))

      expect(command_runs('xyz')).to eq %w[a b a]
    end

    # Characterization: a roomDesc style with no text of its own takes the
    # text before it on its line, as the description always has then.
    it 'takes the text before a roomDesc style that has no text of its own' do
      desc_shown_for(%(Before <style id="roomDesc"/><style id=""/>))

      expect(room_rows.first).to eq 'Before'
    end

    # Characterization: a roomDesc style whose own text is only spaces
    # shows no description (the text before it stays in main).
    it 'shows no description for a roomDesc style whose own text is only spaces' do
      expect(desc_shown_for(%(Before <style id="roomDesc"/> <style id=""/>))).to eq []
      expect(main_rows.first).to eq 'Before'
    end
  end

  describe 'inline "You also see" objects' do
    # The objects row the room window shows for the objects line +line+
    # after a roomName, once the exits commit the room.
    def objects_shown_for(line)
      load_layout
      receive_from_server('<style id="roomName" />[A]', line, exits_line)
      room_rows[1]
    end

    it "shows the line's text, tags removed" do
      shown = {
        'You also see <pushBold/>a goblin<popBold/>.</component>' => 'You also see a goblin.',
        "You also see a box.<component id='x'></component>"       => 'You also see a box.',
        # a > inside a quoted value stays inside its tag; a quoted value
        # can't hold a raw <, so that tag ends at the first > (see
        # XmlTokenizer::SINGLE_TAG_REGEX)
        %(You also see <b t="<component id='x'>">box)             => %(You also see ">box),
        'You also see <pushBold/>a <> b<popBold/>'                => 'You also see a  b'
      }
      expect(shown.keys.to_h { |line| [line, objects_shown_for(line)] }).to eq shown
    end

    it 'shows only the text the objects line shows in main, not the text of paired tags or other streams' do
      shown = {
        'You also see <compass>x</compass>'                 => 'You also see',
        %(You also see <component id="a>b">box</component>) => 'You also see'
      }
      expect(shown.keys.to_h { |line| [line, objects_shown_for(line)] }).to eq shown
    end

    # The runs of the objects row drawn in the monsterbold color for the
    # objects line +line+.
    def red_runs_for(line)
      objects_shown_for(line)
      red_runs('You also see')
    end

    it "opens each object's link where its name is shown" do
      objects_shown_for("You also see <a exist='1' noun='box'>a box</a> and " \
                        "<pushBold/><d cmd='look goblin'>a goblin</d><popBold/>.")

      expect(room_rows[1]).to eq 'You also see a box and a goblin.'
      expect(commands_under('a box')).to eq ['look #1']
      expect(commands_under('a goblin')).to eq ['look goblin']
      expect(commands_under(' and ')).to eq [nil]
    end

    it 'draws the text of each bold region in the monsterbold color' do
      creatures = {
        '<pushBold/>a goblin<popBold/>, <pushBold/>a troll<popBold/>'  => ['a goblin', 'a troll'],
        '<pushBold/>a goblin<popBold/>, <pushBold/>a goblin<popBold/>' => ['a goblin', 'a goblin'],
        '<pushBold>a<popBold>'                                         => ['a'],
        '<popBold/>a<pushBold/><popBold/>'                             => [],
        '<pushBold/> <popBold/>a box.'                                 => [],
        # bold left open at the end of the line closes there
        # (GameTextProcessor#carry_bold)
        '<pushBold/>a'                                                 => ['a'],
        # any tag the dispatcher reads as pushBold or popBold
        "<pushBold x='1'/>a goblin<popBold/>"                          => ['a goblin'],
        '<pushBold/ >a<popBold/>'                                      => ['a'],
        '<pushBold-x/>a<popBold/>'                                     => ['a'],
        '<pushBold/>a <> b<popBold/>'                                  => ['a  b']
      }
      expect(creatures.keys.to_h { |markup| [markup, red_runs_for("You also see #{markup}")] }).to eq creatures
    end

    it "draws a creature that is a link in the monsterbold color where the link color doesn't cover it" do
      state.blue_links = false
      objects_shown_for("You also see <pushBold />a <d cmd='x'>goblin</d><popBold />")

      expect(red_runs('You also see')).to eq ['a goblin']
    end

    it 'draws nested bold regions as the main window does' do
      creatures = {
        '<pushBold/>a<pushBold/>b<popBold/>c<popBold/>' => ['abc'],
        "<pushBold/>a <b t='>'>b<popBold/>"             => ['b'],
        '<pushBold/><right>x</right><popBold/>'         => []
      }
      expect(creatures.keys.to_h { |markup| [markup, red_runs_for("You also see #{markup}")] }).to eq creatures
    end

    # Characterization: the tag parser drops a <b> left open at the end of
    # its line (only pushBold is carried to the next line).
    it "doesn't take a bold left open on an earlier line into a creature" do
      load_layout
      receive_from_server('<style id="roomName" />[A]', '<b>A glint', 'You also see a rat<popBold/> and a box.', exits_line)

      expect(room_rows[1]).to eq 'You also see a rat and a box.'
      expect(red_runs('You also see')).to eq []
    end

    # A bold span open at a mid-line flush (here the roomDesc preset's
    # close) goes on in the text after the flush from its start, as the
    # main window draws it. (Read from the raw line, the objects had no
    # creature: their text held only the span's end.)
    it 'draws a bold span that goes on past a roomDesc preset in the objects after it' do
      load_layout
      receive_from_server('<style id="roomName" />[A]',
                          "<preset id='roomDesc'>A <pushBold/>dark</preset>You also see a rat<popBold/>.", exits_line)

      expect(room_rows[2]).to eq 'You also see a rat.'
      expect(red_runs('You also see')).to eq ['You also see a rat']
    end

    # Bold left open at the end of a line is carried to the next
    # (GameTextProcessor#carry_bold), and the main window draws it there;
    # read from the raw line, the objects had no creature.
    it 'draws a bold span carried from the line before in the objects' do
      load_layout
      receive_from_server('<style id="roomName" />[A]', '<pushBold/>A glint', 'You also see a rat<popBold/> and a box.', exits_line)

      expect(room_rows[1]).to eq 'You also see a rat and a box.'
      expect(red_runs('You also see')).to eq ['You also see a rat']
    end

    # DR sends the objects of a LOOK as "  You also see": the carried span
    # starts on the spaces the room row leaves out, and the creature is
    # still the span's text (it was lost, or cut from the row's end).
    describe 'in objects that start with spaces' do
      it 'draws a carried bold span that ends in the objects' do
        load_layout
        receive_from_server('<style id="roomName" />[A]', '<pushBold/>A glint', '  You also see a rat<popBold/> and a box.', exits_line)

        expect(room_rows[1]).to eq 'You also see a rat and a box.'
        expect(red_runs('You also see')).to eq ['You also see a rat']
      end

      it 'draws a carried bold span that covers all the objects' do
        load_layout
        receive_from_server('<style id="roomName" />[A]', '<pushBold/>A glint', '  You also see a box and a t.<popBold/>', exits_line)

        expect(room_rows[1]).to eq 'You also see a box and a t.'
        expect(red_runs('You also see')).to eq ['You also see a box and a t.']
      end
    end
  end
end
