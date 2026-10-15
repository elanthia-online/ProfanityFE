# frozen_string_literal: true

# The DragonRealms spell list and combat lines in each of the two streams
# the game sends, from real lines (spec/fixtures/rich_stream/, player
# names replaced):
#
# - the old stream (Lich 5.22.0) clears the spell window with
#   <clearStream id="percWindow"/> and sends the list inside
#   <pushStream id="percWindow"/>...<popStream/>; combat lines come inside
#   <pushStream id="combat" />;
# - the rich stream (the stream the game sends when Lich identifies as the
#   Saga client): what reaches Profanity depends on the Lich build. In the
#   session these fixtures come from, the list was pushed once, at login;
#   every later refresh was the clear followed by the spell lines with no
#   pushStream, sometimes after other lines, and no combat pushStream came.
#   In a session on another Lich build, every refresh and every combat line
#   came pushed, as in the old stream.
#
# A bare refresh's spell lines go to the spell window, from the clear up to
# the next prompt or percWindow pushStream. Combat lines that come with no
# combat pushStream stay in main: nothing else marks them.

require_relative '../spec_helper'
require_relative '../support/screen_replay'

RSpec.describe 'The DragonRealms spell list and combat lines from the old and the rich stream' do
  include ScreenReplay

  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:windows) do
    "<window class='percWindow' top='4' left='0' height='20' width='40' value='percWindow'/>" \
      "<window class='text' top='5' left='0' height='20' width='100' value='combat'/>"
  end
  let(:spells) do
    ['Bless  (OM)', 'Auspice  (OM)', 'Divine Radiance  (OM)', 'Shield of Light  (OM)', "Glythtide's Gift  (OM)",
     'Benediction  (OM)', 'Centering  (OM)', 'Starry Waters  (OM)', 'Visage  (OM)', 'Persistence of Mana  (OM)']
  end
  # The spell window's rows for +spells+: the spell abbreviations applied,
  # in the order the game sent them.
  let(:spell_rows) do
    ['Bless (OM)', 'Auspice (OM)', 'DR (OM)', 'SOL (OM)', 'GG (OM)', 'Benediction (OM)', 'Centering (OM)',
     'STAW (OM)', 'Visage (OM)', 'POM (OM)']
  end

  before { stub_screen }
  after { restore_screen }

  describe 'the old stream' do
    it 'shows a pushed spell list in the spell window' do
      load_layout(room_window: false, extra: windows)

      receive_from_server(*fixture('rich_stream', 'dr_old_perc_pushed'))

      expect(window_text('percWindow')).to eq ['OM (91%)', 'POM (OM)', 'Bless (OM)', 'Auspice (OM)', 'DR (OM)',
                                               'SOL (OM)', 'GG (OM)', 'Benediction (OM)', 'Centering (OM)',
                                               'STAW (OM)', 'Visage (OM)']
      expect(main_rows).to be_empty
    end

    it 'shows combat lines in the combat window' do
      load_layout(room_window: false, extra: windows)

      receive_from_server(*fixture('rich_stream', 'dr_old_combat'))

      expect(window_text('combat')).to eq ["Jorvin's foot lands a solid hit to the moradu's left arm."]
    end
  end

  describe 'the rich stream' do
    it 'shows the spell list it pushes at login in the spell window' do
      load_layout(room_window: false, extra: windows)

      receive_from_server(*fixture('rich_stream', 'dr_rich_perc_pushed'))

      expect(window_text('percWindow')).to eq ['OM (91%)', *spell_rows]
    end

    it 'shows a refresh with no pushStream in the spell window, and nothing of it in main' do
      load_layout(room_window: false, extra: windows)

      receive_from_server(*fixture('rich_stream', 'dr_rich_perc_bare'))

      expect(window_text('percWindow')).to eq spell_rows
      expect(main_rows).to eq ['>',
                               'Kestra drops a crust-covered driftwood strongbox into a portable silversteel ' \
                               'bucket with a flared',
                               '  rim.  He glances inside and draws back quickly from the sight.']
    end

    it 'takes the spell lines of a refresh that come after other lines, and leaves those lines in main' do
      load_layout(room_window: false, extra: windows)

      receive_from_server(*fixture('rich_stream', 'dr_rich_perc_split'))

      expect(window_text('percWindow')).to eq spell_rows
      expect(main_rows & spells).to be_empty
      expect(main_rows).to include('Roundtime: 1 sec.',
                                   'You tap into the mana from fifty of the surrounding streams and attempt to ' \
                                   'keep it channeling in')
    end

    it 'leaves a spell-shaped line after the refresh\'s prompt in main (synthetic)' do
      load_layout(room_window: false, extra: windows)

      receive_from_server(*fixture('rich_stream', 'dr_rich_perc_bare'), 'Sanctuary  (OM)')

      expect(window_text('percWindow')).to eq spell_rows
      expect(main_rows.last).to eq 'Sanctuary  (OM)'
    end

    it 'leaves a refresh in main when the game is GemStone (--game)' do
      load_layout(room_window: false, extra: windows, game_rules: Games::GemStone)

      receive_from_server(*fixture('rich_stream', 'dr_rich_perc_bare'))

      expect(window_text('percWindow')).to be_empty
      expect(main_rows.first).to eq 'Bless  (OM)'
    end

    it 'leaves a spell-shaped line in main after a pushed refresh, before its prompt (synthetic)' do
      load_layout(room_window: false, extra: windows)

      receive_from_server('<clearStream id="percWindow"/>', '<pushStream id="percWindow"/>Bless  (OM)',
                          '<popStream/>Sanctuary  (OM)', '<prompt time="1792032076">&gt;</prompt>')

      expect(window_text('percWindow')).to eq ['Bless (OM)']
      expect(main_rows).to include('Sanctuary  (OM)')
    end

    it 'leaves a spell-shaped line on another stream during a bare refresh on that stream (synthetic)' do
      load_layout(room_window: false, extra: windows)

      receive_from_server('<clearStream id="percWindow"/>', '<pushStream id="combat"/>Sanctuary  (OM)',
                          '<popStream/>Bless  (OM)', '<prompt time="1792032076">&gt;</prompt>')

      expect(window_text('combat')).to eq ['Sanctuary  (OM)']
      expect(window_text('percWindow')).to eq ['Bless (OM)']
    end

    it 'leaves a spell-shaped line in main after a clearStream of another stream (synthetic)' do
      load_layout(room_window: false, extra: windows)

      receive_from_server('<clearStream id="combat"/>', 'Bless  (OM)', '<prompt time="1792032076">&gt;</prompt>')

      expect(window_text('percWindow')).to be_empty
      expect(main_rows.first).to eq 'Bless  (OM)'
    end

    it 'shows combat lines that come with no combat pushStream in main' do
      load_layout(room_window: false, extra: windows)

      receive_from_server(*fixture('rich_stream', 'dr_rich_combat'))

      expect(window_text('combat')).to be_empty
      expect(main_rows).to eq ["Aldric's greatsword lands a massive strike to a jeol moradu's left arm!",
                               "Aldric's greatsword lands a very heavy hit to a jeol moradu's left arm!"]
    end
  end
end
