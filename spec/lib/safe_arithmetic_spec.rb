# frozen_string_literal: true

# Tests SafeArithmetic.evaluate, the parser WindowManager uses to size every
# window from layout expressions like "lines-2" or "cols/3+1".
#
# The suite used to test an eval-based copy in spec_helper that disagreed with
# this parser on malformed input: the copy returned 0 where the real parser is
# lenient. The malformed-input examples are characterization specs: the
# leniency is intentional and documented on SafeArithmetic.evaluate, and
# they pin it so any change to it is deliberate.

require_relative '../../lib/safe_arithmetic'

RSpec.describe SafeArithmetic do
  # @param expr [String] expression to evaluate
  # @return [Integer] the parser's result
  def evaluate(expr) = described_class.evaluate(expr)

  describe '.evaluate with well-formed expressions' do
    it 'evaluates layout arithmetic with the usual precedence' do
      expect(evaluate('24-2')).to eq 22
      expect(evaluate('80/3+1')).to eq 27
      expect(evaluate('1+2*3')).to eq 7
      expect(evaluate('(1+2)*3')).to eq 9
    end

    it 'ignores whitespace around operators' do
      expect(evaluate(' 1 + 2 ')).to eq 3
    end

    it 'handles unary minus, including doubled' do
      expect(evaluate('-5')).to eq(-5)
      expect(evaluate('--5')).to eq 5
    end

    it 'uses Ruby integer division, rounding toward negative infinity' do
      expect(evaluate('7/2')).to eq 3
      expect(evaluate('-7/2')).to eq(-4)
    end

    it 'returns 0 for division by zero' do
      expect(evaluate('5/0')).to eq 0
      expect(evaluate('5/(2-2)')).to eq 0
    end
  end

  # Characterization: inputs where the old spec_helper copy returned 0. The
  # parser is lenient on purpose (see the SafeArithmetic.evaluate docs).
  describe '.evaluate with malformed expressions (characterization)' do
    it 'treats a missing closing parenthesis as closed' do
      expect(evaluate('(10')).to eq 10
      expect(evaluate('2*(3')).to eq 6
    end

    it 'joins digits separated by whitespace into one number' do
      expect(evaluate('3 3')).to eq 33
    end

    it 'counts a missing trailing operand as 0' do
      expect(evaluate('1+')).to eq 1
      expect(evaluate('3-')).to eq 3
    end

    it 'ignores anything after the first complete expression' do
      expect(evaluate('10)')).to eq 10
    end

    it 'counts a missing leading operand as 0' do
      expect(evaluate('*3')).to eq 0
      expect(evaluate('2**3')).to eq 0
    end

    it 'returns 0 for an empty expression or empty parentheses' do
      expect(evaluate('')).to eq 0
      expect(evaluate('()')).to eq 0
    end
  end

  describe '.evaluate with deeply nested expressions' do
    it 'evaluates parentheses and unary minus signs nested MAX_DEPTH deep' do
      expect(evaluate("#{'(' * 100}7#{')' * 100}")).to eq 7
      expect(evaluate("#{'-' * 100}7")).to eq 7
      expect(evaluate("#{'-(' * 50}7#{')' * 50}")).to eq 7
    end

    it 'returns 0 and warns one level past MAX_DEPTH' do
      expect { expect(evaluate("#{'(' * 101}7#{')' * 101}")).to eq 0 }
        .to output(/Layout expression error: nested more than 100 levels deep/).to_stderr
      expect { expect(evaluate("#{'-' * 101}7")).to eq 0 }.to output(/nested more than 100/).to_stderr
      expect { expect(evaluate("#{'-(' * 50}-7#{')' * 50}")).to eq 0 }.to output(/nested more than 100/).to_stderr
    end

    # These used to overflow the stack: SystemStackError is not a
    # StandardError, so it escaped the rescue and ended the client.
    it 'returns 0 and warns instead of overflowing the stack' do
      expect { expect(evaluate("#{'(' * 100_000}1#{')' * 100_000}")).to eq 0 }
        .to output(/nested more than 100 levels deep/).to_stderr
      expect { expect(evaluate("#{'(' * 100_000}1")).to eq 0 }.to output(/nested more than 100/).to_stderr
      expect { expect(evaluate("#{'-' * 100_000}1")).to eq 0 }.to output(/nested more than 100/).to_stderr
    end

    it 'does not count parentheses that have closed' do
      expect(evaluate(Array.new(1000, '(1)').join('+'))).to eq 1000
    end
  end

  describe '.evaluate with unsafe characters' do
    it 'returns 0 and warns instead of evaluating' do
      expect { expect(evaluate('lines-2')).to eq 0 }
        .to output(/Invalid layout expression \(unsafe characters\): lines-2/).to_stderr
    end

    it 'never runs Ruby code' do
      expect { expect(evaluate('`touch /tmp/pwned`')).to eq 0 }.to output(/unsafe characters/).to_stderr
      expect { expect(evaluate('1.5')).to eq 0 }.to output(/unsafe characters/).to_stderr
    end
  end
end
