# frozen_string_literal: true

# Tests that the StringClassification predicates look at the whole
# string, not just one line of it: a string with a newline is true only
# when every character, newlines included, is of the class. Also checks
# that single characters (the only thing CommandBuffer's word deletion
# passes in), "\n" and "\r" included, are classified by their own class,
# and that word deletion over text holding "\n" or "\r" is unchanged.

require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../support/screen_line_window'
using StringClassification

RSpec.describe StringClassification do
  describe 'strings with more than one line' do
    {
      alnum?: ["abc\n!", "!\nabc"],
      digits?: ["42\nabc", "abc\n42"],
      punct?: ["!\na", "a\n!"],
      space?: [" \na", "a\n "]
    }.each do |predicate, (first_line_matches, later_line_matches)|
      it "##{predicate} is false for #{first_line_matches.inspect} (only the first line is of the class)" do
        expect(first_line_matches.public_send(predicate)).to be false
      end

      it "##{predicate} is false for #{later_line_matches.inspect} (only a later line is of the class)" do
        expect(later_line_matches.public_send(predicate)).to be false
      end
    end
  end

  # A trailing newline is a character too: it isn't alphanumeric, a digit
  # or punctuation, so the docs' "all characters are ..." makes these
  # false. It is whitespace, so space? stays true.
  describe 'a trailing newline' do
    it('makes alnum? false') { expect("abc\n".alnum?).to be false }
    it('makes digits? false') { expect("42\n".digits?).to be false }
    it('makes punct? false') { expect("!\n".punct?).to be false }
    it('keeps space? true') { expect("  \n".space?).to be true }
    it('keeps space? true after a CR') { expect(" \r\n".space?).to be true }
  end

  # For one character, "every character is of the class" is "this
  # character is of the class". Covers ASCII (with "\n" and "\r"),
  # Latin-1 and a few wider characters.
  describe 'single characters' do
    classes = { alnum?: /[[:alnum:]]/, digits?: /[[:digit:]]/, punct?: /[[:punct:]]/, space?: /[[:space:]]/ }
    chars = (0..0xFF).map { |cp| cp.chr(Encoding::UTF_8) } +
            ["́", " ", " ", "　", "€", "©", "é", "٣", "\u{1F600}"]

    classes.each do |predicate, klass|
      it "##{predicate} matches the character's own class for every sample character" do
        mismatches = chars.reject { |ch| ch.public_send(predicate) == ch.match?(klass) }
        expect(mismatches).to eq []
      end
    end

    it('classifies "\n" as whitespace only') do
      expect(%i[alnum? digits? punct? space?].map { |p| "\n".public_send(p) }).to eq [false, false, false, true]
    end

    it('classifies "\r" as whitespace only') do
      expect(%i[alnum? digits? punct? space?].map { |p| "\r".public_send(p) }).to eq [false, false, false, true]
    end
  end
end

RSpec.describe CommandBuffer do
  subject(:buf) { described_class.new }
  let(:window) { Curses::Window.new(1, 80, 0, 0) }

  before { buf.window = window }

  def type(str)
    str.each_char { |ch| buf.put_ch(ch) }
  end

  # "\n" and "\r" count as whitespace between words, as a space does.
  describe 'word deletion over newlines and carriage returns' do
    {
      "go\nnorth"    => ["go\n", "\nnorth"],
      "go\r\nnorth"  => ["go\r\n", "\r\nnorth"],
      "hi,\r\nthere" => ["hi,\r\n", ",\r\nthere"]
    }.each do |str, (after_backspace, after_delete)|
      it "backspace_word at the end of #{str.inspect} leaves #{after_backspace.inspect}" do
        type(str)
        buf.backspace_word
        expect(buf.text).to eq after_backspace
        expect(buf.pos).to eq after_backspace.length
      end

      it "delete_word at the start of #{str.inspect} leaves #{after_delete.inspect}" do
        type(str)
        buf.cursor_home
        buf.delete_word
        expect(buf.text).to eq after_delete
        expect(buf.pos).to eq 0
      end
    end
  end
end
