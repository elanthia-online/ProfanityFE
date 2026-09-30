# frozen_string_literal: true

=begin
String classification refinement for character-type checking.
Used by CommandBuffer for word-boundary detection in readline-style editing.
=end

# Adds character classification methods to String via refinement.
#
# @example
#   using StringClassification
#   "abc".alnum?  #=> true
#   "123".digits? #=> true
#   "!@#".punct?  #=> true
module StringClassification
  refine String do
    # @return [Boolean] true if the string is non-empty and every character,
    #   newlines included, is alphanumeric
    def alnum?
      !!match(/\A[[:alnum:]]+\z/)
    end

    # @return [Boolean] true if the string is non-empty and every character,
    #   newlines included, is a digit
    def digits?
      !!match(/\A[[:digit:]]+\z/)
    end

    # @return [Boolean] true if the string is non-empty and every character,
    #   newlines included, is punctuation
    def punct?
      !!match(/\A[[:punct:]]+\z/)
    end

    # @return [Boolean] true if the string is non-empty and every character,
    #   newlines included, is whitespace
    def space?
      !!match(/\A[[:space:]]+\z/)
    end
  end
end
