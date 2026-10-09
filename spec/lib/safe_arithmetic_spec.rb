# frozen_string_literal: true

# Tests SafeArithmetic.evaluate, the parser WindowManager uses to size every
# window from layout expressions like "lines-2", "cols/3+1" or
# "min(16, lines-19)".
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

  describe '.evaluate with min and max' do
    it 'returns the smaller or larger of two values, either way round' do
      expect(evaluate('min(16, 5)')).to eq 5
      expect(evaluate('min(5, 16)')).to eq 5
      expect(evaluate('max(16, 5)')).to eq 16
      expect(evaluate('max(5, 16)')).to eq 16
      expect(evaluate('min(7, 7)')).to eq 7
    end

    it 'takes whole expressions as arguments' do
      expect(evaluate('min(16, 24-19)')).to eq 5
      expect(evaluate('min(16, 80-19)')).to eq 16
      expect(evaluate('min(240/3, 40+1)')).to eq 41
      expect(evaluate('max(1, (80/3)*2-60)')).to eq 1
    end

    it 'nests calls' do
      expect(evaluate('max(1, min(16, 24-19))')).to eq 5
      expect(evaluate('max(1, min(16, 20-19-5))')).to eq 1
      expect(evaluate('min(max(2, 3), max(4, min(9, 1)))')).to eq 3
    end

    it 'treats a call as a factor of the surrounding arithmetic' do
      expect(evaluate('2*min(3, 4)')).to eq 6
      expect(evaluate('min(3, 4)*2')).to eq 6
      expect(evaluate('min(3, 4)+max(3, 4)')).to eq 7
      expect(evaluate('10-min(3, 4)')).to eq 7
      expect(evaluate('-min(3, 4)')).to eq(-3)
      expect(evaluate('80/max(1, 0)')).to eq 80
    end

    it 'compares negative values as numbers' do
      expect(evaluate('max(-5, -3)')).to eq(-3)
      expect(evaluate('min(0, 24-30)')).to eq(-6)
    end

    it 'ignores whitespace around the arguments' do
      expect(evaluate(' min ( 16 , 5 ) ')).to eq 5
    end

    it 'counts each call as one level of nesting' do
      expect(evaluate("#{'min(1, ' * 100}7#{')' * 100}")).to eq 1
      expect { expect(evaluate("#{'min(9, ' * 101}7#{')' * 101}")).to eq 0 }
        .to output(/nested more than 100 levels deep/).to_stderr
      expect(evaluate("#{'-min(9, ' * 50}7#{')' * 50}")).to eq 7 # 50 minus signs and 50 calls
      expect { expect(evaluate("#{'-min(9, ' * 51}7#{')' * 51}")).to eq 0 }.to output(/nested more than 100/).to_stderr
    end

    it 'returns 0 and warns for a call with other than two arguments' do
      expect { expect(evaluate('min(1)')).to eq 0 }
        .to output(/Layout expression error: min takes 2 arguments, not 1 in 'min\(1\)'/).to_stderr
      expect { expect(evaluate('max(1, 2, 3)')).to eq 0 }.to output(/max takes 2 arguments, not 3/).to_stderr
    end

    it 'returns 0 and warns for an empty argument' do
      %w[min() min(,2) min(1,) max(1,,2) min(].each do |expr|
        expect { expect(evaluate(expr)).to eq 0 }.to output(/empty argument in min\(\.\.\.\)|empty argument in max/).to_stderr
      end
    end

    it 'returns 0 and warns for a call missing its closing parenthesis' do
      expect { expect(evaluate('min(1, 2')).to eq 0 }
        .to output(/min\(\.\.\.\) is missing its closing parenthesis in 'min\(1, 2'/).to_stderr
      expect { expect(evaluate('max(1, min(2, 3)')).to eq 0 }.to output(/max\(\.\.\.\) is missing its closing/).to_stderr
    end

    it 'returns 0 and warns for a name not followed by a parenthesis' do
      expect { expect(evaluate('min')).to eq 0 }.to output(/min must be followed by \(/).to_stderr
      expect { expect(evaluate('max+1')).to eq 0 }.to output(/max must be followed by \(/).to_stderr
      expect { expect(evaluate('2*min 3')).to eq 0 }.to output(/min must be followed by \(/).to_stderr
    end

    it 'returns 0 and warns for a comma outside the arguments of a call' do
      ['1, 2', '(1, 2)', 'min(1, (2, 3))', '4+5, 6'].each do |expr|
        expect { expect(evaluate(expr)).to eq 0 }
          .to output(/a comma only separates the arguments of min\(\.\.\.\) or max\(\.\.\.\)/).to_stderr
      end
    end

    it 'treats any other name, or min and max in capitals, as unsafe characters' do
      %w[mid(1,2) minimum(1,2) MIN(1,2) Max(1,2) abs(3)].each do |expr|
        expect { expect(evaluate(expr)).to eq 0 }
          .to output(/Invalid layout expression \(unsafe characters\): #{Regexp.escape(expr)}/).to_stderr
      end
    end

    it 'ignores anything after a complete call, as after any complete expression' do
      expect(evaluate('min(1, 2)3')).to eq 1
      expect(evaluate('min(1, 2))')).to eq 1
    end

    # Text after a complete expression is otherwise ignored, but before
    # min/max there were no names, so a name there was always an error
    # ("2min(30, 40)" meant as 2*min would silently be 2).
    it 'returns 0 and warns for a name after a complete expression, where an operator is missing' do
      {
        '2min(30, 40)' => 'min', '3min' => 'min', '16max' => 'max', 'min(1, 2)max' => 'max',
        'min(1, 2)max(3, 4)' => 'max', '(2)min(1, 2)' => 'min', '(2 min(1, 2))' => 'min',
        '10)min(1, 2)' => 'min', '4 max(1, 2)' => 'max'
      }.each do |expr, name|
        expect { expect(evaluate(expr)).to eq 0 }
          .to output(/#{name} after the end of the expression \(missing an operator\?\) in '#{Regexp.escape(expr)}'/).to_stderr
      end
    end

    it 'still ignores a number or parenthesis after a complete expression' do
      expect { expect(evaluate('2(3)')).to eq 2 }.not_to output.to_stderr
      expect { expect(evaluate('min(1, 2)(3)')).to eq 1 }.not_to output.to_stderr
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
      expect { expect(evaluate('min(1, exit)')).to eq 0 }.to output(/unsafe characters/).to_stderr
      expect { expect(evaluate('min.call(1, 2)')).to eq 0 }.to output(/unsafe characters/).to_stderr
      expect { expect(evaluate('send(:min, 1, 2)')).to eq 0 }.to output(/unsafe characters/).to_stderr
    end
  end
end
