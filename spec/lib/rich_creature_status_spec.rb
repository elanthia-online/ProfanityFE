# frozen_string_literal: true

# A creature's state in the room window. DragonRealms sends
# <crtrStatus exist='N' .../> with a creature's whole state (hostile,
# disengaged, dead, sleeping, prone, immobile); when Lich identifies as the
# Saga client, each creature in the room's objects is an <a exist='N'>
# link, so the room window can tell which creature a state is for, even
# between two creatures of one name. A dead, sleeping or prone creature is
# drawn in the room window's preset for that state, when it is defined.
# From real lines (spec/fixtures/room_pipeline/dr_rich_creatures: one jeol
# moradu immobile, one dead) and synthetic status lines.

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
end
