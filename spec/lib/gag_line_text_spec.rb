# frozen_string_literal: true

# A gag is tested against the raw line, tags included, and then against
# the line's text (LineFilter#line_text): what the game shows of it, with
# entities decoded, leaving out the content of paired tags and the text of
# a component (a component's text is a window's, such as the room
# window's). A line matched as sent keeps only its stream and style tags;
# a line matched by its text only keeps every tag but those of its text.
# Synthetic lines in the forms the game sends.

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

    it 'drops only the main text of a line that also holds a component' do
      GagPatterns.add_general_pattern('^Also here:')

      line = "<crtrStatus exist=\"1\" hostile=\"1\"/>Also here: Bob.<component id='room objs'>You also see a rock.</component>"

      expect(line_filter.filter(line)).to eq "<crtrStatus exist=\"1\" hostile=\"1\"/><component id='room objs'>You also see a rock.</component>"
    end

    it 'keeps the tags of a line it matches by its text only, but those of the text' do
      GagPatterns.add_general_pattern('^You search the')

      line = "<dialogData id='expr'><progressBar id='mindState' value='100' text='must rest'/></dialogData>" \
             'You search the <pushBold/><a exist="1" noun="lurk">shambling lurk</a><popBold/>.' \
             "<preset id='roomDesc'>A cave.</preset><d cmd='look'>LOOK</d><color fg='ff0000'>!</color>"

      expect(line_filter.filter(line)).to eq "<dialogData id='expr'><progressBar id='mindState' value='100' text='must rest'/></dialogData>"
    end

    it 'keeps the links and bold inside a component beside the text it matches' do
      GagPatterns.add_general_pattern('^A bone wyvern walks')

      component = "<component id='room objs'>You also see <pushBold/>a <a exist=\"2\" noun=\"rock\">rock</a><popBold/>.</component>"
      line = "<pushBold/>A <a exist=\"1\" noun=\"wyvern\">bone wyvern</a><popBold/> walks southeast.#{component}"

      expect(line_filter.filter(line)).to eq component
    end

    it 'keeps only the stream and style tags of a line it matches as sent' do
      GagPatterns.add_general_pattern('You search the')

      line = "<dialogData id='expr'><progressBar id='mindState' value='100' text='must rest'/></dialogData>" \
             '<pushStream id="combat" />You search the shambling lurk.'

      expect(line_filter.filter(line)).to eq '<pushStream id="combat" />'
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

    # A line with no text (a prompt, a room component, a status tag) shows
    # nothing a gag written against the text could hide; its tags still
    # matter. A gag on blank lines must keep matching blank lines only.
    it 'leaves a line with no text alone under a gag that matches an empty line' do
      GagPatterns.add_general_pattern('^\s*$')

      lines = ['<prompt time="1792031037">&gt;</prompt>',
               "<component id='room objs'>You also see a rock.</component>",
               "<nav rm='4217405'/>",
               '<roundTime value="1792031040"/>']

      expect(lines.map { |line| line_filter.filter(line) }).to eq lines
    end

    it 'still drops a blank line under a gag that matches an empty line' do
      GagPatterns.add_general_pattern('^$')

      expect(line_filter.filter('')).to be_nil
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

    it 'keeps the tags of a start and an end line it matches by their text only' do
      GagPatterns.add_multiline_gag('^Knowledge from your', '^The knowledge fades')

      bar = "<dialogData id='expr'><progressBar id='mindState' value='100' text='must rest'/></dialogData>"
      lines = ["#{bar}Knowledge from your <a exist=\"1\" noun=\"crystal\">crystal</a> rings clear:",
               'Some lore.',
               "<indicator id='IconHIDDEN' visible='n'/>The knowledge fades."]

      expect(lines.map { |line| line_filter.filter(line) }).to eq [bar, nil, "<indicator id='IconHIDDEN' visible='n'/>"]
    end

    it 'keeps only the stream and style tags of a line inside the block' do
      GagPatterns.add_multiline_gag('^Knowledge from your', '^The knowledge fades')

      lines = ['Knowledge from your crystal rings clear:',
               "<dialogData id='expr'><progressBar id='mindState' value='100' text='must rest'/></dialogData>" \
               '<pushStream id="combat" />Some lore.',
               'The knowledge fades.']

      expect(lines.map { |line| line_filter.filter(line) }).to eq [nil, '<pushStream id="combat" />', nil]
    end

    it "doesn't start on a line with no text under a start that matches an empty line" do
      GagPatterns.add_multiline_gag('^\s*$', '^The knowledge fades')

      line = "<component id='room objs'>You also see a rock.</component>"

      expect(line_filter.filter(line)).to eq line
    end

    it "doesn't end on a line with no text under an end that matches an empty line" do
      GagPatterns.add_multiline_gag('^Knowledge from your', '^\s*$')

      lines = ['Knowledge from your crystal rings clear:',
               '<pushBold/>',
               'Some lore.',
               '',
               'A goblin arrives.']

      expect(lines.map { |line| line_filter.filter(line) }).to eq [nil, nil, nil, nil, 'A goblin arrives.']
    end
  end
end
