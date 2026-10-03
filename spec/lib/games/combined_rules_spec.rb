# frozen_string_literal: true

# The per-game rules objects GameTextProcessor asks (Games::Rules): each
# game on its own, and Games::CombinedRules asking them in turn.

require_relative '../../spec_helper'
require 'rexml/document'
require_relative '../../../lib/games/dragonrealms'
require_relative '../../../lib/games/gemstone'
require_relative '../../../lib/games/combined_rules'
require_relative '../../../lib/games'
require_relative '../../../lib/game_text_processor'
require_relative '../../../lib/shared_state'

RSpec.describe Games::CombinedRules do
  # A "!"-terminated Bloodriven bank death: DR's "failed within .*!"
  # catch-all and GS's DR-B entry both match it (AUDIT 6a Q7).
  let(:bloodriven) { ' * Mahtra failed within the Bank at Bloodriven!' }
  let(:both) { described_class.new(Games::DragonRealms, Games::GemStone) }

  describe 'each game on its own' do
    it 'gives the Bloodriven line to DragonRealms as a plain name' do
      expect(Games::DragonRealms.death_summary(bloodriven)).to eq 'Mahtra'
    end

    it 'gives the Bloodriven line to GemStone with its area code' do
      expect(Games::GemStone.death_summary(bloodriven)).to eq 'Mahtra DR-B'
    end

    it 'leaves a GemStone-only death line alone in DragonRealms' do
      expect(Games::DragonRealms.death_summary(' * Mahtra just bit the dust!')).to be_nil
    end

    it 'leaves a DragonRealms-only death line alone in GemStone' do
      expect(Games::GemStone.death_summary(' * Mahtra was just struck down!')).to be_nil
    end

    it 'hides a vaporized character in GemStone with an empty entry' do
      expect(Games::GemStone.death_summary(' * Mahtra has been vaporized!')).to eq ''
    end

    it 'has a DragonRealms-only logon message only in DragonRealms' do
      line = ' * Mahtra just crawled into the adventure.'

      expect(Games::DragonRealms.logon(line)).to eq %w[Mahtra 007700]
      expect(Games::GemStone.logon(line)).to be_nil
    end

    it 'names a custom logon message from its links only in GemStone' do
      line = ' * A drunken Maylan falls to the ground.'

      expect(Games::DragonRealms.logon(line, link_nouns: %w[Maylan])).to be_nil
      expect(Games::GemStone.logon(line, link_nouns: %w[Maylan])).to eq ['Maylan', nil]
    end

    it 'has no stun or spell-name rules in GemStone' do
      expect(Games::GemStone.stun_seconds('Deep and resonating, you feel the chant that falls from your lips')).to be_nil
      expect(Games::GemStone.spell_abbreviation('Aesandry Darlaeth')).to be_nil
    end

    it 'answers nil for a line that is not the game\'s' do
      expect(Games::DragonRealms.stun_seconds('You swing a sword at a goblin.')).to be_nil
      expect(Games::DragonRealms.logon(' * Mahtra tiptoes in.')).to be_nil
    end
  end

  describe 'asking both games' do
    it 'takes the first game\'s answer when both have one' do
      expect(both.death_summary(bloodriven)).to eq 'Mahtra'
      expect(described_class.new(Games::GemStone, Games::DragonRealms).death_summary(bloodriven)).to eq 'Mahtra DR-B'
    end

    it 'asks the next game when the first has no answer' do
      expect(both.death_summary(' * Mahtra just bit the dust!')).to eq 'Mahtra WL'
    end

    it "passes a logon line's link nouns on to each game" do
      expect(both.logon(' * A drunken Maylan falls to the ground.', link_nouns: %w[Maylan])).to eq ['Maylan', nil]
      expect(both.logon(' * A drunken Maylan falls to the ground.')).to be_nil
    end

    it 'counts an empty entry as an answer' do
      expect(both.death_summary(' * Mahtra was just incinerated!')).to eq ''
    end

    it 'finds a room list cut short when any game marks it so, even after a game that says it is not' do
      marks_everything = Module.new do
        extend Games::Rules

        def self.room_list_cut_short?(_text) = true
      end

      expect(both.room_list_cut_short?('You also see a rock and some other stuff.')).to be true
      expect(both.room_list_cut_short?('You also see a rock and some junk.')).to be false
      expect(described_class.new(Games::DragonRealms, marks_everything).room_list_cut_short?('a rock and some junk.')).to be true
    end

    it 'answers nil when no game has an answer' do
      expect(both.death_summary(' * Mahtra fell off a cliff.')).to be_nil
      expect(both.logon(' * Mahtra tiptoes in.')).to be_nil
      expect(both.stun_seconds('You swing a sword at a goblin.')).to be_nil
      expect(both.spell_abbreviation('Frobnicate')).to be_nil
    end

    it 'answers nil for everything with no games' do
      none = described_class.new

      expect(none.death_summary(bloodriven)).to be_nil
      expect(none.spell_abbreviation('Aesandry Darlaeth')).to be_nil
    end

    it 'keeps the games in the order given' do
      expect(both.games).to eq [Games::DragonRealms, Games::GemStone]
    end
  end

  describe 'GameTextProcessor' do
    let(:event_bus) { EventBus.new }
    let(:wm) do
      Struct.new(:stream, :indicator, :progress, :countdown, :room,
                 :command_window, :command_window_layout).new(
                   { 'main' => Object.new, 'death' => Object.new }, {}, {}, {}, {}, nil, nil
                 )
    end

    # What the death window shows for +line+ with +rules+.
    def death_window(line, rules = nil)
      options = rules ? { game_rules: rules } : {}
      processor = GameTextProcessor.new(
        window_mgr: wm, shared_state: SharedState.new.tap { |s| s.skip_server_time_offset = true },
        cmd_buffer: Struct.new(:window).new(nil), xml_escapes: {}, event_bus: event_bus,
        clock: Clock.new(now: -> { Time.new(2026, 9, 29, 9, 5, 7) }), **options
      )
      shown = []
      event_bus.on(:stream_text) { |data| shown << data[:text] if data[:stream] == 'death' }
      queue = ["<pushStream id=\"death\"/>#{line}\r\n", "<popStream/>\r\n"]
      server = Object.new
      server.define_singleton_method(:gets) { queue.shift&.dup }
      allow(IO).to receive(:select).and_return(nil)
      allow(processor).to receive(:show_disconnect_message)
      allow(processor).to receive(:exit)
      processor.run(server)
      shown
    end

    it 'uses both games\' rules, DragonRealms first, by default' do
      expect(Games::BOTH_GAMES.games).to eq [Games::DragonRealms, Games::GemStone]
      expect(death_window(bloodriven)).to eq ['09:05 Mahtra']
    end

    it 'asks the rules it is given' do
      expect(death_window(bloodriven, Games::GemStone)).to eq ['09:05 Mahtra DR-B']
    end
  end
end
