# frozen_string_literal: true

# What gags hide in each of the two streams DragonRealms sends, from real
# lines (spec/fixtures/, player names replaced). General gags are matched
# against the raw server line, tags included (see LineFilter), and a
# gagged line keeps only its stream and style tags.
#
# The rich stream (the stream the game sends when Lich identifies as the
# Saga client) puts an <a exist> link around every object, creature and
# player, so a gag written against the text no longer matches the raw
# line; and it sends a whole room as one line, so a gag on one part of a
# room matches the line of the whole room. The examples marked pending
# describe what the user should see; they fail until gags read the text
# and a room's parts (spec policy: AUDIT §0.2). The patterns are trimmed
# from the shipped templates' gags.

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
      GagPatterns.add_general_pattern('^You also see a deed register')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(main_rows.grep(/You also see/)).to be_empty
      expect(main_rows).to include('[Bosque Deriel, Greengrove] (230006)', 'Obvious paths: south, northwest.')
    end

    it 'hides only the part of a room an unanchored gag matches' do
      GagPatterns.add_general_pattern('You also see .* register')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(main_rows.grep(/You also see/)).to be_empty
      expect(main_rows).to include('[Bosque Deriel, Greengrove] (230006)', 'Obvious paths: south, northwest.')
    end

    it 'hides a gagged room name, and takes the description that follows for no title' do
      GagPatterns.add_general_pattern('^\\[Bosque Deriel, Greengrove\\]')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(main_rows.grep(/Bosque Deriel/)).to be_empty
      expect(main_rows[1]).to start_with 'The trees here are uniform'
      # The move's subtitle names the room in the title row and the terminal title
      expect(room_screen.first).to eq '{[Bosque Deriel, Greengrove] (230006):green}'
      expect(state.room_title).to eq 'Bosque Deriel, Greengrove (230006)'
    end

    it 'leaves a LOOK with its players gagged without players, as the old stream does' do
      GagPatterns.add_general_pattern('^Also here:')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_look'))

      expect(main_rows.grep(/Also here:/)).to be_empty
      expect(room_screen.grep(/Also here:/)).to be_empty
      expect(room_screen.last).to eq 'Obvious exits: north, west, northwest.'
    end

    it 'logs the room part a gag drops with --log-gags' do
      state.log_gags = true
      gag_log = []
      allow(ProfanityLog).to receive(:write) { |context, message, **| gag_log << message if context == 'gag' }
      GagPatterns.add_general_pattern('^You also see a deed register')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(gag_log.map { |message| message[/\A[^\/]*/].strip }).to eq ['general (text) room exists']
    end

    # A gag on blank lines matches the empty text of a room's empty parts
    # (this move has no players and nothing extra); there is nothing to drop.
    it 'logs no room part that was empty already' do
      state.log_gags = true
      gag_log = []
      allow(ProfanityLog).to receive(:write) { |context, message, **| gag_log << message if context == 'gag' }
      GagPatterns.add_general_pattern('^\\s*$')
      load_layout

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(gag_log.grep(/ room /)).to be_empty
    end

    # A multi-line gag still applies to the physical line: one that starts
    # on a room's text hides the whole room (a documented limitation).
    it 'hides the whole room when a multi-line gag starts on its text' do
      GagPatterns.add_multiline_gag('^\\[Bosque Deriel, Greengrove\\]')
      load_layout(room_window: false)

      receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))

      expect(main_rows).to eq ['You stroll southeast.']
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
