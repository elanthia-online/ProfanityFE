# frozen_string_literal: true

# DragonRealms' room description setting (FLAG DESCRIPTION ON/OFF). The old
# stream follows it: with it off, the room's lines in main carry no roomDesc
# preset, and the room window shows no description (see
# room_description_spec.rb). The stream the game sends when Lich identifies
# as the Saga client sends the description whatever the setting, in its
# <room> block, and so does Lich's rewrite of that block into the old
# layout for front ends that don't read <room>. That is a confirmed
# DragonRealms game bug (GemStone follows its setting). As a workaround,
# Profanity follows the setting from the game's answers to it ("You will
# no longer see room descriptions." / "You will now see room
# descriptions."): while it is off, a room description is shown neither in
# main nor in the room window. A view of another room (DR's Locate) keeps
# its description, in the familiar window: the game sends it there too.
# Real lines (spec/fixtures/room_pipeline/dr_rich_*, player names
# replaced) and synthetic lines in Lich's rewrite layout.

require_relative '../spec_helper'
require_relative '../support/screen_replay'

RSpec.describe 'The room description setting on the rich stream' do
  include ScreenReplay

  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:off) { 'You will no longer see room descriptions.' }
  let(:on) { 'You will now see room descriptions.' }
  let(:prompt) { '<prompt time="1">&gt;</prompt>' }
  let(:shacks_desc) { /Here on the route between the sacred sites/ }

  # A room in the layout Lich rewrites a <room> block to (see lich-5's
  # Lich::Common::RoomBlock.legacy_shape)
  let(:rewritten_room) do
    ['<resource picture="0"/><style id="roomName" />[Bosque Deriel, Greengrove] (230006)',
     "<style id=\"\"/><preset id='roomDesc'>The trees here are uniform.</preset>  You also see a deed register.",
     'Obvious paths: <d>south</d>, <d>northwest</d>.']
  end

  before { stub_screen }
  after { restore_screen }

  describe 'with room descriptions turned off' do
    it 'shows no description for the room the game re-sends, in the room window or in main' do
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_view_in_place'))

      expect(room_screen).to eq ['{[Bosque Deriel, Hermit\'s Shacks] (230008):green}',
                                 'Also here: Shadow Priest Corvel, Dunmar and Druid Ebrin.',
                                 'Obvious paths: north, south.']
      expect(main_rows).to include(off, '[Bosque Deriel, Hermit\'s Shacks] (230008)')
      expect(main_rows.grep(shacks_desc)).to be_empty
    end

    it 'clears the description the room desc component sent on a move' do
      load_layout

      receive_from_server(off, prompt, *fixture('room_pipeline', 'dr_rich_move'))

      expect(room_screen).to eq ['{[Bosque Deriel, Greengrove] (230006):green}', 'You also see a deed register.',
                                 'Obvious paths: south, northwest.']
      expect(main_rows.grep(/The trees here/)).to be_empty
    end

    it "shows no description in Lich's rewrite of a room, and the rest of its line (synthetic)" do
      load_layout

      receive_from_server(off, prompt, *rewritten_room, prompt)

      expect(room_screen).to eq ['{[Bosque Deriel, Greengrove] (230006):green}', 'You also see a deed register.',
                                 'Obvious paths: south, northwest.']
      expect(main_rows.last(3)).to eq ['[Bosque Deriel, Greengrove] (230006)', 'You also see a deed register.',
                                       'Obvious paths: south, northwest.']
    end

    it 'shows no description in main without a room window' do
      load_layout(room_window: false)

      receive_from_server(*fixture('room_pipeline', 'dr_rich_view_in_place'))

      expect(main_rows.grep(shacks_desc)).to be_empty
      expect(main_rows).to include('Obvious paths: north, south.')
    end

    it 'keeps the text before a dropped description (synthetic)' do
      load_layout(room_window: false)

      receive_from_server(off, prompt, "Before. <preset id='roomDesc'>The trees here are uniform.</preset>  After.")

      expect(main_rows).to include('Before.')
      expect(main_rows.grep(/The trees here/)).to be_empty
    end

    it 'shows the next line after a description cut off at the end of its line (synthetic)' do
      load_layout

      receive_from_server(off, prompt, '<room><name>[Cut, Short] (5)</name><description>Half of a',
                          'A goblin arrives.', "<preset id='roomDesc'>Half of a", 'A kobold arrives.')

      expect(main_rows.last(3)).to eq ['[Cut, Short] (5)', 'A goblin arrives.', 'A kobold arrives.']
    end

    describe 'and a view of another room (DR Locate)' do
      let(:familiar) { "<window class='text' top='5' left='0' height='10' width='100' value='familiar'/>" }
      let(:burial_ground) do
        '<resource picture="0"/><room><name>[Bosque Deriel, Burial Ground] (230007)</name><description>You come ' \
          'upon an Elven burial ground in the shade of sacred groves.</description><exists></exists><players>' \
          '</players><exits>Obvious paths: <d>north</d>, <d>southeast</d>.</exits><extra></extra></room>'
      end

      # The game re-sends the player's room after OFF, then a Locate shows
      # another room in a <room> block of the same shape, with its
      # description (real lines, a session of 2026-10-16; names replaced,
      # descriptions shortened)
      it "shows the located room's description in the familiar window, and not the player's room's" do
        load_layout(extra: familiar)

        receive_from_server(
          off, prompt, burial_ground, prompt, '<spell>None</spell>You gesture.',
          '<resource picture="0"/><room><name>[Bosque Deriel, Hermit\'s Shacks] (230008)</name><description>Here ' \
          'on the route between the sacred sites of the Observatory and the Faery Ring is a semi-circular ' \
          'clearing.</description><exists>You also see a <a exist="199715456" noun="vessel">floating vessel of ' \
          'flaring crimson light</a>.</exists><players>Also here: Soul Annihilator <a exist="-1001" ' \
          'noun="Corvel">Corvel</a>, Druid <a exist="-1002" noun="Ebrin">Ebrin</a> and <a exist="-1003" ' \
          'noun="Dunmar">Dunmar</a>.</players><exits>Obvious paths: <d>north</d>, <d>south</d>.</exits><extra>' \
          '</extra></room>', prompt
        )

        expect(window_text('familiar')).to eq [
          "[Bosque Deriel, Hermit's Shacks] (230008)",
          'Here on the route between the sacred sites of the Observatory and the Faery Ring is a',
          '  semi-circular clearing.', 'You also see a floating vessel of flaring crimson light.',
          'Also here: Soul Annihilator Corvel, Druid Ebrin and Dunmar.', 'Obvious paths: north, south.'
        ]
        expect(room_screen).to eq ['{[Bosque Deriel, Burial Ground] (230007):green}', 'Obvious paths: north, southeast.']
        expect(main_rows.grep(/Elven burial ground/)).to be_empty
      end

      it "shows the located room's description in Lich's rewrite of the view (synthetic)" do
        load_layout(extra: familiar)

        receive_from_server(off, prompt, burial_ground, prompt, '<spell>None</spell>You gesture.',
                            '<resource picture="0"/><style id="roomName" />[Somewhere Else, Far Hall] (999999)',
                            "<style id=\"\"/><preset id='roomDesc'>A far hall.</preset>",
                            'Obvious paths: <d>east</d>.', prompt)

        expect(window_text('familiar')).to eq ['[Somewhere Else, Far Hall] (999999)', 'A far hall.',
                                               'Obvious paths: east.']
        expect(room_screen).to eq ['{[Bosque Deriel, Burial Ground] (230007):green}', 'Obvious paths: north, southeast.']
      end
    end
  end

  describe 'with room descriptions turned on again' do
    it 'shows the description again' do
      load_layout

      receive_from_server(off, prompt, *rewritten_room, prompt, on, prompt, *rewritten_room, prompt)

      expect(room_screen[1]).to eq 'The trees here are uniform.'
      expect(main_rows).to include('The trees here are uniform.')
    end
  end

  it 'shows descriptions before the game has answered a change of the setting' do
    load_layout

    receive_from_server(*rewritten_room, prompt)

    expect(room_screen[1]).to eq 'The trees here are uniform.'
  end

  it "doesn't follow DragonRealms' setting when the game is GemStone (--game)" do
    load_layout(game_rules: Games::GemStone)

    receive_from_server(off, prompt, *rewritten_room, prompt)

    expect(room_screen[1]).to eq 'The trees here are uniform.'
  end

  # GemStone follows its own setting, and sends its descriptions in a
  # roomDesc style (real lines, spec/fixtures/room_pipeline/gs_move), not
  # in a roomDesc preset or a <room> block. So even a line in DR's answer
  # text, without --game, can't drop one.
  it "keeps GemStone's description after a line in DR's answer text, without --game" do
    load_layout

    receive_from_server(off, prompt, *fixture('room_pipeline', 'gs_move'))

    expect(main_rows.grep(/Long beds of dark loam/).size).to eq 1
    expect(room_screen.grep(/Long beds of dark loam/)).not_to be_empty
  end
end
