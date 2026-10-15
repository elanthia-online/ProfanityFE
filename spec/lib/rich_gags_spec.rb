# frozen_string_literal: true

# What gags hide in each of the two streams DragonRealms sends, from real
# lines (spec/fixtures/, player names replaced). General gags are matched
# against the raw server line, tags included, then against the line's text
# (see LineFilter#line_text), and a gagged line keeps only its stream and
# style tags.
#
# The rich stream (the stream the game sends when Lich identifies as the
# Saga client) puts an <a exist> link around every object, creature and
# player, so a gag written against the text misses the raw line and
# matches its text; and it sends a whole room as one line, so a gag on one
# part of a room matches the line of the whole room. The examples marked
# pending describe what the user should see; they fail until gags read a
# room's parts (spec policy: AUDIT §0.2). The patterns are trimmed from
# the shipped templates' gags.

require_relative '../spec_helper'
require_relative '../support/screen_replay'

# Load the REAL GagPatterns module (replaces the spec_helper stub)
original_verbose = $VERBOSE
$VERBOSE = nil
load File.expand_path('../../lib/gag_patterns.rb', __dir__)
$VERBOSE = original_verbose

RSpec.describe 'Gags on the old and the rich DragonRealms stream' do
  include ScreenReplay

  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }

  before do
    stub_screen
    GagPatterns.load_defaults
  end

  after do
    restore_screen
    GagPatterns.load_defaults
  end

  describe 'the old stream' do
    # A gagged line drops a <component> with its text: a gag on the room's
    # lines in main must leave the room components on their own lines.
    it 'keeps the players in the room window and the indicator under a gag on the players line' do
      GagPatterns.add_general_pattern('^Also here:')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_old_creatures'))

      expect(room_screen).to include('Also here: True to Life Faelan and Universalist Hessa.')
      expect(indicator).to eq 'Faelan, Hessa'
    end

    # With creatures in the room, the players line starts with their
    # <crtrStatus/> tags, so an anchored gag misses its raw line.
    it 'hides the players line in main when creature tags come before its text' do
      GagPatterns.add_general_pattern('^Also here:')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_old_creatures'))

      expect(main_rows.grep(/Also here:/)).to be_empty
    end

    it 'hides the exits line in main, and keeps the exits in the room window' do
      GagPatterns.add_general_pattern('^Obvious (?:paths|exits):')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_old_creatures'))

      expect(main_rows.grep(/Obvious/)).to be_empty
      expect(room_screen.last).to eq 'Obvious exits: north, northeast, east, southwest, west, northwest.'
    end

    # The compass line has no text, only tags: a gag on blank lines must
    # not take it for one.
    it 'keeps the compass under a gag on blank lines' do
      GagPatterns.add_general_pattern('^\s*$')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_old_creatures'))

      expect(compass_lit).to eq %w[n ne e sw w nw]
    end

    it 'hides a line whose text a gag matches after a leading stream tag' do
      GagPatterns.add_general_pattern('^You search the')
      load_layout(room_window: false)

      receive_from_server(*fixture('rich_stream', 'dr_old_gag_lines'))

      expect(main_rows.grep(/You search/)).to be_empty
    end
  end

  describe 'the rich stream' do
    it 'hides a line whose text a gag matches, links and all' do
      GagPatterns.add_general_pattern('^(?:<.*>)?(?:The|A|An) jeol moradu begins to advance')
      load_layout(room_window: false)

      receive_from_server(*fixture('rich_stream', 'dr_rich_gag_lines'))

      expect(main_rows.grep(/begins to advance/)).to be_empty
      expect(main_rows).to include('You stop your performance.')
    end

    it 'hides only the part of a room an anchored gag matches' do
      pending 'gags are matched against the whole room line'
      GagPatterns.add_general_pattern('^You also see a deed register')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(main_rows.grep(/You also see/)).to be_empty
      expect(main_rows).to include('[Bosque Deriel, Greengrove] (230006)', 'Obvious paths: south, northwest.')
    end

    it 'hides only the part of a room an unanchored gag matches' do
      pending 'gags are matched against the whole room line'
      GagPatterns.add_general_pattern('You also see .* register')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(main_rows.grep(/You also see/)).to be_empty
      expect(main_rows).to include('[Bosque Deriel, Greengrove] (230006)', 'Obvious paths: south, northwest.')
    end

    # Combat gags apply to the combat stream. Combat lines that come with no
    # combat pushStream (as in the session these fixtures come from) are
    # main's, so combat gags don't apply to them.
    it 'shows combat lines a combat gag matches, since they are not on the combat stream' do
      GagPatterns.add_combat_pattern('lands a massive strike')
      load_layout(room_window: false)

      receive_from_server(*fixture('rich_stream', 'dr_rich_combat'))

      expect(main_rows).to include("Aldric's greatsword lands a massive strike to a jeol moradu's left arm!")
    end
  end
end
