# frozen_string_literal: true

# --game: with a game code, GameTextProcessor applies only that game's
# rules (Games.rules_for), so the other game's death, logon, stun and
# spell-name rules never see a line. Raw server lines go through the real
# GameTextProcessor#run. Without --game both games' rules run, as pinned
# line by line in game_rules_processing_spec.rb.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/games'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'GameTextProcessor with one game\'s rules (--game)' do
  let(:event_bus) { EventBus.new }
  let(:wm) do
    windows = %w[main death logons percWindow].to_h { |id| [id, Object.new] }
    Struct.new(:stream, :indicator, :progress, :countdown, :room,
               :command_window, :command_window_layout).new(windows, {}, {}, {}, {}, nil, nil)
  end
  let(:shown) { [] }
  let(:stuns) { [] }

  before do
    event_bus.on(:stream_text) { |data| shown << data }
    event_bus.on(:stun) { |data| stuns << data[:seconds] }
  end

  # A processor with the rules --game=+code+ selects (nil: no --game).
  def processor_for(code)
    GameTextProcessor.new(
      window_mgr: wm,
      shared_state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus,
      clock: Clock.new(now: -> { Time.new(2026, 9, 29, 9, 5, 7) }),
      game_rules: Games.rules_for(code)
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(code, *lines)
    processor = processor_for(code)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    allow(IO).to receive(:select).and_return(nil)
    allow(processor).to receive(:show_disconnect_message)
    allow(processor).to receive(:exit)
    processor.run(server)
  end

  # Send +text+ on +stream+ (a pushStream/popStream pair, as the game does).
  def receive_on(code, stream, text)
    receive_from_server(code, "<pushStream id=\"#{stream}\"/>#{text}", '<popStream/>')
  end

  # Every text shown on +stream+, empty ones included.
  def lines_on(stream)
    shown.select { |data| data[:stream] == stream }.map { |data| data[:text] }
  end

  bloodriven = ' * Mahtra failed within the Bank at Bloodriven!'
  raise_dead = 'Deep and resonating, you feel the chant that falls from your lips.'
  shadow_valley = 'Just as you think the falling will never end, you crash through an ethereal barrier ' \
                  'which bursts into a dazzling kaleidoscope of color!  Your sensation of falling turns to ' \
                  'dizziness and you feel unusually heavy for a moment.  Everything seems to stop for a ' \
                  'prolonged second and then WHUMP!!!'

  describe '--game=GS' do
    it 'shows the "!"-terminated Bloodriven bank death with its area code' do
      receive_on('GS', 'death', bloodriven)

      expect(lines_on('death')).to eq ['09:05 Mahtra DR-B']
    end

    {
      ' * Mahtra just bit the dust!'                                   => '09:05 Mahtra WL',
      ' * Bob may just be going home on his shield!'                   => '09:05 Bob RED',
      ' * Mahtra failed within the Bank at Bloodriven'                 => '09:05 Mahtra DR-B',
      ' * Mahtra was just defeated during round 12 in Duskruin Arena!' => '09:05 Mahtra DR-A',
    }.each do |line, expected|
      it "still shows #{line.strip.inspect} as #{expected.inspect}" do
        receive_on('GS', 'death', line)

        expect(lines_on('death')).to eq [expected]
      end
    end

    it 'still hides a vaporized character' do
      receive_on('GS', 'death', ' * Mahtra has been vaporized!')

      expect(lines_on('death')).to eq ['']
    end

    # DR's death rules no longer run: each line is shown as sent, no time
    [
      ' * Hawthrick was just struck down!',
      ' * Mahtra just disintegrated!',
      ' * Mahtra was lost to the Plane of Exile!',
      " * A fiery phoenix soars into the heavens as Mahtra's spirit arises from the ashes of death.",
      ' * Mahtra was smote by Kertigen!',
      ' * Mahtra failed within the Temple of Hodierna!',
      ' * Mahtra was just sacrificed to Harawep!',
    ].each do |line|
      it "shows the DragonRealms death #{line.strip.inspect} as sent" do
        receive_on('GS', 'death', line)

        expect(lines_on('death')).to eq [line]
      end
    end

    it 'still rewrites a logon message GemStone sends' do
      receive_on('GS', 'logons', ' * Mahtra has disconnected.')

      expect(lines_on('logons')).to eq ['09:05 Mahtra']
      expect(shown.last[:colors]).to eq [{ start: 0, end: 5, fg: 'aa7733' }]
    end

    it 'shows a DragonRealms-only logon message as sent' do
      receive_on('GS', 'logons', ' * Mahtra just crawled into the adventure.')

      expect(lines_on('logons')).to eq [' * Mahtra just crawled into the adventure.']
    end

    it 'does not stun on the DragonRealms Raise Dead and Shadow Valley messages' do
      receive_from_server('GS', raise_dead, shadow_valley)

      expect(stuns).to be_empty
    end

    it 'still stuns on "You are stunned for N rounds", which is not a per-game rule' do
      receive_from_server('GS', 'You are stunned for 3 rounds!')

      expect(stuns).to eq [15]
    end

    it 'does not shorten DragonRealms spell names' do
      receive_on('GS', 'percWindow', 'Turmar Illumination  (6 roisaen)')

      expect(lines_on('percWindow')).to eq ['Turmar Illumination (6 roisaen)']
    end
  end

  describe '--game=DR' do
    it 'shows the "!"-terminated Bloodriven bank death as a DragonRealms death' do
      receive_on('DR', 'death', bloodriven)

      expect(lines_on('death')).to eq ['09:05 Mahtra']
    end

    {
      ' * Hawthrick was just struck down!'                                                           => '09:05 Hawthrick',
      " * A fiery phoenix soars into the heavens as Mahtra's spirit arises from the ashes of death." => '09:05 Mahtra MF',
      ' * Mahtra was just sacrificed to Harawep!'                                                    => '09:05 Mahtra Sacrifice',
    }.each do |line, expected|
      it "still shows #{line.strip.inspect} as #{expected.inspect}" do
        receive_on('DR', 'death', line)

        expect(lines_on('death')).to eq [expected]
      end
    end

    # GemStone's death patterns, area table and suppression no longer run
    [
      ' * Mahtra just bit the dust!',
      ' * The death cry of Mahtra echoes in your mind!',
      ' * Bob may just be going home on his shield!',
      ' * Mahtra failed within the Bank at Bloodriven',
      ' * Mahtra has been vaporized!',
      ' * Mahtra was just incinerated!',
    ].each do |line|
      it "shows the GemStone death #{line.strip.inspect} as sent" do
        receive_on('DR', 'death', line)

        expect(lines_on('death')).to eq [line]
      end
    end

    it 'still rewrites DragonRealms logon messages' do
      receive_on('DR', 'logons', ' * Mahtra just crawled into the adventure.')

      expect(lines_on('logons')).to eq ['09:05 Mahtra']
      expect(shown.last[:colors]).to eq [{ start: 0, end: 5, fg: '007700' }]
    end

    it 'still stuns on Raise Dead and the Shadow Valley' do
      receive_from_server('DR', raise_dead, shadow_valley)

      expect(stuns).to eq [30.6, 16.2]
    end

    it 'still shortens spell names' do
      receive_on('DR', 'percWindow', 'Turmar Illumination  (6 roisaen)')

      expect(lines_on('percWindow')).to eq ['TURI (6 roisaen)']
    end
  end

  describe 'no --game' do
    it 'runs both games\' rules, DragonRealms first, as without the option' do
      expect(Games.rules_for(nil)).to be Games::BOTH_GAMES

      receive_on(nil, 'death', bloodriven)
      receive_on(nil, 'death', ' * Mahtra just bit the dust!')

      expect(lines_on('death')).to eq ['09:05 Mahtra', '09:05 Mahtra WL']
    end
  end

  describe 'Games.rules_for' do
    it 'refuses a code no game starts with' do
      expect { Games.rules_for('XX') }.to raise_error(ArgumentError, /unknown game code: "XX"/)
    end
  end
end
