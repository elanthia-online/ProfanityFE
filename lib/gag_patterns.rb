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
      regexp = compile_pattern(pattern, 'combat gag')
      return unless regexp

      @combat_patterns << regexp
      rebuild_regexps
    end

    # Add a general gag pattern (applies to all streams).
    #
    # @param pattern [String, Regexp] pattern to match against incoming text
    # @return [void]
    # @raise [RegexpError] logged as warning if pattern string is invalid
    def add_general_pattern(pattern)
      regexp = compile_pattern(pattern, 'gag')
      return unless regexp

      @general_patterns << regexp
      rebuild_regexps
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
      gag = compile_multiline_gag(start_pattern, end_pattern)
      return unless gag

      @multiline_gags << gag
      rebuild_regexps
    end

    # Replace every custom gag with the given ones, rebuilding the union
    # regexps once. Used by settings load and reload so the gags from the
    # settings file take effect together. All patterns are compiled before
    # any set is replaced; an invalid pattern is warned about and skipped,
    # as by the add methods.
    #
    # @param general [Array<String, Regexp>] general gag patterns
    # @param multiline [Array<Hash>] multi-line gags, each
    #   { start: String|Regexp, end: String|Regexp|nil } (see #add_multiline_gag)
    # @param combat [Array<String, Regexp>] combat gag patterns
    # @return [void]
    def replace_custom(general: [], multiline: [], combat: [])
      general_patterns = default_general_patterns + general.filter_map { |p| compile_pattern(p, 'gag') }
      combat_patterns = default_combat_patterns + combat.filter_map { |p| compile_pattern(p, 'combat gag') }
      multiline_gags = default_multiline_gags +
                       multiline.filter_map { |gag| compile_multiline_gag(gag[:start], gag[:end]) }

      @general_patterns = general_patterns
      @combat_patterns = combat_patterns
      @multiline_gags = multiline_gags
      rebuild_regexps
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

    # Find the general gag pattern that matches the given line.
    #
    # The union regexp is checked first as a fast reject so the common
    # no-match case costs a single match instead of one per pattern.
    #
    # @param line [String] raw server line to test
    # @return [Regexp, nil] the first matching pattern, or nil
    def match_general(line)
      return nil unless line.match?(@general_regexp)

      @general_patterns.find { |pattern| line.match?(pattern) }
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

    # Compile a single-line gag pattern.
    #
    # @param pattern [String, Regexp] pattern to compile
    # @param kind [String] gag kind for the warning ("gag" or "combat gag")
    # @return [Regexp, nil] the regexp, or nil (with a warning) if the pattern is invalid
    # @api private
    def compile_pattern(pattern, kind)
      pattern.is_a?(Regexp) ? pattern : Regexp.new(pattern)
    rescue RegexpError => e
      warn "Invalid #{kind} pattern: #{pattern} - #{e.message}"
      nil
    end

    # Compile a multi-line gag's start and optional end patterns. A blank
    # end pattern means the block ends at the next prompt.
    #
    # @param start_pattern [String, Regexp] pattern that begins the block
    # @param end_pattern [String, Regexp, nil] optional pattern that ends the block
    # @return [Hash, nil] { start:, end: }, or nil (with a warning) if a pattern is invalid
    # @api private
    def compile_multiline_gag(start_pattern, end_pattern)
      start_regexp = start_pattern.is_a?(Regexp) ? start_pattern : Regexp.new(start_pattern)
      end_regexp = nil
      if end_pattern && !end_pattern.to_s.strip.empty?
        end_regexp = end_pattern.is_a?(Regexp) ? end_pattern : Regexp.new(end_pattern)
      end
      { start: start_regexp, end: end_regexp }
    rescue RegexpError => e
      warn "Invalid multiline gag pattern: #{start_pattern} / #{end_pattern} - #{e.message}"
      nil
    end

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

  # Start with the (empty) defaults so matching works before any gag is
  # added. Nothing else calls load_defaults, and the regexps were only
  # built when a gag was added, so a settings file with no gags left them
  # nil and every server line raised.
  load_defaults
end
