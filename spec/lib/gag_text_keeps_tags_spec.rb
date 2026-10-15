# frozen_string_literal: true

# A gag that matches only a line's text (LineFilter#line_text) hides that
# text and nothing else: the tags beside it still reach the windows. Both
# games put a window's tags in front of main text on one line, where an
# anchored gag on the text never matched the line as sent. Synthetic lines
# in the shapes the games send (names replaced), with gags from the
# shipped default template.

require_relative '../spec_helper'
require_relative '../support/screen_replay'

# Load the REAL GagPatterns module (replaces the spec_helper stub)
original_verbose = $VERBOSE
$VERBOSE = nil
load File.expand_path('../../lib/gag_patterns.rb', __dir__)
$VERBOSE = original_verbose

RSpec.describe 'A gag on the text of a line that also holds window tags' do
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

  # GemStone sends the experience bars on the line of a search, in front
  # of its text.
  it 'still updates the mind bar from a GemStone search line it hides' do
    GagPatterns.add_general_pattern('^You search the')
    load_layout(extra: "<window class='progress' top='4' left='0' height='1' width='20' value='mind' label='mind'/>")

    receive_from_server(
      "<dialogData id='expr'><progressBar id='mindState' value='40' text='clear as a bell' top='45' left='3'/></dialogData>",
      "<dialogData id='expr'><progressBar id='mindState' value='100' text='must rest' top='45' left='3'/></dialogData>" \
      'You search the <pushBold/><a exist="1" noun="lurk">shambling lurk</a><popBold/>.'
    )

    expect(main_rows.grep(/You search/)).to be_empty
    expect(@window_manager.progress['mind'].value).to eq 100
  end

  # DragonRealms sends the room's objects on the line of a creature that
  # leaves, after its text.
  it 'still updates the room objects from a creature line it hides' do
    GagPatterns.add_general_pattern('^(?:<.*>)?(?:The|A|An) (?:bone wyvern)')
    load_layout

    receive_from_server(
      "<component id='room objs'>You also see a rock and <pushBold/>a <a exist=\"2\" noun=\"wyvern\">bone wyvern</a><popBold/>.</component>",
      '<pushBold/>A <a exist="2" noun="wyvern">bone wyvern</a><popBold/> walks southeast.' \
      "<component id='room objs'>You also see a rock.</component>"
    )

    expect(main_rows.grep(/wyvern/)).to be_empty
    expect(room_screen.join("\n")).to include('You also see a rock.')
    expect(room_screen.join("\n")).not_to include('wyvern')
  end
end
