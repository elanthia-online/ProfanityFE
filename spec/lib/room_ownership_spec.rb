# frozen_string_literal: true

# Component data owns the room it described (AUDIT §0.2, one room
# pipeline). DragonRealms sends a room twice on a move: the room
# components (after the room streamWindow's subtitle), then the inline
# lines (roomName, roomDesc, "You also see", "Also here:", "Obvious
# paths:"). Within one burst (from the subtitle or a prompt to the end of
# the line with the next prompt) the inline lines no longer overwrite a
# field a component delivered; they fill only what the burst didn't
# deliver, and a LOOK after the prompt shows its own lines. The title row
# is the exception: it takes the roomName's text when that differs from
# the subtitle (Lich's room ids), so the row and the terminal title name
# the room alike.
#
# Lines are fed through the real server loop into windows built from
# layout XML; the assertions read the room window's rows (with the command
# a click on a cell sends) and the room players indicator.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/games'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Room ownership' do
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:prompt) { '<prompt time="1">&gt;</prompt>' }
  let(:game_rules) { Games::BOTH_GAMES }

  before do
    allow(IO).to receive(:select).and_return(nil)
    expect(Process).not_to receive(:spawn)
    state.blue_links = true
    LAYOUT['ownership'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='20' width='100' value='main'/>
        <window class='room' top='1' left='0' height='12' width='100' value='room'/>
        <window class='indicator' top='2' left='0' height='1' width='60' label=' ' value='room players'/>
      </layout>
    XML
    event_bus = EventBus.new
    @window_manager = WindowManager.new(shared_state: state)
    @window_manager.load_layout('ownership')
    @window_manager.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @window_manager, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus, game_rules: game_rules
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would (Lich ends every line with CRLF).
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |_command| nil }
    server.define_singleton_method(:flush) { nil }
    @processor.run(server)
  end

  # The room window's rows, blank rows left out, with "[text](cmd)" where
  # a click on the cells sends +cmd+.
  def room_screen
    room = @window_manager.room['room']
    room.rows.each_index.filter_map do |y|
      next if room.row(y).strip.empty?

      runs = room.row(y).rstrip.each_char.with_index.chunk_while do |(_, a), (_, b)|
        room.link_cmd_at(y, a) == room.link_cmd_at(y, b)
      end
      runs.map { |run| (cmd = room.link_cmd_at(y, run.first.last)) ? "[#{run.map(&:first).join}](#{cmd})" : run.map(&:first).join }
          .join
    end
  end

  def indicator_label = @window_manager.indicator['room players'].rows.first.rstrip

  # A room's subtitle and components, as DR sends them on a move.
  def components(name, objs: 'You also see a box.', players: '', exits: 'Obvious paths: <d>north</d>.')
    ["<streamWindow id='room' title='Room' subtitle=\" - #{name}\" location='center' target='drop' ifClosed='' resident='true'/>",
     "<component id='room desc'>Desc of #{name}.</component>",
     "<component id='room objs'>#{objs}</component>",
     "<component id='room players'>#{players}</component>",
     "<component id='room exits'>#{exits}<compass></compass></component>",
     "<component id='room extra'></component>"]
  end

  # A room's inline lines (a move's second half, or a LOOK).
  def inline(name, objs: '  You also see a box.', players: nil, exits: 'Obvious paths: <d>north</d>.')
    ["<resource picture=\"0\"/><style id=\"roomName\" />#{name}", "<style id=\"\"/><preset id='roomDesc'>Desc of #{name}.</preset>#{objs}",
     *players, exits]
  end

  describe 'inline lines in the burst the components delivered' do
    it "keep the component's objects, players and exits" do
      receive_from_server(*components('[A] (1)', players: 'Also here: Bob.'),
                          *inline('[A] (1)', objs: '  You also see a box and a rat.', players: 'Also here: Bob and Ann.',
                                             exits: 'Obvious paths: <d>north</d>, <d>south</d>.'),
                          prompt)

      expect(room_screen).to eq ['[A] (1)', 'Desc of [A] (1).', 'You also see a box.', 'Also here: Bob.',
                                 'Obvious paths: [north](north).']
      expect(indicator_label).to eq 'Bob'
    end

    it 'keep a field an empty component cleared' do
      receive_from_server(*components('[A] (1)', objs: ''), *inline('[A] (1)'), prompt)

      expect(room_screen).to eq ['[A] (1)', 'Desc of [A] (1).', 'Obvious paths: [north](north).']
    end

    it 'keep the title row when they carry no roomName' do
      receive_from_server(*components('[A] (1)'), 'Also here: Bob.', 'Obvious paths: <d>north</d>.', prompt)

      expect(room_screen.first).to eq '[A] (1)'
    end

    # Characterization (passes on the base by design): the room title
    # component's title stayed on the base too.
    it 'keep the title a room title component delivered when they carry no roomName' do
      receive_from_server(prompt, "<component id='room title'>[B] (2)</component>", 'Also here: Bob.', 'Obvious paths: <d>north</d>.',
                          prompt)

      expect(room_screen.first).to eq '[B] (2)'
    end

    it "show the roomName's text in the title row when it differs from the subtitle, and fill nothing else" do
      receive_from_server(*components('[A] (1)'), *inline('[A - 55] (1)', objs: '  You also see a rat.'), prompt)

      expect(room_screen).to eq ['[A - 55] (1)', 'Desc of [A] (1).', 'You also see a box.', 'Obvious paths: [north](north).']
      expect(state.room_title).to eq 'A - 55 (1)'
    end

    # Characterization (passes on the base by design): what no component
    # delivered is filled from the inline lines, as before ownership.
    it 'fill the fields the components left out' do
      receive_from_server("<streamWindow id='room' title='Room' subtitle=\" - [A] (1)\" location='center' target='drop' ifClosed='' resident='true'/>",
                          "<component id='room desc'>Desc of [A] (1).</component>", "<component id='room extra'></component>",
                          *inline('[A] (1)', objs: '  You also see a rat.', players: 'Also here: Ann.'), prompt)

      expect(room_screen).to eq ['[A] (1)', 'Desc of [A] (1).', 'You also see a rat.', 'Also here: Ann.',
                                 'Obvious paths: [north](north).']
      expect(indicator_label).to eq 'Ann'
    end
  end

  describe "DR's cut-short objs component" do
    let(:cut) { 'You also see a box, a rat and some other stuff.' }
    let(:full) { '  You also see a box, a rat, a pebble and a leaf.' }

    it "doesn't own the objects: the inline list of the burst fills in" do
      receive_from_server(*components('[A] (1)', objs: cut), *inline('[A] (1)', objs: full), prompt)

      expect(room_screen[2]).to eq 'You also see a box, a rat, a pebble and a leaf.'
    end

    # Characterization (passes on the base by design): the cut list is
    # shown as it arrives.
    it 'shows until the inline list arrives' do
      receive_from_server(*components('[A] (1)', objs: cut))

      expect(room_screen[2]).to eq 'You also see a box, a rat and some other stuff.'
    end

    it 'takes back the ownership a whole list gave earlier in the burst' do
      receive_from_server(*components('[A] (1)'), "<component id='room objs'>#{cut}</component>",
                          *inline('[A] (1)', objs: full), prompt)

      expect(room_screen[2]).to eq 'You also see a box, a rat, a pebble and a leaf.'
    end

    context 'with --game=GS' do
      let(:game_rules) { Games.rules_for('GS') }

      it 'owns the objects: GemStone has no cut-short mark' do
        receive_from_server(*components('[A] (1)', objs: cut), *inline('[A] (1)', objs: full), prompt)

        expect(room_screen[2]).to eq 'You also see a box, a rat and some other stuff.'
      end
    end
  end

  describe 'inline lines after the prompt (a LOOK)' do
    # Characterization (passes on the base by design): the prompt ends the
    # burst, so a LOOK fills every field, as before ownership.
    it 'show their own lines' do
      receive_from_server(*components('[A] (1)'), *inline('[A] (1)'), prompt,
                          *inline('[A] (1)', objs: '  You also see a box and a rat.', players: 'Also here: Ann.',
                                             exits: 'Obvious paths: <d>north</d>, <d>south</d>.'),
                          prompt)

      expect(room_screen).to eq ['[A] (1)', 'Desc of [A] (1).', 'You also see a box and a rat.', 'Also here: Ann.',
                                 'Obvious paths: [north](north), [south](south).']
      expect(indicator_label).to eq 'Ann'
    end
  end

  # A prompt on the inline exits line ends the burst at the line's end,
  # after the line's text has been handed off, so that line's commit is
  # still part of the burst the components delivered. DR sends no such line
  # (the corpus has no text before a prompt on the same line).
  describe 'a prompt on the inline exits line' do
    let(:subtitle) do
      "<streamWindow id='room' title='Room' subtitle=\" - [A] (1)\" location='center' target='drop' ifClosed='' resident='true'/>"
    end
    # A component after the room exits component: an order DR doesn't send
    # (the GemStone specs use it).
    let(:exits_then_players) do
      [prompt, subtitle, "<component id='room exits'>Obvious paths: <d>north</d>.<compass></compass></component>",
       "<component id='room players'>Also here: Bob.</component>"]
    end

    # Decided (component data owns the room it described), as without the
    # prompt. The base sent the inline lines here: DR's room exits
    # component, sent last, dropped what the components had staged.
    it "keeps the component's fields in that line's commit" do
      receive_from_server(*components('[A] (1)', players: 'Also here: Bob.'),
                          *inline('[A] (1)', objs: '  You also see a rat.', players: 'Also here: Ann.',
                                             exits: "Obvious paths: <d>south</d>.#{prompt}"))

      expect(room_screen).to eq ['[A] (1)', 'Desc of [A] (1).', 'You also see a box.', 'Also here: Bob.',
                                 'Obvious paths: [north](north).']
      expect(indicator_label).to eq 'Bob'
    end

    # Characterization (passes on the base by design): the base re-sent the
    # players the component staged after the room exits component.
    it 'keeps players a component delivered after the room exits component' do
      receive_from_server(*exits_then_players, *inline('[A] (1)', exits: "Obvious paths: <d>north</d>.#{prompt}"))

      expect(room_screen).to eq ['[A] (1)', 'Desc of [A] (1).', 'You also see a box.', 'Also here: Bob.',
                                 'Obvious paths: [north](north).']
      expect(indicator_label).to eq 'Bob'
    end

    # Characterization (passes on the base by design).
    it 'keeps them with the prompt at the start of the exits line' do
      receive_from_server(*exits_then_players, *inline('[A] (1)', exits: "#{prompt}Obvious paths: <d>north</d>."))

      expect(room_screen).to eq ['[A] (1)', 'Desc of [A] (1).', 'You also see a box.', 'Also here: Bob.',
                                 'Obvious paths: [north](north).']
    end

    # Characterization (passes on the base by design): the burst ended with
    # that line, so a LOOK on the next lines shows its own lines.
    it 'lets a LOOK on the next lines show its own lines' do
      receive_from_server(*exits_then_players, *inline('[A] (1)', exits: "Obvious paths: <d>north</d>.#{prompt}"),
                          *inline('[A] (1)', objs: '  You also see a rat.', players: 'Also here: Ann.'), prompt)

      expect(room_screen).to eq ['[A] (1)', 'Desc of [A] (1).', 'You also see a rat.', 'Also here: Ann.',
                                 'Obvious paths: [north](north).']
      expect(indicator_label).to eq 'Ann'
    end

    # Characterization (passes on the base by design): a component after
    # the prompt on the same line belongs to the next burst, and keeps it
    # when the line ends.
    it 'leaves a component after the prompt on its line to the next burst' do
      receive_from_server(*components('[A] (1)'), *inline('[A] (1)'),
                          "#{prompt}<component id='room players'>Also here: Carl.</component>",
                          *inline('[A] (1)', players: 'Also here: Bob.'), prompt)

      expect(room_screen[3]).to eq 'Also here: Carl.'
      expect(indicator_label).to eq 'Carl'
    end

    # Characterization (passes on the base by design): the same with a
    # second prompt on the line.
    it 'keeps them with two prompts on the exits line' do
      receive_from_server(*exits_then_players, *inline('[A] (1)', exits: "Obvious paths: <d>north</d>.#{prompt}#{prompt}"))

      expect(room_screen[3]).to eq 'Also here: Bob.'
    end

    # Decided (PLAN Q1 b): a cut-short objs list after a whole one, both
    # after the prompt, leaves the objects to the next burst's inline list.
    it 'lets a cut-short objs component after the prompt leave the objects to the inline list' do
      receive_from_server(*components('[A] (1)'), *inline('[A] (1)'),
                          "#{prompt}<component id='room objs'>You also see a box.</component>" \
                          "<component id='room objs'>You also see a box and some other stuff.</component>",
                          *inline('[A] (1)', objs: '  You also see a box and a rat.'), prompt)

      expect(room_screen[2]).to eq 'You also see a box and a rat.'
    end

    # Decided (component data owns the room it described): a subtitle
    # after the prompt starts the next burst at once, and that burst keeps
    # its title.
    it 'ends the burst at once for a subtitle after the prompt, which the next burst keeps' do
      receive_from_server(*components('[A] (1)', players: 'Also here: Bob.'), *inline('[B] (2)').first(2),
                          "#{prompt}#{subtitle.sub('[A] (1)', '[B] (2)')}Obvious paths: <d>south</d>.")

      expect(room_screen).to eq ['[B] (2)', 'Desc of [B] (2).', 'You also see a box.', 'Obvious paths: [south](south).']

      receive_from_server('Also here: Ann.', 'Obvious paths: <d>south</d>.', prompt)

      expect(room_screen).to eq ['[B] (2)', 'Also here: Ann.', 'Obvious paths: [south](south).']
    end
  end

  # Two inline lines for one field in one view: the first roomDesc and the
  # first "Also here:" line stay (as the base's guards gave); the last
  # roomName and "You also see" line win.
  describe 'two inline lines for one field in a view' do
    let(:look_desc) { ['<resource picture="0"/><style id="roomName" />[A] (1)', "<style id=\"\"/><preset id='roomDesc'>Main desc.</preset>  You also see a box."] }
    let(:familiar_desc) { ["<pushStream id='familiar'/><preset id='roomDesc'>The familiar's room.</preset>", '<popStream/>'] }

    it "keep main's roomDesc over a familiar's that arrives before the exits line" do
      receive_from_server(prompt, *look_desc, *familiar_desc, 'Obvious paths: <d>north</d>.', prompt)

      expect(room_screen).to eq ['[A] (1)', 'Main desc.', 'You also see a box.', 'Obvious paths: [north](north).']
    end

    # Kept as on the base: a roomDesc on another stream is staged too (PLAN
    # F2), so a familiar's read before the view's own is the one shown.
    it "keep a familiar's roomDesc read before the view's own" do
      receive_from_server(prompt, *familiar_desc, *inline('[A] (1)'), prompt)

      expect(room_screen[1]).to eq "The familiar's room."
    end

    it 'keep the first "Also here:" line' do
      receive_from_server(prompt, *inline('[A] (1)', players: ['Also here: Ann.', 'Also here: Bob.']), prompt)

      expect(room_screen[3]).to eq 'Also here: Ann.'
      expect(indicator_label).to eq 'Ann'
    end

    # Characterization (passes on the base by design).
    it 'take the last roomName' do
      receive_from_server(prompt, *look_desc, "<pushStream id='familiar'/><style id=\"roomName\" />[F] (9)", '<style id=""/><popStream/>',
                          'Obvious paths: <d>north</d>.', prompt)

      expect(room_screen.first).to eq '[F] (9)'
    end

    # Characterization (passes on the base by design).
    it 'take the last "You also see" line' do
      receive_from_server(prompt, *inline('[A] (1)', players: '  You also see a rat.'), prompt)

      expect(room_screen[2]).to eq 'You also see a rat.'
    end
  end

  # Characterization (passes on the base by design): an "Also here:" line
  # alone before the exits line commits a view, as a title, description or
  # objects line does.
  it 'shows an "Also here:" line that comes alone before the exits line, and hides what it lacks' do
    receive_from_server(*components('[A] (1)'), *inline('[A] (1)'), prompt,
                        'Also here: Ann.', 'Obvious paths: <d>north</d>.', prompt)

    expect(room_screen).to eq ['Desc of [A] (1).', 'Also here: Ann.', 'Obvious paths: [north](north).']
    expect(indicator_label).to eq 'Ann'
  end

  it 'changes only the exits for a lone exits line after a trailing players component' do
    receive_from_server(*components('[A] (1)'), *inline('[A] (1)'), "<component id='room players'>Also here: Bob.</component>", prompt,
                        'Obvious paths: <d>north</d>, <d>up</d>.', prompt)

    expect(room_screen).to eq ['[A] (1)', 'Desc of [A] (1).', 'You also see a box.', 'Also here: Bob.',
                               'Obvious paths: [north](north), [up](up).']
  end

  # Characterization (passes on the base by design): a roomDesc read on
  # another stream (a familiar's view) is staged, and the room exits
  # component drops it, so a later brief move doesn't show it.
  it "doesn't show a familiar's room description on a brief move with an exits component" do
    receive_from_server("<pushStream id='familiar'/><preset id='roomDesc'>The familiar's room.</preset>", '<popStream/>', prompt,
                        "<streamWindow id='room' title='Room' subtitle=\" - [A] (1)\" location='center' target='drop' ifClosed='' resident='true'/>",
                        "<component id='room exits'>Obvious paths: <d>north</d>.<compass></compass></component>",
                        '<resource picture="0"/><style id="roomName" />[A] (1)', '<style id=""/>  ', 'Obvious paths: <d>north</d>.', prompt)

    expect(room_screen).to eq ['[A] (1)', 'Obvious paths: [north](north).']
  end

  # Characterization (passes on the base by design): a second room's
  # subtitle starts a new burst, so the first room's components don't own
  # the second room's inline lines.
  it 'fills a second room of the same prompt cycle from its inline lines' do
    receive_from_server(*components('[A] (1)'), *inline('[A] (1)'),
                        "<streamWindow id='room' title='Room' subtitle=\" - [B] (2)\" location='center' target='drop' ifClosed='' resident='true'/>",
                        *inline('[B] (2)', objs: '  You also see a rat.', exits: 'Obvious paths: <d>south</d>.'), prompt)

    expect(room_screen).to eq ['[B] (2)', 'Desc of [B] (2).', 'You also see a rat.', 'Obvious paths: [south](south).']
  end
end
