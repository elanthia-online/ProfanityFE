# frozen_string_literal: true

# Link colors against the other colors of a line, in each of the two
# streams DragonRealms sends, from real lines (spec/fixtures/, player names
# replaced). The old stream (Lich 5.22.0) sends no <a> links; the rich
# stream (the stream the game sends when Lich identifies as the Saga
# client) puts an <a exist> link around every object, creature and player.
# With links on, a creature's name or a highlighted name should keep its
# own color and stay clickable; the link color is for text with no other
# color. The examples marked pending describe what the user should see;
# they fail until the link color yields (spec policy: AUDIT §0.2).

require_relative '../spec_helper'
require_relative '../support/screen_replay'

RSpec.describe 'Link colors on the old and the rich DragonRealms stream' do
  include ScreenReplay

  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }

  before do
    stub_screen
    state.blue_links = true
  end

  after do
    restore_screen
    HIGHLIGHT.delete(/Aldric/)
  end

  describe 'the old stream' do
    it 'draws creatures in the creature color, with no links to color' do
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_old_creatures'))

      expect(room_screen[1]).to start_with 'You also see {a jeol moradu:red}, {a jeol moradu:red},'
    end
  end

  describe 'the rich stream' do
    it 'draws creatures in the creature color with links off' do
      state.blue_links = false
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

      expect(room_screen).to include(start_with('You also see {a jeol moradu:red} (immobile), a pouch'))
    end

    it 'keeps a creature clickable in the room window' do
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

      expect(room_screen.join).to include('(look #195652828)')
    end

    it 'draws a creature in the creature color with links on, in the room window and in main' do
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_creatures'))

      expect(room_screen).to include(start_with('You also see {a :red}[jeol moradu:red](look #195652828) (immobile)'))
      expect(main_screen.join).to include('{a jeol moradu:red} (immobile)')
    end

    it 'draws a highlighted name in the highlight color with links off' do
      state.blue_links = false
      HIGHLIGHT[/Aldric/] = ['ff00ff', nil, nil]
      load_layout(room_window: false)

      receive_from_server(*fixture('rich_stream', 'dr_rich_combat'))

      expect(main_screen.first).to start_with "{Aldric:magenta}'s greatsword"
    end

    # An underlined highlight adds A_UNDERLINE to the cells' attributes;
    # their color is still the highlight's.
    it 'draws an underlined highlighted name in the highlight color with links off' do
      state.blue_links = false
      HIGHLIGHT[/Aldric/] = ['ff00ff', nil, 'true']
      load_layout(room_window: false)

      receive_from_server(*fixture('rich_stream', 'dr_rich_combat'))

      expect(main_screen.first).to start_with "{Aldric:magenta}'s greatsword"
    end

    it 'draws a highlighted name in the highlight color with links on' do
      HIGHLIGHT[/Aldric/] = ['ff00ff', nil, nil]
      load_layout(room_window: false)

      receive_from_server(*fixture('rich_stream', 'dr_rich_combat'))

      expect(main_screen.first).to start_with "{Aldric:magenta}'s {greatsword:link}"
    end
  end
end
