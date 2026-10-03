# frozen_string_literal: true

# What a click on a GemStone coord link sends: <a exist="..." coord="..."
# noun="...">. The command for a coord comes from the game's own command
# table, the <cmdlist> of <cli coord menu command menu_cat/> the server can
# send; a coord with no entry in it is not a link at all.
#
# The exits, ACCEPT/DECLINE, TARGET and pay lines are real GemStone lines
# from the stream-complete Lich XML logs of 2026-10-01/02 (trimmed: fewer
# exits or players). No log has a <cmdlist>: the cmdlist lines below are
# written in the form a third-party front-end's parser reads (Saga 6c2079e),
# which is the only source for it.
#
# Lines are fed through the real server loop (GameTextProcessor#run) into
# real windows built from layout XML; the assertions are on what the
# windows show and on #link_cmd_at, which answers a click.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Coord links' do
  let(:state) do
    SharedState.new.tap do |s|
      s.skip_server_time_offset = true
      s.blue_links = true
    end
  end
  # Color pair number per foreground color, so a cell's color can be read
  # back: 5555ff is the color links are drawn in when no 'links' preset is
  # set.
  let(:pairs) { { '5555ff' => 5 } }
  # What the client writes to the server.
  let(:written) { [] }

  # Exits: every link carries the clicking character's own id
  # (GSIV-Ilten/2026-10-01_21-00-59.xml:37, two of its six exits).
  let(:exits_line) do
    'Obvious paths: <a exist="-11069569" coord="2524,1864" noun="northeast">northeast</a>, ' \
      '<a exist="-11069569" coord="2524,1864" noun="east">east</a>'
  end
  # GSF-Pickasso/2026-10-01_21-27-24.xml:2488
  let(:offer_line) do
    '<a exist="-11165808" noun="Nexushealbot">Nexushealbot</a> offers you <a exist="558389477" noun="crackers">' \
      'some soylent green crackers</a>.  Click <a exist="-11165808" coord="2524,1753" noun="">ACCEPT</a> to accept ' \
      'the offer or <a exist="-11165808" coord="2524,1755" noun="">DECLINE</a> to decline it.  ' \
      'The offer will expire in 30 seconds.'
  end
  # GSF-Tysong/2026-10-01_23-23-55.xml:1278-1280
  let(:target_lines) do
    ['        <a exist="-11223064" coord="2524,1983" noun="">TARGET RANDOM</a>',
     '        <d cmd="target next">TARGET NEXT</d>',
     '        <a exist="-11223064" coord="2524,1706" noun="">TARGET CLEAR</a>']
  end
  # GSF-Tysong/2026-10-01_21-02-27.xml:12971 (cut after the link)
  let(:pay_line) do
    'He looks over the <a exist="558119051" noun="trunk">tanik trunk</a>, frowns, and tells you, ' \
      '"<a exist="-11223064" coord="2524,1940" noun="">Gimme 3,085 silvers</a>, and I\'ll have it open."'
  end

  before do
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, _bg| pairs.fetch(fg, 0) }
    load_layout
  end

  # Build a main window and a room window, and a processor that feeds them.
  def load_layout
    LAYOUT['coord'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='8' width='160' value='main'/>
        <window class='room' top='10' left='0' height='8' width='160' value='room'/>
      </layout>
    XML
    event_bus = EventBus.new
    @window_manager = WindowManager.new(shared_state: state)
    @window_manager.load_layout('coord')
    @window_manager.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @window_manager, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would (Lich ends every line with CRLF). Anything the client writes to
  # the server is kept in +written+.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    sent = written
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    %i[write puts print syswrite].each do |name|
      server.define_singleton_method(name) { |*args| sent.concat(args) }
    end
    allow(IO).to receive(:select).and_return(nil)
    @processor.run(server)
  end

  def main = @window_manager.stream['main']
  def room = @window_manager.room['room']
  def main_rows = main.rows.map(&:rstrip).reject(&:empty?)
  def room_rows = room.rows.map(&:rstrip).reject(&:empty?)

  # The row of +window+ showing +text+ (the last one), and its column.
  def locate(window, text)
    y = window.rows.rindex { |row| row.include?(text) }
    raise "#{text.inspect} not shown: #{window.rows.reject(&:empty?).inspect}" unless y

    [y, window.row(y).index(text)]
  end

  # The link command a click on each character of +text+ opens (nil where
  # there is no link), without repeats.
  def commands_under(text, window = main)
    y, x = locate(window, text)
    (x...(x + text.length)).map { |col| window.link_cmd_at(y, col) }.uniq
  end

  # The color of each character of +text+: a foreground color, nil when
  # uncolored, or an Array when mixed.
  def color_of(text, window = main)
    y, x = locate(window, text)
    colors = (x...(x + text.length)).map { |col| pairs.key(window.attrs_at(y, col) >> 8) }.uniq
    colors.size == 1 ? colors.first : colors
  end

  # A <cmdlist> on one line, one <cli> per [coord, command].
  def cmdlist(*entries)
    clis = entries.map { |coord, command| %(<cli coord="#{coord}" menu="m" command="#{command}" menu_cat="0"/>) }
    "<cmdlist>#{clis.join}</cmdlist>"
  end

  describe 'with no command table from the server (every log so far)' do
    it 'makes no exit clickable, and shows the exits as plain text' do
      receive_from_server(exits_line)

      expect(main_rows).to eq ['Obvious paths: northeast, east']
      expect(commands_under('northeast')).to eq [nil]
      expect(commands_under(' east')).to eq [nil]
      expect(color_of('northeast')).to be_nil
    end

    it 'makes ACCEPT and DECLINE unclickable, and keeps the links without a coord' do
      receive_from_server(offer_line)

      expect(commands_under('ACCEPT')).to eq [nil]
      expect(commands_under('DECLINE')).to eq [nil]
      expect(commands_under('Nexushealbot')).to eq ['look #-11165808']
      expect(commands_under('some soylent green crackers')).to eq ['look #558389477']
      expect(color_of('Nexushealbot')).to eq '5555ff'
    end

    it "makes TARGET RANDOM and TARGET CLEAR unclickable, and keeps TARGET NEXT's cmd" do
      receive_from_server(*target_lines)

      expect(commands_under('TARGET RANDOM')).to eq [nil]
      expect(commands_under('TARGET CLEAR')).to eq [nil]
      expect(commands_under('TARGET NEXT')).to eq ['target next']
    end

    it "makes the locksmith's pay link unclickable" do
      receive_from_server(pay_line)

      expect(commands_under('Gimme 3,085 silvers')).to eq [nil]
      expect(commands_under('tanik trunk')).to eq ['look #558119051']
    end

    it "makes the inline exits unclickable in the room window too, as after Ilten's LOOK" do
      # GSIV-Ilten/2026-10-01_21-00-59.xml:33-38, trimmed: no room exits
      # component arrives, so the inline exits line fills the room window.
      receive_from_server(
        '<resource picture="0"/><style id="roomName" />[Town Square Central] (7120)',
        '<style id=""/><style id="roomDesc"/>At the north end, an <a exist="-562" noun="well">old well</a> ' \
        'is shaded.  <style id=""/>',
        exits_line,
        '<compass><dir value="ne"/><dir value="e"/></compass><prompt time="1790902867">s&gt;</prompt>'
      )

      expect(room_rows.last).to eq 'Obvious paths: northeast, east'
      expect(commands_under('northeast', room)).to eq [nil]
      expect(color_of('northeast', room)).to be_nil
      expect(commands_under('old well', room)).to eq ['look #-562']
    end

    it "keeps the room exits component's <d> links clickable (#224)" do
      # GSF-Tysong/2026-10-01_21-20-16.xml:12235 (the exits compDef) with
      # the room push around it.
      receive_from_server(
        "<pushStream id='room'/><compDef id='room exits'>Obvious paths: <d>north</d>, <d>east</d></compDef>",
        "<popStream id='room'/>",
        '<prompt time="1790904402">&gt;</prompt>'
      )

      expect(commands_under('north', room)).to eq ['north']
      expect(commands_under('east', room)).to eq ['east']
    end

    it 'treats an empty coord as no coord' do
      receive_from_server('Click <a exist="-1" coord="" noun="">here</a>.')

      expect(commands_under('here')).to eq ['_drag #-1']
    end

    it 'lets a cmd attribute win over the coord' do
      receive_from_server('<a exist="-1" coord="2524,1864" noun="north" cmd="go north">north</a>')

      expect(commands_under('north')).to eq ['go north']
    end

    it 'sends no request to the server for a table' do
      receive_from_server(exits_line, '<updateverbs/>', '<cmdtimestamp data="1776042608"/>', '<prompt time="1">&gt;</prompt>')

      # Only the 'look' PromptTracker sends at the first prompt: no
      # "_menu update" or anything else.
      expect(written).to eq ['look']
      expect(main_rows).to eq ['Obvious paths: northeast, east']
    end
  end

  describe 'with a command table from the server' do
    it 'sends the command for the coord, with @ as the noun' do
      receive_from_server(cmdlist(['2524,1864', 'go @']), exits_line)

      expect(commands_under('northeast')).to eq ['go northeast']
      expect(commands_under(' east')[1..]).to eq ['go east']
      expect(color_of('northeast')).to eq '5555ff'
    end

    it 'shows nothing for the table, whichever window is current' do
      receive_from_server('before', cmdlist(['2524,1864', 'go @']), 'after')

      expect(main_rows).to eq %w[before after]
      expect(room_rows).to be_empty
    end

    it 'sends the command for ACCEPT and DECLINE, whose noun is empty' do
      receive_from_server(cmdlist(%w[2524,1753 accept], %w[2524,1755 decline]), offer_line)

      expect(commands_under('ACCEPT')).to eq ['accept']
      expect(commands_under('DECLINE')).to eq ['decline']
    end

    it 'replaces # with #exist and % with the bare exist' do
      receive_from_server(cmdlist(['2524,1983', 'look #'], ['2524,1706', '_inspect %']), *target_lines)

      expect(commands_under('TARGET RANDOM')).to eq ['look #-11223064']
      expect(commands_under('TARGET CLEAR')).to eq ['_inspect -11223064']
    end

    it 'drops the space an empty noun leaves, and collapses runs of spaces' do
      receive_from_server(cmdlist(['2524,1940', ' pay   @ ']), pay_line)

      expect(commands_under('Gimme 3,085 silvers')).to eq ['pay']
    end

    it 'makes a link unclickable when its command has both # and %' do
      receive_from_server(cmdlist(['2524,1940', '_dialog # %']), pay_line)

      expect(commands_under('Gimme 3,085 silvers')).to eq [nil]
    end

    it 'makes a link unclickable when its command comes out empty' do
      receive_from_server(cmdlist(%w[2524,1940 @]), pay_line)

      expect(commands_under('Gimme 3,085 silvers')).to eq [nil]
    end

    it 'leaves a coord the table lacks unclickable' do
      receive_from_server(cmdlist(%w[2524,1753 accept]), offer_line)

      expect(commands_under('ACCEPT')).to eq ['accept']
      expect(commands_under('DECLINE')).to eq [nil]
    end

    it 'ignores a <cli> with no command or an empty one' do
      receive_from_server(
        '<cmdlist><cli coord="2524,1753" menu="accept"/><cli coord="2524,1755" menu="decline" command=""/></cmdlist>',
        offer_line
      )

      expect(commands_under('ACCEPT')).to eq [nil]
      expect(commands_under('DECLINE')).to eq [nil]
    end

    it 'reads a table sent over several lines, and shows none of its lines' do
      receive_from_server(
        'before',
        '<cmdlist timestamp="1776042608">',
        '<cli coord="2524,1753" menu="accept" command="accept" menu_cat="0"/>',
        'stray text',
        '<cli coord="2524,1755" menu="decline" command="decline" menu_cat="0"/></cmdlist>after',
        offer_line
      )

      expect(main_rows.first(2)).to eq %w[before after]
      expect(commands_under('ACCEPT')).to eq ['accept']
      expect(commands_under('DECLINE')).to eq ['decline']
    end

    it 'discards a table a prompt cuts short, handles the prompt and shows what follows' do
      receive_from_server(
        '<cmdlist><cli coord="2524,1753" menu="accept" command="accept" menu_cat="0"/>',
        '<prompt time="1">&gt;</prompt>',
        offer_line
      )

      # The 'look' PromptTracker sends at the first prompt: the prompt was
      # handled as a prompt.
      expect(written).to eq ['look']
      expect(main_rows).to eq [offer_line.gsub(/<[^>]*>/, '')]
      expect(commands_under('ACCEPT')).to eq [nil]
    end

    it 'adds a later table to the first, the later command winning for the same coord' do
      receive_from_server(cmdlist(%w[2524,1753 accept], %w[2524,1755 decline]),
                          cmdlist(['2524,1753', 'accept offer']), offer_line)

      expect(commands_under('ACCEPT')).to eq ['accept offer']
      expect(commands_under('DECLINE')).to eq ['decline']
    end

    it 'reads nothing from an empty <cmdlist/>, and goes on showing text' do
      receive_from_server('<cmdlist/>after', offer_line)

      expect(main_rows.first).to eq 'after'
      expect(commands_under('ACCEPT')).to eq [nil]
    end

    it 'ignores a <cli> outside a <cmdlist>' do
      receive_from_server('<cli coord="2524,1753" menu="accept" command="accept" menu_cat="0"/>', offer_line)

      expect(commands_under('ACCEPT')).to eq [nil]
    end

    it 'leaves a link that arrived before the table unclickable' do
      receive_from_server(offer_line, cmdlist(%w[2524,1753 accept]))

      expect(commands_under('ACCEPT')).to eq [nil]
    end

    it 'uses the table for the inline exits in the room window' do
      receive_from_server(
        cmdlist(['2524,1864', 'go @']),
        '<resource picture="0"/><style id="roomName" />[Town Square Central] (7120)',
        '<style id=""/><style id="roomDesc"/>A square.  <style id=""/>',
        exits_line,
        '<compass><dir value="ne"/><dir value="e"/></compass><prompt time="1790902867">s&gt;</prompt>'
      )

      expect(commands_under('northeast', room)).to eq ['go northeast']
    end
  end
end
