# frozen_string_literal: true

# Tests StringClassification refinement: word_char?, whitespace_char?,
# and punctuation_char? predicates for cursor word-movement logic.

require_relative '../../lib/string_classification'
using StringClassification

RSpec.describe StringClassification do
  describe '#alnum?' do
    it('letters') { expect('abc'.alnum?).to be true }
    it('digits') { expect('123'.alnum?).to be true }
    it('mixed') { expect('abc123'.alnum?).to be true }
    it('single char') { expect('a'.alnum?).to be true }
    it('single digit') { expect('0'.alnum?).to be true }

    it('rejects punctuation') { expect('abc!'.alnum?).to be false }
    it('rejects spaces') { expect('a b'.alnum?).to be false }
    it('rejects empty') { expect(''.alnum?).to be false }
    it('rejects whitespace') { expect("\t".alnum?).to be false }
    it('rejects newline') { expect("\n".alnum?).to be false }

    # Adversarial
    it('accepts non-ASCII letters') { expect('café'.alnum?).to be true }
    it('rejects hyphen') { expect('-'.alnum?).to be false }
    it('rejects underscore') { expect('_'.alnum?).to be false }
  end

  describe '#digits?' do
    it('all digits') { expect('42'.digits?).to be true }
    it('single digit') { expect('0'.digits?).to be true }
    it('long number') { expect('123456789'.digits?).to be true }

    it('rejects letters') { expect('42a'.digits?).to be false }
    it('rejects empty') { expect(''.digits?).to be false }
    it('rejects spaces') { expect('4 2'.digits?).to be false }
    it('rejects negative sign') { expect('-1'.digits?).to be false }
    it('rejects decimal point') { expect('3.14'.digits?).to be false }
  end

  describe '#punct?' do
    it('exclamation') { expect('!'.punct?).to be true }
    it('multiple') { expect('!@#$%'.punct?).to be true }
    it('period') { expect('.'.punct?).to be true }
    it('comma') { expect(','.punct?).to be true }
    it('semicolon') { expect(';'.punct?).to be true }
    it('brackets') { expect('[]'.punct?).to be true }
    it('braces') { expect('{}'.punct?).to be true }

    it('rejects letters') { expect('a'.punct?).to be false }
    it('rejects digits') { expect('1'.punct?).to be false }
    it('rejects empty') { expect(''.punct?).to be false }
    it('rejects mixed') { expect('a!'.punct?).to be false }
    it('rejects space') { expect(' '.punct?).to be false }
  end

  describe '#space?' do
    it('spaces') { expect('   '.space?).to be true }
    it('single space') { expect(' '.space?).to be true }
    it('tab') { expect("\t".space?).to be true }
    it('newline') { expect("\n".space?).to be true }
    it('carriage return') { expect("\r".space?).to be true }
    it('mixed whitespace') { expect(" \t\n".space?).to be true }

    it('rejects letters') { expect('a'.space?).to be false }
    it('rejects empty') { expect(''.space?).to be false }
    it('rejects mixed') { expect(' a'.space?).to be false }
  end

  # ---- Word boundary behavior (how CommandBuffer uses these) ----

  describe 'word boundary classification' do
    it 'correctly classifies each character type in "hello, world! 42"' do
      text = 'hello, world! 42'
      #       0123456789012345
      expect(text[0].alnum?).to be true    # 'h'
      expect(text[5].punct?).to be true    # ','
      expect(text[6].space?).to be true    # ' '
      expect(text[12].punct?).to be true   # '!'
      expect(text[13].space?).to be true   # ' '
      expect(text[14].alnum?).to be true   # '4'
    end

    it 'identifies transitions that define word boundaries' do
      text = 'foo-bar'
      expect(text[2].alnum?).to be true    # 'o'
      expect(text[3].punct?).to be true    # '-'
      expect(text[4].alnum?).to be true    # 'b'
      # alnum->punct and punct->alnum are word boundaries
    end
  end
end
