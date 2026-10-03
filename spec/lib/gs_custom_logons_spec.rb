# frozen_string_literal: true

# GemStone's custom logon and logoff messages on the logons stream.
#
# Besides its three standard endings ("joins the adventure." and so on),
# GemStone IV prime announces some characters with a message of their own
# (219 of 4,810 logons in a 12-hour log, 102 different forms). The logons
# window shows each as "HH:MM Name", like a standard one: the name is the
# noun of the line's first link that names a player. The game doesn't say
# whether such a line is a logon or a logoff, so its time gets no type
# color. A line with no player link is shown as the game sent it.
#
# The lines below marked real are copied from GemStone session logs
# (corpus_streams), each followed by the pop the game sends on the next
# line; the others are built to probe the edges of the rule.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/games'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'GemStone custom logon messages' do
  let(:event_bus) { EventBus.new }
  let(:windows) { %w[main logons].to_h { |id| [id, Object.new] } }
  let(:wm) do
    Struct.new(:stream, :indicator, :progress, :countdown, :room,
               :command_window, :command_window_layout).new(windows, {}, {}, {}, {}, nil, nil)
  end
  let(:shown) { [] }

  before do
    event_bus.on(:stream_text) { |data| shown << data }
    allow(IO).to receive(:select).and_return(nil)
  end

  # A processor parsing into +window_mgr+ with the rules --game=+code+
  # selects (nil: no --game, both games' rules).
  def processor_for(code, window_mgr = wm)
    GameTextProcessor.new(
      window_mgr: window_mgr,
      shared_state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus,
      clock: Clock.new(now: -> { Time.new(2026, 10, 1, 21, 4, 7) }),
      game_rules: Games.rules_for(code)
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(code, *lines, window_mgr: wm)
    processor = processor_for(code, window_mgr)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |*| nil }
    server.define_singleton_method(:flush) { nil }
    allow(processor).to receive(:show_disconnect_message)
    allow(processor).to receive(:exit)
    processor.run(server)
  end

  # Send +text+ on the logons stream, and the game's pop on the next line.
  def receive_logon(code, text, window_mgr: wm)
    receive_from_server(code, "<pushStream id=\"logons\"/>#{text}", '<popStream/><prompt time="1790909031">s&gt;</prompt>',
                        window_mgr: window_mgr)
  end

  # The non-empty pieces of text shown on +stream+.
  def shown_on(stream)
    shown.select { |data| data[:stream] == stream && !data[:text].empty? }
  end

  # The non-empty texts shown on +stream+.
  def lines_on(stream)
    shown_on(stream).map { |data| data[:text] }
  end

  # Real: GSIV-Ilten/2026-10-01_21-00-59.xml:13795 (13 rows of the 19-column
  # window when shown as sent).
  maylan = ' * A drunken <a exist="-11031785" noun="Maylan">Maylan</a> falls to the ground with a belch and ' \
           'crawls off, <a exist="-11031785" noun="Maylan">her</a> mop-fringed pegleg leaving a trail of murky ' \
           'detritus best left undescribed behind <a exist="-11031785" noun="Maylan">her</a>.'
  maylan_text = ' * A drunken Maylan falls to the ground with a belch and crawls off, her mop-fringed pegleg ' \
                'leaving a trail of murky detritus best left undescribed behind her.'

  [['GS', '--game=GS'], [nil, 'no --game']].each do |code, label|
    context "with #{label}" do
      it 'shows a custom message as "HH:MM Name", the time in no type color (real)' do
        receive_logon(code, maylan)

        expect(lines_on('logons')).to eq ['21:04 Maylan']
        expect(shown_on('logons').last[:colors]).to eq []
      end

      # Real: GSIV-Ilten/2026-10-01_21-00-59.xml:13487, four links and
      # quotes in the text.
      it 'takes the name from the first of four links naming the same player (real)' do
        receive_logon(code, ' * A boisterous "YARRRR!" accompanies <a exist="-11031785" noun="Maylan">Maylan</a> ' \
                            'as <a exist="-11031785" noun="Maylan">she</a> smashes an empty bottle, which ' \
                            '<a exist="-11031785" noun="Maylan">she</a> swiftly sweeps away with ' \
                            '<a exist="-11031785" noun="Maylan">her</a> mop-fringed pegleg.')

        expect(lines_on('logons')).to eq ['21:04 Maylan']
      end

      # Real: GSIV-Ilten/2026-10-01_21-00-59.xml:7271. The link's text is
      # "her"; its noun is the name.
      it 'takes the name from the noun when the first link reads as a pronoun (real)' do
        receive_logon(code, ' * Gathering the folds of <a exist="-11086776" noun="Dirvy">her</a> bloodstained cloak, ' \
                            '<a exist="-11086776" noun="Dirvy">Dirvy</a> tiredly climbs a nearby tree for a nap.')

        expect(lines_on('logons')).to eq ['21:04 Dirvy']
      end

      # Real: GSIV-Ilten/2026-10-02_00-00-01.xml:431
      it 'takes the name, not the possessive, from a link that reads "Xred\'s" (real)' do
        receive_logon(code, %( * Trumpet blasts signal <a exist="-10241155" noun="Xred">Xred's</a> withdrawal from ) +
                            '<a exist="-10241155" noun="Xred">his</a> hunt.')

        expect(lines_on('logons')).to eq ['21:04 Xred']
      end

      # Real: GSF-Pickasso/2026-10-01_22-00-48.xml:1702,
      # GSIV-Ilten/2026-10-02_00-00-01.xml:24713 (exist="0") and
      # GSF-Pickasso/2026-10-01_23-21-09.xml:10841.
      {
        ' * <a exist="-11239946" noun="Airoo">Airoo</a> joins the adventure.'                   => ['21:04 Airoo', '007700'],
        ' * <a exist="0" noun="Doiran">Doiran</a> returns home from a hard day of adventuring.' => ['21:04 Doiran', '777700'],
        ' * <a exist="-11167205" noun="Trixie">Trixie</a> has disconnected.'                    => ['21:04 Trixie', 'aa7733']
      }.each do |line, (expected, fg)|
        it "keeps the standard form's type color: #{expected} in #{fg} (real)" do
          receive_logon(code, line)

          expect(lines_on('logons')).to eq [expected]
          expect(shown_on('logons').last[:colors]).to eq [{ start: 0, end: 5, fg: fg }]
        end
      end

      it "keeps the line's highlights on the short form, with no type color" do
        HIGHLIGHT[/Maylan/] = ['ff00ff', nil, nil]
        allow(HighlightProcessor).to receive(:get_color_pair_id).and_return(0)

        receive_logon(code, maylan)

        expect(lines_on('logons')).to eq ['21:04 Maylan']
        expect(shown_on('logons').last[:colors]).to contain_exactly(include(start: 6, end: 12, fg: 'ff00ff'))
      end

      it 'shows each of two custom messages in a row as its own short line (real, consecutive)' do
        receive_from_server(
          code,
          "<pushStream id=\"logons\"/>#{maylan}", '<popStream/><prompt time="1790909031">s&gt;</prompt>',
          '<pushStream id="logons"/> * Gathering the folds of <a exist="-11086776" noun="Dirvy">her</a> ' \
          'bloodstained cloak, <a exist="-11086776" noun="Dirvy">Dirvy</a> tiredly climbs a nearby tree for a nap.',
          '<popStream/><prompt time="1790909032">s&gt;</prompt>'
        )

        expect(lines_on('logons')).to eq ['21:04 Maylan', '21:04 Dirvy']
        expect(lines_on('main')).to eq []
      end

      # Built: the edges of "the first player link".
      it 'skips a link whose noun is not a name (an item) and takes the player link after it' do
        receive_logon(code, ' * Clutching <a exist="12345" noun="lantern">a lantern</a>, ' \
                            '<a exist="-11086776" noun="Dirvy">Dirvy</a> wanders off.')

        expect(lines_on('logons')).to eq ['21:04 Dirvy']
      end

      it 'shows a custom message whose only link is an item as sent' do
        receive_logon(code, ' * Clutching <a exist="12345" noun="lantern">a lantern</a>, Dirvy wanders off.')

        expect(lines_on('logons')).to eq [' * Clutching a lantern, Dirvy wanders off.']
      end

      it 'shows a custom message with no link as sent' do
        receive_logon(code, maylan.gsub(/<[^>]*>/, ''))

        expect(lines_on('logons')).to eq [maylan_text]
      end

      {
        'a link with no noun'                              => '<a exist="-11031785">Maylan</a>',
        'a link with an empty noun'                        => '<a exist="-11031785" noun="">Maylan</a>',
        'a noun not shaped like a name (all capitals)'     => '<a exist="-11031785" noun="MAYLAN">Maylan</a>',
        'a noun not shaped like a name (two words)'        => '<a exist="-11031785" noun="Maylan Bob">Maylan</a>',
        'a DragonRealms-style link with a cmd and no noun' => "<d cmd='look Maylan'>Maylan</d>"
      }.each do |what, link|
        it "shows a custom message whose only link is #{what} as sent" do
          receive_logon(code, " * A drunken #{link} falls to the ground.")

          expect(lines_on('logons')).to eq [' * A drunken Maylan falls to the ground.']
        end
      end

      it 'needs the " * " in front of a custom message too' do
        receive_logon(code, 'A drunken <a exist="-11031785" noun="Maylan">Maylan</a> falls to the ground.')

        expect(lines_on('logons')).to eq ['A drunken Maylan falls to the ground.']
      end

      it "doesn't shorten a custom message shown in main for want of a logons window" do
        windows.delete('logons')

        receive_logon(code, maylan)

        expect(lines_on('main')).to eq [maylan_text]
      end
    end
  end

  context 'with --game=DR' do
    it 'shows a GemStone custom message as sent' do
      receive_logon('DR', maylan)

      expect(lines_on('logons')).to eq [maylan_text]
    end

    it 'still shortens its own logon messages' do
      receive_logon('DR', ' * Mahtra just crawled into the adventure.')

      expect(lines_on('logons')).to eq ['21:04 Mahtra']
      expect(shown_on('logons').last[:colors]).to eq [{ start: 0, end: 5, fg: '007700' }]
    end
  end

  # The logons window of templates/tysong.xml: 19 columns wide.
  context 'in a 19-column logons window' do
    let(:tysong_logons) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='8' width='60' value='main'/>
          <window class='text' top='0' left='60' height='8' width='19' value='logons'/>
        </layout>
      XML
      WindowManager.new.tap do |manager|
        manager.load_layout('test')
        manager.subscribe_to_events(event_bus)
      end
    end

    it 'takes one row for a custom message instead of thirteen (real)' do
      receive_logon('GS', maylan, window_mgr: tysong_logons)

      expect(tysong_logons.stream['logons'].rows.first(2)).to eq ['21:04 Maylan', '']
    end
  end
end
