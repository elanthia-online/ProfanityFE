# frozen_string_literal: true

# gag_patterns.rb: Gag pattern management for filtering unwanted text from display.
# Patterns loaded from XML config via <gag> and <combat_gag> elements.

# Manages gag patterns that filter unwanted text from the display.
# Patterns can be loaded from the XML config file or added programmatically.
# Maintains three pattern sets: general (all streams, single line), combat
# (single line), and multi-line (a start pattern that suppresses a block of
# lines until an end pattern or the next game prompt).
#
# == Concurrency
#
# The server thread reads the gags on every line ({match_general},
# {match_multiline_start}, {combat_regexp}) while the input thread may
# replace them (+.reload+). All gag state lives in one frozen {Snapshot}:
# the three pattern lists and their union regexps. A writer builds a
# complete new snapshot off to the side and publishes it with a single
# ivar assignment, so a reader sees either the old configuration or the
# new one, never a mix, without taking a lock. Each reader loads the
# snapshot once per call and uses only that. Writers ({load_defaults},
# the +add_*+ methods, {clear_custom}, {replace_custom}) are serialized by
# a mutex so concurrent adds are not lost. The lists returned by
# {multiline_gags} are frozen and never change after they are returned.
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
  # One complete, immutable gag configuration: the pattern lists and the
  # union regexps built from them. Build with {.build}; never mutated.
  #
  # @!attribute [r] general_patterns
  #   @return [Array<Regexp>] general gag patterns (frozen)
  # @!attribute [r] combat_patterns
  #   @return [Array<Regexp>] combat gag patterns (frozen)
  # @!attribute [r] multiline_gags
  #   @return [Array<Hash>] multi-line gags, each a frozen { start:, end: } (frozen)
  # @!attribute [r] general_regexp
  #   @return [Regexp] union of the general patterns
  # @!attribute [r] combat_regexp
  #   @return [Regexp] union of the combat patterns
  # @!attribute [r] multiline_start_regexp
  #   @return [Regexp] union of the multi-line start patterns
  Snapshot = Data.define(:general_patterns, :combat_patterns, :multiline_gags,
                         :general_regexp, :combat_regexp, :multiline_start_regexp) do
    # Build a snapshot from pattern lists, freezing them and computing the
    # union regexps.
    #
    # @param general [Array<Regexp>] general gag patterns
    # @param combat [Array<Regexp>] combat gag patterns
    # @param multiline [Array<Hash>] multi-line gags, each { start:, end: }
    # @return [Snapshot]
    def self.build(general:, combat:, multiline:)
      general = general.dup.freeze
      combat = combat.dup.freeze
      multiline = multiline.map { |gag| gag.dup.freeze }.freeze
      new(general_patterns: general, combat_patterns: combat, multiline_gags: multiline,
          general_regexp: Regexp.union(general), combat_regexp: Regexp.union(combat),
          multiline_start_regexp: Regexp.union(multiline.map { |gag| gag[:start] }))
    end
  end

  @write_lock = Mutex.new
  @snapshot = nil

  class << self
    # @return [Regexp] combined regexp matching any combat gag pattern
    def combat_regexp = @snapshot.combat_regexp

    # @return [Regexp] combined regexp matching any general gag pattern
    def general_regexp = @snapshot.general_regexp

    # @return [Array<Hash>] multi-line gag definitions, each { start:, end: }
    #   (frozen; a later change publishes a new list instead)
    def multiline_gags = @snapshot.multiline_gags

    # Initialize with default patterns (empty). Call at startup.
    #
    # @return [void]
    def load_defaults
      publish { defaults_snapshot }
    end

    # Add a combat stream gag pattern. An invalid pattern string is warned
    # about and not added.
    #
    # @param pattern [String, Regexp] pattern to match against combat text
    # @return [void]
    def add_combat_pattern(pattern)
      regexp = compile_pattern(pattern, 'combat gag')
      return unless regexp

      publish { |current| rebuild(current, combat: current.combat_patterns + [regexp]) }
    end

    # Add a general gag pattern (applies to all streams). An invalid
    # pattern string is warned about and not added.
    #
    # @param pattern [String, Regexp] pattern to match against incoming text
    # @return [void]
    def add_general_pattern(pattern)
      regexp = compile_pattern(pattern, 'gag')
      return unless regexp

      publish { |current| rebuild(current, general: current.general_patterns + [regexp]) }
    end

    # Add a multi-line gag. When a line matches +start_pattern+, that line
    # and every following line are suppressed until either +end_pattern+
    # matches (that end line is also suppressed) or, if no end pattern is
    # given, the next game prompt is reached (the prompt is not suppressed).
    # If either pattern string is invalid, it is warned about and the gag is
    # not added.
    #
    # @param start_pattern [String, Regexp] pattern that begins the block
    # @param end_pattern [String, Regexp, nil] optional pattern that ends the
    #   block; when nil the block is terminated by the next prompt
    # @return [void]
    def add_multiline_gag(start_pattern, end_pattern = nil)
      gag = compile_multiline_gag(start_pattern, end_pattern)
      return unless gag

      publish { |current| rebuild(current, multiline: current.multiline_gags + [gag]) }
    end

    # Replace every custom gag with the given ones in one step. Used by
    # settings load and reload so the gags from the settings file take
    # effect together. All patterns are compiled and the new snapshot is
    # built before it is published; an invalid pattern is warned about and
    # skipped, as by the add methods.
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

      publish { Snapshot.build(general: general_patterns, combat: combat_patterns, multiline: multiline_gags) }
    end

    # Find the multi-line gag whose start pattern matches the given line.
    #
    # A union regexp is checked first as a fast reject so the common
    # no-match case costs a single match instead of one per gag.
    #
    # @param line [String] raw server line to test
    # @return [Hash, nil] the matching { start:, end: } gag (frozen), or nil
    def match_multiline_start(line)
      snapshot = @snapshot
      return nil if snapshot.multiline_gags.empty?
      return nil unless line.match?(snapshot.multiline_start_regexp)

      snapshot.multiline_gags.find { |gag| line.match?(gag[:start]) }
    end

    # Find the general gag pattern that matches the given line.
    #
    # The union regexp is checked first as a fast reject so the common
    # no-match case costs a single match instead of one per pattern.
    #
    # @param line [String] raw server line to test
    # @return [Regexp, nil] the first matching pattern, or nil
    def match_general(line)
      snapshot = @snapshot
      return nil unless line.match?(snapshot.general_regexp)

      snapshot.general_patterns.find { |pattern| line.match?(pattern) }
    end

    # Reset to default patterns, discarding any custom patterns.
    # Called during settings reload to re-apply patterns from XML.
    #
    # @return [void]
    def clear_custom
      publish { defaults_snapshot }
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

    # Build the next snapshot under the write lock and publish it with a
    # single assignment, so readers never see a partly built one.
    #
    # @yieldparam current [Snapshot, nil] the published snapshot
    # @yieldreturn [Snapshot] the snapshot to publish
    # @return [void]
    # @api private
    def publish
      @write_lock.synchronize { @snapshot = yield(@snapshot) }
      nil
    end

    # Build a snapshot from +current+ with some pattern lists replaced.
    #
    # @param current [Snapshot] snapshot to start from
    # @param general [Array<Regexp>] general gag patterns
    # @param combat [Array<Regexp>] combat gag patterns
    # @param multiline [Array<Hash>] multi-line gags
    # @return [Snapshot]
    # @api private
    def rebuild(current, general: current.general_patterns, combat: current.combat_patterns,
                multiline: current.multiline_gags)
      Snapshot.build(general: general, combat: combat, multiline: multiline)
    end

    # @return [Snapshot] a snapshot holding only the default patterns
    # @api private
    def defaults_snapshot
      Snapshot.build(general: default_general_patterns, combat: default_combat_patterns,
                     multiline: default_multiline_gags)
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
