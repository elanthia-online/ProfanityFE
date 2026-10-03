# frozen_string_literal: true

# Tests where GemStone's loot results go. After LOOT ROOM/AREA or a box
# search the game sends what was found on the loot stream
# (<pushStream id='loot'/> ... <popStream id='loot'/>) and no copy of it
# in main. A layout with no window for loot (the bundled tysong.xml has
# none) shows the results in main, as Lich's conversion for front-ends
# without streams (sf_to_wiz) keeps them; a layout with a loot window
# shows them there, and only there. Bounty and reserve updates stay
# dropped when there is no window for them, as Lich drops them too
# (decided 2026-10-04).
#
# Every case runs real GemStone lines (trimmed from the 2026-10-01/02
# Tysong and Pickasso session logs) through the real server loop
# (GameTextProcessor#run) into the windows of the real tysong.xml layout
# on the virtual screen.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'GemStone loot results (the loot stream)' do
  let(:tysong) { File.expand_path('../../templates/tysong.xml', __dir__) }
  let(:event_bus) { EventBus.new }
  let(:wm) { WindowManager.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: wm,
      shared_state: state,
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus,
      game_rules: Games.rules_for('GS')
    )
  end
  # Every non-empty :stream_text emit, as [stream, text, colors].
  let(:shown) { [] }
  let(:errors) { [] }

  # GSF-Tysong/2026-10-01_21-02-27.xml:373-380, the first line trimmed to
  # its main text (the inv stream before it is dropped either way).
  let(:loot_room) do
    [
      'With a discerning eye, you gather up what treasure you find worthwhile and casually stow it away.',
      "<pushStream id='loot'/>",
      'You search the room and find:',
      '  (stowed in a <a exist="513692462" noun="pouch">sturdy dark leather gem pouch</a>)',
      '   a <a exist="558041195" noun="sapphire">violet sapphire</a>',
      'Looted 1 items.',
      "<popStream id='loot'/>",
      '<prompt time="1790902956">&gt;</prompt>',
      'You have no silver with you.',
    ]
  end

  let(:loot_rows) do
    ['You search the room and find:', '  (stowed in a sturdy dark leather gem pouch)', '   a violet sapphire',
     'Looted 1 items.']
  end

  before do
    # tysong.xml is laid out for 55x234; at the spec default 24x80 its
    # main window would be off-screen.
    allow(Curses).to receive_messages(lines: 55, cols: 234)
    allow(ProfanityLog).to receive(:write) { |context, message, **| errors << "#{context}: #{message}" }
    GagPatterns.load_defaults
    expect(SettingsLoader.load(tysong, {}, {}, proc {})).to be_nil
    # Loading with no key actions logs every binding; only what the game
    # text logs matters here.
    errors.clear
    event_bus.on(:stream_text) { |data| shown << [data[:stream], data[:text], data[:colors]] unless data[:text].empty? }
  end

  # Load tysong.xml's layout, with +extra_windows+ (layout XML) added to
  # it in a copy of the file, and subscribe the windows to the bus. The
  # copy goes in a directory of its own, removed after loading, so it
  # doesn't stay in the home directory every example shares.
  def load_layout(extra_windows = nil)
    if extra_windows
      Dir.mktmpdir('tysong-plus') do |dir|
        path = File.join(dir, 'tysong_plus.xml')
        File.write(path, File.read(tysong).sub('</layout>', "#{extra_windows}</layout>"))
        expect(SettingsLoader.load(path, {}, {}, proc {})).to be_nil
      end
    end
    wm.load_layout('default')
    wm.subscribe_to_events(event_bus)
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    allow(processor).to receive(:show_disconnect_message)
    allow(processor).to receive(:exit)
    processor.run(fake_server(lines))
  end

  # A socket that yields +lines+ as the game sends them, then EOF.
  def fake_server(lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    # The first prompt sends 'look'.
    server.define_singleton_method(:puts) { |*| nil }
    server.define_singleton_method(:flush) { nil }
    allow(IO).to receive(:select).and_return(nil)
    server
  end

  # The main window's rows after +lines+ run through a fresh window
  # manager and processor on tysong.xml's layout.
  def main_rows_of_fresh_run(lines)
    other_wm = WindowManager.new
    other_bus = EventBus.new
    other_wm.load_layout('default')
    other_wm.subscribe_to_events(other_bus)
    other = GameTextProcessor.new(
      window_mgr: other_wm, shared_state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: other_bus, game_rules: Games.rules_for('GS')
    )
    allow(other).to receive(:show_disconnect_message)
    allow(other).to receive(:exit)
    other.run(fake_server(lines))
    visible_rows(other_wm.stream['main'])
  end

  def visible_rows(window)
    window.rows.map(&:rstrip).reject(&:empty?)
  end

  def main_rows
    visible_rows(wm.stream['main'])
  end

  # The colors of the main-window emit of +text+.
  def main_colors_of(text)
    shown.find { |stream, shown_text, _| stream == 'main' && shown_text == text }&.last
  end

  describe 'with the bundled tysong.xml layout (no loot window)' do
    before { load_layout }

    it 'has no window for the loot stream' do
      expect(wm.stream).not_to have_key('loot')
    end

    it 'shows the loot results in main, between the line before them and the prompt after them' do
      receive_from_server(*loot_room)

      expect(main_rows).to eq [loot_room.first, *loot_rows, '>', 'You have no silver with you.']
      expect(errors).to be_empty
    end

    # GSF-Pickasso/2026-10-01_21-02-04.xml:5889-5900, a box search (the
    # first line trimmed to its last sentence; 306 of the 2,539 blocks
    # follow a box search).
    it 'shows a box search with items stowed in two containers' do
      receive_from_server(
        'You search through an iron-bound tanik trunk and remove a few items of note which you promptly stow away.',
        "<pushStream id='loot'/>",
        'You search through an <a exist="558042139" noun="trunk">iron-bound tanik trunk</a> and find:',
        '  (stowed in a <a exist="513672676" noun="pouch">sloppy ruby red pouch</a>)',
        '   a <a exist="558042144" noun="spinel">pink spinel</a>',
        '  (stowed in an <a exist="513672616" noun="cloak">embroidered sage green silk cloak</a>)',
        '   a <a exist="558042142" noun="statue">small statue</a>',
        '   a <a exist="558042143" noun="statue">carved haon gryphon statue</a>',
        '   a <a exist="558042140" noun="ingot">bright gold ingot</a>',
        'Looted 4 items.',
        "<popStream id='loot'/>",
        '<prompt time="1790903228">&gt;</prompt>',
        'You could discard items in an <a exist="66050" noun="wastebarrel">iron-bound driftwood wastebarrel</a>.'
      )

      expect(main_rows).to eq ['You search through an iron-bound tanik trunk and remove a few items of note which ' \
                               'you promptly stow away.',
                               'You search through an iron-bound tanik trunk and find:',
                               '  (stowed in a sloppy ruby red pouch)', '   a pink spinel',
                               '  (stowed in an embroidered sage green silk cloak)', '   a small statue',
                               '   a carved haon gryphon statue', '   a bright gold ingot', 'Looted 4 items.', '>',
                               'You could discard items in an iron-bound driftwood wastebarrel.']
    end

    # Wizard users see the loot results as main text (Lich's sf_to_wiz
    # strips only the stream tags); so does the main window here, the
    # pending prompt included.
    it 'shows the loot results, and the prompts around them, as it shows the same lines sent as main text' do
      session = ['<prompt time="1790902955">&gt;</prompt>', *loot_room.drop(1)]
      receive_from_server(*session)

      expect(main_rows).to eq ['>', *loot_rows, '>', 'You have no silver with you.']
      expect(main_rows).to eq main_rows_of_fresh_run(session.reject { |line| line.include?('Stream id=') })
    end

    it 'applies highlights to the loot results' do
      HIGHLIGHT[/violet sapphire/] = ['ff00ff', nil, nil]

      receive_from_server(*loot_room)

      expect(main_colors_of('   a violet sapphire')).to include(a_hash_including(start: 5, end: 20, fg: 'ff00ff'))
    end

    it 'keeps the item and container links clickable with links on' do
      state.blue_links = true

      receive_from_server(*loot_room)

      expect(main_colors_of('  (stowed in a sturdy dark leather gem pouch)'))
        .to eq [{ start: 15, fg: '5555ff', bg: nil, cmd: 'look #513692462', end: 44 }]
      expect(main_colors_of('   a violet sapphire')).to eq [{ start: 5, fg: '5555ff', bg: nil, cmd: 'look #558041195', end: 20 }]
    end

    it 'adds no colour of its own: tysong.xml has no loot preset' do
      receive_from_server(*loot_room)

      expect(main_colors_of('Looted 1 items.')).to eq []
    end

    it "colours the loot results with a 'loot' preset when the settings have one" do
      PRESET['loot'] = ['aaaa00', nil]

      receive_from_server(*loot_room)

      expect(main_colors_of('Looted 1 items.')).to eq [{ start: 0, fg: 'aaaa00', bg: nil, end: 15 }]
    end

    # The server sends no main copy of loot text (0 of 2,539 blocks), so
    # the next main line is never taken for one: the same text again in
    # main is shown again.
    it 'shows a main line identical to the last loot line' do
      receive_from_server(*loot_room.first(7), 'Looted 1 items.')

      expect(main_rows.last(2)).to eq ['Looted 1 items.', 'Looted 1 items.']
    end

    it 'shows the main copy of a speech line that came before the loot results' do
      # The speech window's line is the stored one; loot text shown in
      # main in between uses it up, as any other stream falling back does.
      receive_from_server("<pushStream id='speech'/>You say, \"Done.\"", "<popStream id='speech'/>",
                          *loot_room.drop(1).first(6), 'You say, "Done."')

      expect(visible_rows(wm.stream['speech'])).to eq ['You say, "Done."']
      expect(main_rows.last).to eq 'You say, "Done."'
    end

    it 'returns to main after the loot block (main text after the pop is main text)' do
      receive_from_server(*loot_room)

      expect(shown.map(&:first).uniq).to eq ['main']
      expect(shown.map { |_, text, _| text }.last).to eq 'You have no silver with you.'
    end

    it 'shows a loot block closed by a bare popStream' do
      receive_from_server(*loot_room.first(6), '<popStream/>', 'You have no silver with you.')

      expect(main_rows).to eq [loot_room.first, *loot_rows, 'You have no silver with you.']
    end

    # GSF-Pickasso/2026-10-01_21-02-04.xml:7038-7041, and
    # GSF-Pickasso/2026-10-01_22-27-57.xml:15808-15810 (trimmed after the
    # <right> tag).
    it 'still drops bounty and reserve updates' do
      receive_from_server(
        "<streamWindow id='bounty' title='Bounties' scroll='manual' resident='true' ifClosed='' location='right'/>",
        "<clearStream id='bounty'/><pushStream id='bounty'/>",
        'You are not currently assigned a task.',
        "<popStream id='bounty'/>",
        "<clearStream id='reserve' ifClosed=''/><pushStream id='reserve'/>You have the following items reserved for combat:",
        '  Slot 1: (empty)',
        '<popStream/>',
        'You are not currently in a group.'
      )

      expect(main_rows).to eq ['You are not currently in a group.']
      expect(shown.map(&:first)).to eq ['main']
    end
  end

  describe 'with a loot window' do
    it 'shows the loot results in the loot window and not in main' do
      load_layout("<window class='text' top='0' left='0' height='10' width='60' value='loot'/>")

      receive_from_server(*loot_room)

      expect(visible_rows(wm.stream['loot'])).to eq loot_rows
      expect(main_rows).to eq [loot_room.first, '>', 'You have no silver with you.']
    end

    it 'shows the loot results in a tab named loot' do
      load_layout("<window class='tabbed' top='0' left='0' height='10' width='60' value='loot,bounty'/>")

      receive_from_server(*loot_room)

      expect(visible_rows(wm.stream['loot'])).to include(*loot_rows)
      expect(main_rows).not_to include(*loot_rows)
    end
  end

  describe "with loot listed in main's window" do
    it 'shows the loot results in main once' do
      LAYOUT['main-loot'] = REXML::Document.new(
        "<layout><window class='text' top='0' left='0' height='20' width='100' value='main,loot'/></layout>"
      ).root
      wm.load_layout('main-loot')
      wm.subscribe_to_events(event_bus)

      receive_from_server(*loot_room)

      expect(main_rows).to eq [loot_room.first, *loot_rows, '>', 'You have no silver with you.']
      expect(shown.map(&:first).count('loot')).to eq 4
    end
  end
end
