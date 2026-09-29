# frozen_string_literal: true

# Safe arithmetic evaluation for layout dimension expressions.

# Safe arithmetic expression evaluator for layout dimensions.
#
# Lives in lib (rather than the profanity.rb entry script) so the classes
# that size windows, such as {WindowManager}, work when loaded on their own.
#
# @example
#   SafeArithmetic.evaluate('24-2')   # => 22
#   SafeArithmetic.evaluate('80/3+1') # => 27
module SafeArithmetic
  module_function

  # How deep {.evaluate} lets parentheses and unary minus signs nest. Each
  # level is a recursive call, so without a limit deep enough nesting (a
  # few thousand levels) overflows the stack. The layouts in templates/
  # nest at most 2 deep.
  MAX_DEPTH = 100

  # Safe arithmetic expression evaluator for layout dimensions.
  # Parses integers, +, -, *, /, and parentheses without using eval.
  # Uses a simple recursive descent parser (expression → term → factor).
  #
  # The parser is lenient: a missing closing parenthesis is ignored
  # ("(10" is 10), whitespace between digits is dropped ("3 3" is 33),
  # a missing operand counts as 0 ("1+" is 1), and anything after the
  # first complete expression is ignored ("10)" is 10).
  #
  # Parentheses and unary minus signs may nest {MAX_DEPTH} levels deep
  # ("-(1)" is two levels); deeper nesting is an error.
  #
  # @param expr [String] arithmetic expression (e.g., "lines-2", "cols/3+1"),
  #   after "lines"/"cols" have been replaced by numbers
  # @return [Integer] computed result, or 0 on error (including division by
  #   zero and nesting deeper than {MAX_DEPTH})
  def evaluate(expr)
    tokens = expr.gsub(/\s+/, '').scan(%r{(\d+|[+\-*/()]|.)})
                 .flatten.reject(&:empty?)

    # Reject tokens that aren't valid arithmetic
    unless tokens.all? { |t| t.match?(%r{\A(\d+|[+\-*/()])\z}) }
      warn "Invalid layout expression (unsafe characters): #{expr}"
      return 0
    end

    pos = [0] # mutable position index
    depth = 0 # parentheses and unary minus signs open at pos

    # Recursive descent: expr → term ((+|-) term)*
    parse_expr = nil
    parse_term = nil
    parse_factor = nil

    # Parse one level deeper (inside parentheses or after a unary minus)
    nested = lambda { |parse|
      depth += 1
      raise ArgumentError, "nested more than #{MAX_DEPTH} levels deep" if depth > MAX_DEPTH

      result = parse.call
      depth -= 1
      result
    }

    parse_factor = lambda {
      if tokens[pos[0]] == '('
        pos[0] += 1
        result = nested.call(parse_expr)
        pos[0] += 1 if tokens[pos[0]] == ')' # consume ')'
        result
      elsif tokens[pos[0]] == '-'
        pos[0] += 1
        -nested.call(parse_factor)
      elsif tokens[pos[0]]&.match?(/\A\d+\z/)
        val = tokens[pos[0]].to_i
        pos[0] += 1
        val
      else
        0
      end
    }

    parse_term = lambda {
      result = parse_factor.call
      while pos[0] < tokens.length && %w[* /].include?(tokens[pos[0]])
        op = tokens[pos[0]]
        pos[0] += 1
        right = parse_factor.call
        if op == '*'
          result *= right
        elsif right != 0
          result /= right
        else
          result = 0 # division by zero → 0
        end
      end
      result
    }

    parse_expr = lambda {
      result = parse_term.call
      while pos[0] < tokens.length && %w[+ -].include?(tokens[pos[0]])
        op = tokens[pos[0]]
        pos[0] += 1
        right = parse_term.call
        result = op == '+' ? result + right : result - right
      end
      result
    }

    parse_expr.call.to_i
  rescue StandardError => e
    warn "Layout expression error: #{e.message} in '#{expr}'"
    0
  end
end
