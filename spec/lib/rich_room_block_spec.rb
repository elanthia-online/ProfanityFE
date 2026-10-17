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
      pending 'the <room> block is not read yet'
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
      pending 'the <room> block is not read yet'
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_look'))

      expect(room_screen.first).to eq '{[Jeol\'gelvmoraen, Ice Grottos] (4217404):green}'
      expect(room_screen).to include('Also here: Monster Aldric and Mountaineer Brannoc.',
                                     'Obvious exits: north, west, northwest.')
      expect(indicator).to eq 'Aldric, Brannoc'
      expect(state.room_title).to eq 'Jeol\'gelvmoraen, Ice Grottos (4217404)'
    end

    it 'shows the room a FLAG DESCRIPTION re-sends in place, with its players in the indicator' do
      pending 'the <room> block is not read yet'
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_view_in_place'))

      expect(room_screen.first).to eq '{[Bosque Deriel, Hermit\'s Shacks] (230008):green}'
      expect(room_screen.last(2)).to eq ['Also here: Shadow Priest Corvel, Dunmar and Druid Ebrin.',
                                         'Obvious paths: north, south.']
      expect(indicator).to eq 'Corvel, Dunmar, Ebrin'
    end

    it 'keeps the room lines out of main under --room-window-only' do
      pending 'the <room> block is not read yet'
      state.room_window_only = true
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(room_screen.last).to eq 'Obvious paths: south, northwest.'
      expect(main_rows).to eq ['You stroll southeast.']
    end

    it 'shows the room in main without a room window, and the players in the indicator' do
      pending 'the <room> block is not read yet'
      load_layout(room_window: false)

      receive_from_server(*fixture('room_pipeline', 'dr_rich_view_in_place'))

      expect(main_rows.first(3)).to eq ['You will no longer see room descriptions.', 'R>',
                                        '[Bosque Deriel, Hermit\'s Shacks] (230008)']
      expect(main_rows).to include('Obvious paths: north, south.')
      expect(indicator).to eq 'Corvel, Dunmar, Ebrin'
    end

    # The components carry a move in both streams, so the room window shows
    # it alike already, except that the rich stream always sends the
    # description, which shows under the name. (This is the only example
    # not pending that pins the description in the room window.)
    it 'shows a move to the same room alike in the room window from either stream' do
      load_layout
      receive_from_server(*fixture('room_pipeline', 'dr_old_move_greengrove'))
      old_room = room_screen

      load_layout
      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(room_screen).to eq [old_room.first, *greengrove_desc, *old_room.drop(1)]
    end

    it 'lights the compass from the exits' do
      pending 'the compass is not lit from the exits yet'
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(compass_lit).to eq %w[s nw]
    end
  end
end
