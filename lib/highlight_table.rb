# frozen_string_literal: true

# highlight_table.rb: the Hash of highlight patterns (HIGHLIGHT), which
# counts its own changes.

# The highlight patterns, regex => [fg, bg, ul], tried in insertion order.
# A Hash in every way, except that each method that changes it also adds
# one to {#generation}. HighlightProcessor remembers the regions it found
# for a text along with the generation they were found at, so a change
# made by any path (+.highlight+, +.unhighlight+, +.reload+, a spec
# assigning HIGHLIGHT[...] directly) is never answered from regions found
# with the old patterns.
#
# The colors arrays are not watched: HighlightProcessor reads a pattern's
# colors each time it reports a region, so changing an array in place
# shows on the next line just as it did before the regions were
# remembered.
#
# @example
#   table = HighlightTable.new
#   table[/goblin/] = ['ff0000', nil, nil]
#   table.generation # => 1
class HighlightTable < Hash
  # Hash's public methods that change a Hash: the ones that raise
  # FrozenError on a frozen Hash. A spec checks this list against the
  # running Ruby, so a mutator a new Ruby adds can't slip past.
  MUTATORS = %i[
    []= store delete delete_if reject! select! filter! keep_if clear replace
    merge! update shift compact! transform_keys! transform_values! rehash
    compare_by_identity default= default_proc=
  ].freeze

  # Each of {MUTATORS}, followed by a new generation, also when the
  # change raises part way.
  module CountsChanges
    MUTATORS.each do |name|
      define_method(name) do |*args, &block|
        super(*args, &block)
      ensure
        @generation = generation + 1
      end
    end
  end
  prepend CountsChanges

  # Changes made to this table so far: 0 for a new table (also one made
  # with HighlightTable[...]). A copy starts from its original's count and
  # counts only its own changes from then on.
  #
  # @return [Integer]
  def generation = @generation || 0
end
