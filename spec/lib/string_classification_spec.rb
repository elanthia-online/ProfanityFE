# frozen_string_literal: true

# Tests the StringClassification refinement: alnum?, digits?, punct? and
# space?, each true only when every character is of its class.
# CommandBuffer's word deletion uses punct? and space? on single
# characters; command_buffer_spec checks that through the editing keys.

require_relative '../../lib/string_classification'
using StringClassification

RSpec.describe StringClassification do
  describe '#alnum?' do
    it('accepts letters') { expect('abc'.alnum?).to be true }
    it('accepts digits') { expect('123'.alnum?).to be true }
    it('accepts mixed') { expect('abc123'.alnum?).to be true }
    it('accepts single char') { expect('a'.alnum?).to be true }
    it('accepts single digit') { expect('0'.alnum?).to be true }

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
    it('accepts all digits') { expect('42'.digits?).to be true }
    it('accepts single digit') { expect('0'.digits?).to be true }
    it('accepts long number') { expect('123456789'.digits?).to be true }

    it('rejects letters') { expect('42a'.digits?).to be false }
    it('rejects empty') { expect(''.digits?).to be false }
    it('rejects spaces') { expect('4 2'.digits?).to be false }
    it('rejects negative sign') { expect('-1'.digits?).to be false }
    it('rejects decimal point') { expect('3.14'.digits?).to be false }
  end

  describe '#punct?' do
    it('accepts exclamation') { expect('!'.punct?).to be true }
    it('accepts multiple') { expect('!@#$%'.punct?).to be true }
    it('accepts period') { expect('.'.punct?).to be true }
    it('accepts comma') { expect(','.punct?).to be true }
    it('accepts semicolon') { expect(';'.punct?).to be true }
    it('accepts brackets') { expect('[]'.punct?).to be true }
    it('accepts braces') { expect('{}'.punct?).to be true }
    it('accepts a hyphen') { expect('-'.punct?).to be true }

    it('rejects letters') { expect('a'.punct?).to be false }
    it('rejects digits') { expect('1'.punct?).to be false }
    it('rejects empty') { expect(''.punct?).to be false }
    it('rejects mixed') { expect('a!'.punct?).to be false }
    it('rejects space') { expect(' '.punct?).to be false }
  end

  describe '#space?' do
    it('accepts spaces') { expect('   '.space?).to be true }
    it('accepts single space') { expect(' '.space?).to be true }
    it('accepts tab') { expect("\t".space?).to be true }
    it('accepts newline') { expect("\n".space?).to be true }
    it('accepts carriage return') { expect("\r".space?).to be true }
    it('accepts mixed whitespace') { expect(" \t\n".space?).to be true }

    it('rejects letters') { expect('a'.space?).to be false }
    it('rejects empty') { expect(''.space?).to be false }
    it('rejects mixed') { expect(' a'.space?).to be false }
  end
end
