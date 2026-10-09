# frozen_string_literal: true

# Safe arithmetic evaluation for layout dimension expressions.

# Safe arithmetic expression evaluator for layout dimensions.
#
# Lives in lib (rather than the profanity.rb entry script) so the classes
# that size windows, such as {WindowManager}, work when loaded on their own.
#
# @example
#   SafeArithmetic.evaluate('24-2')               # => 22
#   SafeArithmetic.evaluate('80/3+1')             # => 27
#   SafeArithmetic.evaluate('max(1, min(16, 5))') # => 5
module SafeArithmetic
  module_function

  # How deep {.evaluate} lets parentheses, unary minus signs and
  # +min+/+max+ calls nest. Each level is a recursive call, so without a
  # limit deep enough nesting (a few thousand levels) overflows the stack.
  # The layouts in templates/ nest at most 3 deep.
  MAX_DEPTH = 100

  # The functions an expression may call, each with exactly two
  # arguments: the smaller and the larger of two values.
  FUNCTIONS = { 'min' => :min, 'max' => :max }.freeze

  # Safe arithmetic expression evaluator for layout dimensions.
  # Parses integers, +, -, *, /, parentheses and the two-argument
  # functions +min(a, b)+ and +max(a, b)+ without using eval.
  # Uses a simple recursive descent parser (expression → term → factor).
  #
  # A +min+/+max+ call is a factor, like a number or a parenthesised
  # expression, and its arguments are whole expressions, so calls nest and
  # combine with the operators: "max(1, min(16, 24-19))" is 5 and
  # "2*min(3, 4)" is 6. A malformed call is an error: a name not followed
  # by "(", other than two arguments, an empty argument, or a missing ")"
  # ("min(1)", "min(1, 2, 3)", "min(, 2)", "min(1, 2"). So is a comma
  # outside a call's argument list ("1, 2", "(1, 2)"), and a name other
  # than +min+ and +max+ counts as an unsafe character.
  #
  # Otherwise the parser is lenient: a missing closing parenthesis is
  # ignored ("(10" is 10), whitespace between digits is dropped ("3 3" is
  # 33), a missing operand counts as 0 ("1+" is 1), and anything after the
  # first complete expression is ignored ("10)" is 10).
  #
  # Parentheses, unary minus signs and calls may nest {MAX_DEPTH} levels
  # deep ("-(1)" and "-min(1, 2)" are two levels); deeper nesting is an
  # error.
  #
  # @param expr [String] arithmetic expression (e.g., "lines-2", "cols/3+1",
  #   "min(16, lines-19)"), after "lines"/"cols" have been replaced by
  #   numbers
  # @return [Integer] computed result, or 0 on error (including division by
  #   zero, a malformed call and nesting deeper than {MAX_DEPTH})
  def evaluate(expr)
    tokens = expr.gsub(/\s+/, '').scan(%r{(\d+|[a-z]+|[+\-*/(),]|.)})
                 .flatten.reject(&:empty?)

    # Reject tokens that aren't valid arithmetic
    unless tokens.all? { |t| t.match?(%r{\A(\d+|[+\-*/(),])\z}) || FUNCTIONS.key?(t) }
      warn "Invalid layout expression (unsafe characters): #{expr}"
      return 0
    end

    pos = [0] # mutable position index
    depth = 0 # parentheses, unary minus signs and call arguments open at pos

    # Recursive descent: expr → term ((+|-) term)*
    parse_expr = nil
    parse_term = nil
    parse_factor = nil

    # Parse one level deeper (inside parentheses, after a unary minus or in
    # a call's argument)
    nested = lambda { |parse|
      depth += 1
      raise ArgumentError, "nested more than #{MAX_DEPTH} levels deep" if depth > MAX_DEPTH

      result = parse.call
      depth -= 1
      result
    }

    # A comma ends an expression only between a call's arguments
    no_comma = lambda {
      raise ArgumentError, 'a comma only separates the arguments of min(...) or max(...)' if tokens[pos[0]] == ','
    }

    # Parse a min/max call's two arguments, from just after its name
    parse_call = lambda { |name|
      raise ArgumentError, "#{name} must be followed by (" unless tokens[pos[0]] == '('

      args = []
      loop do
        pos[0] += 1 # consume '(' or ','
        raise ArgumentError, "empty argument in #{name}(...)" if [',', ')', nil].include?(tokens[pos[0]])

        args << nested.call(parse_expr)
        break unless tokens[pos[0]] == ','
      end
      raise ArgumentError, "#{name}(...) is missing its closing parenthesis" unless tokens[pos[0]] == ')'
      raise ArgumentError, "#{name} takes 2 arguments, not #{args.size}" unless args.size == 2

      pos[0] += 1 # consume ')'
      args.public_send(FUNCTIONS.fetch(name))
    }

    parse_factor = lambda {
      if tokens[pos[0]] == '('
        pos[0] += 1
        result = nested.call(parse_expr)
        no_comma.call
        pos[0] += 1 if tokens[pos[0]] == ')' # consume ')'
        result
      elsif FUNCTIONS.key?(tokens[pos[0]])
        name = tokens[pos[0]]
        pos[0] += 1
        parse_call.call(name)
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

    result = parse_expr.call
    no_comma.call
    result.to_i
  rescue StandardError => e
    warn "Layout expression error: #{e.message} in '#{expr}'"
    0
  end
end
