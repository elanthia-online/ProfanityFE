# frozen_string_literal: true

# Tests the room window's creature highlight as a user sees it: the window is
# built from layout XML by WindowManager and draws onto the virtual screen
# (spec/support/virtual_screen.rb). Creature names arrive with the room
# objects, taken from the game's bold regions.

require 'rexml/document'
require_relative '../../../lib/window_manager'

RSpec.describe RoomWindow do
  # Color pair number per foreground color, so a cell's color can be read
  # back from its attributes.
  let(:pairs) { { 'ffff00' => 1 } }

  let(:window) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='room' top='0' left='0' height='5' width='80'/></layout>
    XML
    window_manager = WindowManager.new
    window_manager.load_layout('test')
    window_manager.room['room']
  end

  before do
    PRESET['monsterbold'] = ['ffff00', nil]
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
  end

  def show_objects(text, creatures)
    window.update_objects(text, creatures: creatures)
    window.update_exits('Obvious paths: north.')
    window.render
  end

  # Columns of the objects row drawn in the creature color.
  def highlighted_columns
    (0...window.maxx).select { |x| window.attrs_at(0, x) >> 8 == 1 }
  end

  # The characters of the objects row drawn in the creature color.
  def highlighted
    highlighted_columns.map { |x| window.rows[0][x] }.join
  end

  it 'highlights a creature name only where it is a whole word' do
    show_objects('You also see a pirate and a rat.', ['rat'])

    expect(window.rows[0]).to eq 'You also see a pirate and a rat.'
    expect(highlighted_columns).to eq [28, 29, 30]
  end

  it 'does not highlight a creature name at the start of a longer word' do
    show_objects('You also see an elkhound and an elk.', ['an elk'])

    expect(highlighted).to eq 'an elk'
  end

  it 'does not highlight a creature name joined to a word by a hyphen or apostrophe' do
    show_objects("You also see a rat-faced man, a rat's nest and a rat.", ['a rat'])

    expect(highlighted).to eq 'a rat'
  end

  it 'highlights names with apostrophes and hyphens in full' do
    show_objects("You also see an Adan'f shadow mage and a void-black umbral moth.",
                 ["an Adan'f shadow mage", 'a void-black umbral moth'])

    expect(highlighted).to eq "an Adan'f shadow magea void-black umbral moth"
  end

  it 'highlights every whole-word occurrence of a creature name' do
    show_objects('You also see a rat, a rat and a rat.', ['a rat'])

    expect(highlighted).to eq 'a rat' * 3
  end
end
