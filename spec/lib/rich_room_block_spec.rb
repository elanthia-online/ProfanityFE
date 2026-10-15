# frozen_string_literal: true

# What the user sees of a DragonRealms room in each of the two streams the
# game sends, from real lines (spec/fixtures/room_pipeline/dr_old_* and
# dr_rich_*, player names replaced):
#
# - the old stream (Lich 5.22.0): the roomName style, the roomDesc preset
#   and the "You also see" / "Also here:" / "Obvious paths:" lines on
#   main, then <compass> with a <dir> per exit;
# - the rich stream (the stream the game sends when Lich identifies as the
#   Saga client): the whole room on one line, <room><name/><description/>
#   <exists/><players/><exits/><extra/></room>, with no style, preset or
#   <dir> tags, and an <a exist> link around every object and player.
#
# Both send the room components (room desc, objs, players, exits) on a
# move. Profanity has to show a room alike from either stream. The rich
# examples marked pending describe what the user should see; they fail
# until the rich stream is read (spec policy: AUDIT §0.2).

require_relative '../spec_helper'
require_relative '../support/screen_replay'

RSpec.describe 'A DragonRealms room from the old and the rich stream' do
  include ScreenReplay

  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }

  before { stub_screen }
  after { restore_screen }

  let(:greengrove_desc) do
    ['The trees here are uniform and have all the appearance of being trimmed by art or artifice.  They',
     'almost take on the shapes of the very woodland creatures that cavort among them.  One especially',
     'fine beech tree has clay watering pots filled with wine resting among its roots.']
  end

  describe 'the old stream' do
    it 'shows a move in brief mode in the room window and in main, and lights the compass' do
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_old_move_greengrove'))

      expect(room_screen).to eq ['{[Bosque Deriel, Greengrove] (230006):green}',
                                 'You also see a deed register.',
                                 'Obvious paths: south, northwest.']
      expect(main_screen).to eq ['You stroll southeast.',
                                 '{[Bosque Deriel, Greengrove] (230006):green}',
                                 'You also see a deed register.',
                                 'Obvious paths: south, northwest.']
      expect(compass_lit).to eq %w[s nw]
      expect(state.room_title).to eq 'Bosque Deriel, Greengrove (230006)'
    end

    it 'shows the room a FLAG DESCRIPTION re-sends in place, with its players in the indicator' do
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_old_view_in_place'))

      expect(room_screen.first).to eq '{[Jeol\'gelvmoraen, Ice Grottos] (4217404):green}'
      expect(room_screen).to include('Also here: Traveler Jorvin and Chieftain Ilmar.',
                                     'Obvious exits: north, west, northwest.')
      expect(indicator).to eq 'Jorvin, Ilmar'
      expect(compass_lit).to eq %w[n w nw]
    end
  end

  describe 'the rich stream' do
    it 'shows a move in the room window and as one line per part in main' do
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(room_screen).to eq ['{[Bosque Deriel, Greengrove] (230006):green}',
                                 *greengrove_desc,
                                 'You also see a deed register.',
                                 'Obvious paths: south, northwest.']
      expect(main_screen).to eq ['You stroll southeast.',
                                 '{[Bosque Deriel, Greengrove] (230006):green}',
                                 *greengrove_desc,
                                 'You also see a deed register.',
                                 'Obvious paths: south, northwest.']
      expect(state.room_title).to eq 'Bosque Deriel, Greengrove (230006)'
    end

    it 'shows a LOOK, which sends no subtitle, in the room window and the indicator' do
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_look'))

      expect(room_screen.first).to eq '{[Jeol\'gelvmoraen, Ice Grottos] (4217404):green}'
      expect(room_screen).to include('Also here: Monster Aldric and Mountaineer Brannoc.',
                                     'Obvious exits: north, west, northwest.')
      expect(indicator).to eq 'Aldric, Brannoc'
      expect(state.room_title).to eq 'Jeol\'gelvmoraen, Ice Grottos (4217404)'
    end

    it 'shows the room a FLAG DESCRIPTION re-sends in place, with its players in the indicator' do
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_view_in_place'))

      expect(room_screen.first).to eq '{[Bosque Deriel, Hermit\'s Shacks] (230008):green}'
      expect(room_screen.last(2)).to eq ['Also here: Shadow Priest Corvel, Dunmar and Druid Ebrin.',
                                         'Obvious paths: north, south.']
      expect(indicator).to eq 'Corvel, Dunmar, Ebrin'
    end

    it 'keeps the room lines out of main under --room-window-only' do
      state.room_window_only = true
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(room_screen.last).to eq 'Obvious paths: south, northwest.'
      expect(main_rows).to eq ['You stroll southeast.']
    end

    it 'shows the room in main without a room window, and the players in the indicator' do
      load_layout(room_window: false)

      receive_from_server(*fixture('room_pipeline', 'dr_rich_view_in_place'))

      expect(main_rows.first(3)).to eq ['You will no longer see room descriptions.', 'R>',
                                        '[Bosque Deriel, Hermit\'s Shacks] (230008)']
      expect(main_rows).to include('Obvious paths: north, south.')
      expect(indicator).to eq 'Corvel, Dunmar, Ebrin'
    end

    # The components carry a move in both streams, so the room window shows
    # it alike already; the rich stream always sends the description.
    it 'shows a move to the same room alike in the room window from either stream' do
      load_layout
      receive_from_server(*fixture('room_pipeline', 'dr_old_move_greengrove'))
      old_room = room_screen

      load_layout
      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(room_screen - greengrove_desc).to eq old_room
    end

    # Synthetic lines, in the rich stream's form, for cases the session
    # didn't show: a block's parts are read from what its tags say.
    describe 'synthetic blocks' do
      # A view in place of the room the move named, with nothing in it
      def block(name: '[Bosque Deriel, Greengrove] (230006)', description: '', exits: 'Obvious paths: south.')
        "<resource picture=\"0\"/><room><name>#{name}</name><description>#{description}</description>" \
          "<exists></exists><players></players><exits>#{exits}</exits><extra></extra></room>"
      end

      it 'clears the description for a block with an empty one' do
        load_layout

        receive_from_server(*fixture('room_pipeline', 'dr_rich_move'), block, '<prompt time="1">&gt;</prompt>')

        expect(room_screen).to eq ['{[Bosque Deriel, Greengrove] (230006):green}', 'Obvious paths: south.']
      end

      it 'shows nothing new for a block whose exits part is empty' do
        load_layout
        receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))
        moved = room_screen

        receive_from_server(block(name: '[Elsewhere] (1)', description: 'Nowhere.', exits: ''),
                            '<prompt time="1">&gt;</prompt>')

        expect(room_screen).to eq moved
      end

      it 'leaves no capture for the next line after a block cut off at the end of its line' do
        load_layout

        receive_from_server('<room><name>[Cut, Short] (5)</name><description>Half of a', 'A goblin arrives.')

        expect(main_rows.last).to eq 'A goblin arrives.'
      end

      it 'reads a name tag outside a block as text' do
        load_layout

        receive_from_server('<name>Bob</name> waves.')

        expect(main_rows).to eq ['Bob waves.']
        expect(state.room_title).to eq ''
      end

      it 'shows a block for another room after a move, as Locate sends one, in the familiar window' do
        load_layout(extra: "<window class='text' top='5' left='0' height='10' width='100' value='familiar'/>")
        receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))
        moved = room_screen

        receive_from_server(block(name: '[Somewhere Else, Far Hall] (999999)', description: 'A far hall.',
                                  exits: 'Obvious paths: <d>east</d>.'), '<prompt time="1">&gt;</prompt>')

        expect(room_screen).to eq moved
        expect(window_text('familiar')).to eq ['[Somewhere Else, Far Hall] (999999)', 'A far hall.',
                                               'Obvious paths: east.']
        expect(state.room_title).to eq 'Bosque Deriel, Greengrove (230006)'
        expect(compass_lit).to eq %w[s nw]
      end
    end

    describe 'the compass' do
      it 'lights the compass from the exits' do
        load_layout

        receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

        expect(compass_lit).to eq %w[s nw]
      end

      it 'darkens the compass in a room with no exits' do
        load_layout

        receive_from_server(*fixture('room_pipeline', 'dr_rich_move'), *fixture('room_pipeline', 'dr_rich_no_exits'))

        expect(compass_lit).to eq []
      end

      it 'lights the compass for a LOOK without a room window' do
        load_layout(room_window: false)

        receive_from_server(*fixture('room_pipeline', 'dr_rich_look'))

        expect(compass_lit).to eq %w[n w nw]
      end

      it 'follows an exits component sent on its own, despite its empty <compass> (synthetic)' do
        load_layout

        receive_from_server(*fixture('room_pipeline', 'dr_rich_move'),
                            "<component id='room exits'>Obvious paths: <d>north</d>.<compass></compass></component>")

        expect(compass_lit).to eq %w[n]
      end

      it "keeps GemStone's own compass directions (--game GS)" do
        load_layout(game_rules: Games::GemStone)

        receive_from_server(*fixture('room_pipeline', 'gs_move'))

        expect(compass_lit).to eq %w[n s]
      end
    end
  end
end
