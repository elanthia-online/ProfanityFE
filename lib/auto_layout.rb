# frozen_string_literal: true

# Selects a named layout by terminal width. Window construction, resizing,
# history and redraw remain owned by the upstream WindowManager.
class AutoLayout
  # @param options [Hash] command-line layout names, thresholds and toggle
  def initialize(options = {})
    @enabled = options.fetch(:auto_layout, true)
    @narrow = options.fetch(:narrow_layout, 'default')
    @wide = options.fetch(:wide_layout, 'wide')
    @mobile = options.fetch(:mobile_layout, 'mobile')
    @wide_cols = options.fetch(:wide_layout_cols, 160)
    @mobile_cols = options.fetch(:mobile_layout_cols, 90)
  end

  # @return [Boolean] whether resize may choose a different layout
  attr_accessor :enabled

  # Missing optional layouts fall back to the narrow/default/first layout,
  # so unmodified upstream templates still work.
  # @param layouts [Hash] available layouts by name
  # @param cols [Integer] terminal width
  # @return [String, nil] selected layout ID, or nil when there are no layouts
  def choose(layouts, cols)
    return @wide if enabled && cols >= @wide_cols && layouts.key?(@wide)
    return @mobile if enabled && cols < @mobile_cols && layouts.key?(@mobile)

    [@narrow, 'default', layouts.keys.first].find { |id| layouts.key?(id) }
  end
end
