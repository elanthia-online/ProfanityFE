# frozen_string_literal: true

# A gag is tested against the raw line, tags included, and then against
# the line's text (LineFilter#line_text): what the game shows of it, with
# entities decoded, leaving out the content of paired tags and the text of
# a room component (a component's text is the room window's, and a gagged
# line keeps only its stream and style tags). Synthetic lines in the forms
# the game sends.

require_relative '../spec_helper'
require_relative '../../lib/line_filter'
require_relative '../../lib/shared_state'

# Load the REAL GagPatterns module (replaces the spec_helper stub)
original_verbose = $VERBOSE
$VERBOSE = nil
load File.expand_path('../../lib/gag_patterns.rb', __dir__)
$VERBOSE = original_verbose

RSpec.describe LineFilter do
  subject(:line_filter) { described_class.new(shared_state: state, xml_escapes: escapes) }

  let(:state) { SharedState.new }
  let(:escapes) { { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' } }
  let(:gag_log) { [] }

  before do
    GagPatterns.load_defaults
    allow(ProfanityLog).to receive(:write) { |context, message, **| gag_log << message if context == 'gag' }
  end

  after { GagPatterns.load_defaults }

  describe 'a general gag' do
    it 'drops a line whose text it matches across links' do
      GagPatterns.add_general_pattern('^The jeol moradu begins to advance')

      line = '<pushBold/>The <a exist="1" noun="moradu">jeol moradu</a><popBold/> begins to advance on you!'

      expect(line_filter.filter(line)).to be_nil
    end

    it 'keeps the stream tags of a line it matches by text' do
      GagPatterns.add_general_pattern('^You search the')

      expect(line_filter.filter('<popStream id="combat" />You search the jeol moradu.')).to eq '<popStream id="combat" />'
    end

    it 'leaves a room component alone, though its text matches' do
      GagPatterns.add_general_pattern('^Also here:')

      line = "<compass><dir value=\"n\"/></compass><component id='room players'>Also here: Bob.</component>"

      expect(line_filter.filter(line)).to eq line
    end

    it 'drops the main text of a line that also holds a component' do
      GagPatterns.add_general_pattern('^Also here:')

      line = "<crtrStatus exist=\"1\" hostile=\"1\"/>Also here: Bob.<component id='room extra'></component>"

      expect(line_filter.filter(line)).to be_nil
    end

    it "doesn't take a paired tag's content for text" do
      GagPatterns.add_general_pattern('^Empty')

      expect(line_filter.filter('<left>Empty</left><right>Empty</right>')).to eq '<left>Empty</left><right>Empty</right>'
    end

    it 'matches the text with its entities decoded' do
      GagPatterns.add_general_pattern('You see <nothing>')

      expect(line_filter.filter('You see &lt;nothing&gt; here.')).to be_nil
    end

    it 'still matches the tags of a line, as a gag written against the raw line does' do
      GagPatterns.add_general_pattern('<preset id="whisper">\w+ whispers,')

      expect(line_filter.filter('<preset id="whisper">Bob whispers,</preset> "hi"')).to be_nil
    end

    it 'logs a match on the text only as such with --log-gags' do
      state.log_gags = true
      GagPatterns.add_general_pattern('^You search the')

      line_filter.filter('<popStream id="combat" />You search the jeol moradu.')

      expect(gag_log).to eq ['general (text) STREAM-TAG /^You search the/ "<popStream id=\"combat\" />You search the jeol moradu."']
    end
  end

  describe 'a multi-line gag' do
    it 'starts and ends on lines whose text it matches' do
      GagPatterns.add_multiline_gag('^Knowledge from your', '^The knowledge fades')

      lines = ['<pushBold/>Knowledge from your <a exist="1" noun="crystal">crystal</a> rings clear:',
               'Some lore.',
               '<pushBold/>The knowledge fades<popBold/>.',
               'A goblin arrives.']

      expect(lines.map { |line| line_filter.filter(line) }).to eq [nil, nil, nil, 'A goblin arrives.']
    end
  end
end
