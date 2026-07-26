# frozen_string_literal: true

# gag_patterns.rb: Gag pattern management for filtering unwanted text from display.
# Patterns loaded from XML config via <gag> and <combat_gag> elements.

# Manages gag patterns that filter unwanted text from the display.
# Patterns can be loaded from the XML config file or added programmatically.
# Maintains three pattern sets: general (all streams, single line), combat
# (single line), and multi-line (a start pattern that suppresses a block of
# lines until an end pattern or the next game prompt).
#
# @example
#   GagPatterns.load_defaults
#   GagPatterns.add_general_pattern('You also see .* moth')
#   GagPatterns.general_regexp  # => /(?-mix:You also see .* moth)/
#
# @example Multi-line gag
#   GagPatterns.add_multiline_gag('Knowledge from your sanowret crystal')
#   GagPatterns.match_multiline_start('Knowledge from your sanowret crystal ...')
#   # => { start: /.../, end: nil }
module GagPatterns
  @combat_patterns = []
  @general_patterns = []
  @multiline_gags = []
  @combat_regexp = nil
  @general_regexp = nil
  @multiline_start_regexp = nil

  class << self
    # @return [Regexp] combined regexp matching any combat gag pattern
    attr_reader :combat_regexp

    # @return [Regexp] combined regexp matching any general gag pattern
    attr_reader :general_regexp

    # @return [Array<Hash>] multi-line gag definitions, each { start:, end: }
    attr_reader :multiline_gags

    # Initialize with default patterns (empty). Call at startup.
    #
    # @return [void]
    def load_defaults
      @combat_patterns = default_combat_patterns.dup
      @general_patterns = default_general_patterns.dup
      @multiline_gags = default_multiline_gags.dup
      rebuild_regexps
    end

    # Add a combat stream gag pattern.
    #
    # @param pattern [String, Regexp] pattern to match against combat text
    # @return [void]
    # @raise [RegexpError] logged as warning if pattern string is invalid
    def add_combat_pattern(pattern)
      regexp = pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)
      @combat_patterns << regexp
      rebuild_regexps
    rescue RegexpError => e
      warn "Invalid combat gag pattern: #{pattern} - #{e.message}"
    end

    # Add a general gag pattern (applies to all streams).
    #
    # @param pattern [String, Regexp] pattern to match against incoming text
    # @return [void]
    # @raise [RegexpError] logged as warning if pattern string is invalid
    def add_general_pattern(pattern)
      regexp = pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)
      @general_patterns << regexp
      rebuild_regexps
    rescue RegexpError => e
      warn "Invalid gag pattern: #{pattern} - #{e.message}"
    end

    # Add a multi-line gag. When a line matches +start_pattern+, that line
    # and every following line are suppressed until either +end_pattern+
    # matches (that end line is also suppressed) or, if no end pattern is
    # given, the next game prompt is reached (the prompt is not suppressed).
    #
    # @param start_pattern [String, Regexp] pattern that begins the block
    # @param end_pattern [String, Regexp, nil] optional pattern that ends the
    #   block; when nil the block is terminated by the next prompt
    # @return [void]
    # @raise [RegexpError] logged as warning if a pattern string is invalid
    def add_multiline_gag(start_pattern, end_pattern = nil)
      start_regexp = start_pattern.is_a?(Regexp) ? start_pattern : Regexp.new(start_pattern)
      end_regexp = nil
      if end_pattern && !end_pattern.to_s.strip.empty?
        end_regexp = end_pattern.is_a?(Regexp) ? end_pattern : Regexp.new(end_pattern)
      end
      @multiline_gags << { start: start_regexp, end: end_regexp }
      rebuild_regexps
    rescue RegexpError => e
      warn "Invalid multiline gag pattern: #{start_pattern} / #{end_pattern} - #{e.message}"
    end

    # Find the multi-line gag whose start pattern matches the given line.
    #
    # A union regexp is checked first as a fast reject so the common
    # no-match case costs a single match instead of one per gag.
    #
    # @param line [String] raw server line to test
    # @return [Hash, nil] the matching { start:, end: } gag, or nil
    def match_multiline_start(line)
      return nil if @multiline_gags.empty?
      return nil unless line.match?(@multiline_start_regexp)

      @multiline_gags.find { |gag| line.match?(gag[:start]) }
    end

    # Reset to default patterns, discarding any custom patterns.
    # Called during settings reload to re-apply patterns from XML.
    #
    # @return [void]
    def clear_custom
      @combat_patterns = default_combat_patterns.dup
      @general_patterns = default_general_patterns.dup
      @multiline_gags = default_multiline_gags.dup
      rebuild_regexps
    end

    private

    # Rebuild the union regexps from the current pattern arrays.
    #
    # @return [void]
    # @api private
    def rebuild_regexps
      @combat_regexp = Regexp.union(@combat_patterns)
      @general_regexp = Regexp.union(@general_patterns)
      @multiline_start_regexp = Regexp.union(@multiline_gags.map { |gag| gag[:start] })
    end

    # @return [Array<Regexp>] default combat gag patterns (empty)
    # @api private
    def default_combat_patterns
      []
    end

    # @return [Array<Regexp>] default general gag patterns (empty)
    # @api private
    def default_general_patterns
      []
    end

    # @return [Array<Hash>] default multi-line gags (empty)
    # @api private
    def default_multiline_gags
      []
    end
  end
end
