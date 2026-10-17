# frozen_string_literal: true

# A creature's state in the room window, in both games. Each sends
# <crtrStatus exist='N' .../> with a creature's whole state (DragonRealms:
# hostile, disengaged, dead, sleeping, prone, immobile...; GemStone: health,
# maxhealth, hostile, dead, prone, sleeping...). GemStone sends it inside
# the room objs compDef or component, just before each creature;
# DragonRealms sends it on the line after the room objs component, or
# after </exists> in a <room> block. Where each creature in the room's
# objects is an <a exist='N'> link (always in GemStone; in DragonRealms
# when Lich identifies as the Saga client) the room window can tell which
# creature a state is for, even between two creatures of one name. A dead,
# sleeping or prone creature is drawn in the room window's preset for that
# state, when it is defined.
# From real lines (spec/fixtures/room_pipeline/dr_rich_creatures: one jeol
# moradu immobile, one dead; gs_sanctum_tower_move), synthetic status
# lines, and GemStone objects updates in a real shape (see 'in GemStone').

require_relative '../spec_helper'
require_relative '../support/screen_replay'

RSpec.describe 'Creature states in the room window' do
  include ScreenReplay

  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:status_tags) { %w[creatureDead creatureSleeping creatureProne] }

  before do
    stub_screen
    @saved = status_tags.to_h { |id| [id, PRESET[id]] }
    PRESET['creatureDead'] = ['444444', nil]
    PRESET['creatureProne'] = ['00ffff', nil]
    PRESET.delete('creatureSleeping')
  end

  after do
    restore_screen
    @saved.each { |id, colors| colors ? PRESET[id] = colors : PRESET.delete(id) }
  end

  # A <crtrStatus> line for the creature with id +exist+, then a prompt
  def status(exist, *flags)
    ["<crtrStatus exist=\"#{exist}\" hostile=\"1\"#{flags.map { |f| " #{f}=\"1\"" }.join}/>" \
     '<prompt time="1">&gt;</prompt>']
  end

  def objects_row = room_screen.find { |row| row.start_with?('You also see') }

  it 'draws a dead creature in the dead preset, and one of the same name alive in the creatures preset' do
    load_layout

    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

    expect(objects_row).to start_with 'You also see {a jeol moradu:red} (immobile), a pouch'
    expect(room_screen.join).to include('{a jeol moradu:grey} (dead)')
  end

  it 'keeps a dead creature clickable with links on' do
    state.blue_links = true
    load_layout

    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

    expect(room_screen.join).to include('{a :grey}[jeol moradu:grey](look #195652888) (dead)')
  end

  it "follows a creature's state as it changes, and back" do
    load_layout
    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

    receive_from_server(*status('195652828', 'prone'))
    expect(objects_row).to start_with 'You also see {a jeol moradu:cyan} (immobile)'

    receive_from_server(*status('195652828'))
    expect(objects_row).to start_with 'You also see {a jeol moradu:red} (immobile)'
  end

  it 'leaves a creature in the creatures preset for a state whose preset is not defined' do
    load_layout
    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

    receive_from_server(*status('195652828', 'sleeping'))

    expect(objects_row).to start_with 'You also see {a jeol moradu:red} (immobile)'
  end

  it 'draws a dead creature in the dead preset when the creatures preset is not defined' do
    saved = PRESET.delete('monsterbold')
    load_layout

    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

    expect(objects_row).to start_with 'You also see a jeol moradu (immobile), a pouch'
    expect(room_screen.join).to include('{a jeol moradu:grey} (dead)')
  ensure
    PRESET['monsterbold'] = saved if saved
  end

  it 'keeps no creature states without a room window' do
    load_layout(room_window: false)

    receive_from_server(*(1..50).flat_map { |id| status(id.to_s, 'dead') })

    expect(@processor.instance_variable_get(:@room).instance_variable_get(:@creature_states)).to be_empty
  end

  # The fixture's room objs line: the objects again, with no status tags
  def objects_line = fixture('room_pipeline', 'dr_rich_creatures').find { |line| line.include?("<component id='room objs'>") }

  # A room objs line listing the fixture's two moradus and one more, id 195650001
  def objects_with_third_line
    objects_line.sub(' and some junk.', ', <pushBold/>a <a exist="195650001" noun="moradu">jeol moradu</a><popBold/> and some junk.')
  end

  it 'keeps a dead creature in the dead preset through an objects update that sends no state' do
    load_layout
    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

    receive_from_server(objects_line, '<prompt time="1">&gt;</prompt>')

    expect(objects_row).to start_with 'You also see {a jeol moradu:red} (immobile)'
    expect(room_screen.join).to include('{a jeol moradu:grey} (dead)')
  end

  it 'draws a creature whose state came before the objects that show it' do
    load_layout
    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

    receive_from_server(*status('195650001', 'prone'))
    receive_from_server(objects_with_third_line, '<prompt time="1">&gt;</prompt>')

    expect(room_screen.join).to include('{a jeol moradu:cyan} and some junk.')
  end

  it 'keeps only the states of the creatures the objects shown link to after an objects update' do
    load_layout
    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))
    receive_from_server(*(1..50).flat_map { |id| status(id.to_s, 'dead') })

    receive_from_server(objects_line, '<prompt time="1">&gt;</prompt>')

    kept = @processor.instance_variable_get(:@room).instance_variable_get(:@creature_states)
    expect(kept.keys).to contain_exactly('195652828', '195652888')
  end

  it 'draws the room window again only when the state of a creature it shows changes' do
    load_layout
    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))
    room = @window_manager.room['room']
    allow(room).to receive(:render).and_call_original

    receive_from_server(*status('999', 'dead'))
    receive_from_server(*status('195652888', 'dead'))
    expect(room).not_to have_received(:render)

    receive_from_server(*status('195652828', 'prone'))
    expect(room).to have_received(:render).once
  end

  it 'draws a creature that is both sleeping and prone in the sleeping preset' do
    PRESET['creatureSleeping'] = ['ff00ff', nil]
    load_layout
    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

    receive_from_server(*status('195652828', 'sleeping', 'prone'))

    expect(objects_row).to start_with 'You also see {a jeol moradu:magenta} (immobile)'
  end

  it "takes the state presets from the room window's dead-preset and prone-preset" do
    saved = %w[ownDead ownProne].to_h { |id| [id, PRESET[id]] }
    PRESET['ownDead'] = ['00ff00', nil]
    PRESET['ownProne'] = ['ffff00', nil]
    load_layout(room_window: false, extra: "<window class='room' top='1' left='0' height='30' width='100' " \
                                           "value='room' dead-preset='ownDead' prone-preset='ownProne'/>")
    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

    receive_from_server(*status('195652828', 'prone'))

    expect(objects_row).to start_with 'You also see {a jeol moradu:yellow} (immobile)'
    expect(room_screen.join).to include('{a jeol moradu:green} (dead)')
  ensure
    saved.each { |id, colors| colors ? PRESET[id] = colors : PRESET.delete(id) }
  end

  it 'follows the state of a creature shown while a layout without a room window is loaded' do
    load_layout
    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))
    receive_from_server(*status('195652828', 'prone'))
    LAYOUT['no-room'] = REXML::Document.new(
      "<layout><window class='text' top='0' left='0' height='60' width='100' value='main'/></layout>"
    ).root

    @window_manager.load_layout('no-room')
    receive_from_server(*status('195652828'))
    @window_manager.load_layout('replay')
    receive_from_server(objects_line, '<prompt time="1">&gt;</prompt>')

    expect(objects_row).to start_with 'You also see {a jeol moradu:red} (immobile)'
  ensure
    LAYOUT.delete('no-room')
  end

  it 'ignores the state of a creature the objects shown do not link to' do
    load_layout
    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))
    shown = room_screen

    receive_from_server(*status('999', 'dead'))

    expect(room_screen).to eq shown
  end

  it 'keeps creatures in the creatures preset in main' do
    load_layout

    receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

    expect(main_screen.join).to include('{a jeol moradu:red} (dead)')
  end

  it 'shows no state in the old stream, whose creatures are not links' do
    load_layout

    receive_from_server(*fixture('room_pipeline', 'dr_old_creatures'))

    expect(room_screen.join).not_to include(':grey}')
  end

  # GemStone links every creature, and sends each one's <crtrStatus> inside
  # the room objs compDef or component, just before the creature's <b>.
  # The move is a real one (gs_sanctum_tower_move: one pale scaled shaper,
  # id 559065931, alive); the objects updates after it are in the shape of
  # real ones from a 2026-10-15 GemStone log, ids and the disk's owner
  # changed. GemStone sends a dead creature as dead and prone, and a
  # standalone <crtrStatus> before the component that shows the change.
  describe 'in GemStone' do
    let(:move) { fixture('room_pipeline', 'gs_sanctum_tower_move') }

    # A GemStone room objs component: a disk, a dead fanatic, a live
    # fanatic of the same name, and the shaper with +shaper_flags+
    def gs_objects(shaper_flags = '')
      "<component id='room objs'>  You also see the <a exist=\"700000001\" noun=\"disk\">blue Avrel disk</a>," \
        '<crtrStatus exist="700000011" health="-128" maxhealth="240" hostile="1" dead="1" prone="1"/>' \
        '<b> <pushBold/>a <a exist="700000011" noun="fanatic">deathsworn fanatic</a><popBold/></b> that appears dead,' \
        '<crtrStatus exist="700000012" health="240" maxhealth="240" hostile="1"/>' \
        '<b> <pushBold/>a <a exist="700000012" noun="fanatic">deathsworn fanatic</a><popBold/></b> and' \
        "<crtrStatus exist=\"559065931\" health=\"85\" maxhealth=\"240\" hostile=\"1\"#{shaper_flags}/>" \
        '<b> <pushBold/>a <a exist="559065931" noun="shaper">pale scaled shaper</a><popBold/></b>.</component>'
    end

    it 'draws a dead creature in the dead preset, and one of the same name alive in the creatures preset' do
      load_layout
      receive_from_server(*move)

      receive_from_server(gs_objects, '<prompt time="1">&gt;</prompt>')

      expect(room_screen).to include('You also see the blue Avrel disk, {a deathsworn fanatic:grey} that appears dead, ' \
                                     '{a deathsworn fanatic:red} and', '{a pale scaled shaper:red}.')
    end

    it 'follows a standalone <crtrStatus> sent before the objects update' do
      load_layout
      receive_from_server(*move)
      receive_from_server(gs_objects, '<prompt time="1">&gt;</prompt>')

      receive_from_server('<crtrStatus exist="559065931" health="85" maxhealth="240" hostile="1" prone="1"/>' \
                          '<prompt time="2">&gt;</prompt>')

      expect(room_screen).to include('{a pale scaled shaper:cyan}.')
    end

    it 'draws a creature the objects update marks prone in the prone preset' do
      load_layout
      receive_from_server(*move)

      receive_from_server(gs_objects(' prone="1"'), '<prompt time="1">&gt;</prompt>')

      expect(room_screen).to include('{a pale scaled shaper:cyan}.')
    end
  end
end
