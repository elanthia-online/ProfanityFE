# frozen_string_literal: true

# Color presets: the ids the game and the room window name presets by,
# and the one lookup from an id to its colors.
#
# The presets themselves live in +PRESET+ (the same Hash as
# {Config#preset}), filled from the settings' +<preset>+ elements. Any id
# can have a preset: the game's +<preset id='...'>+ and +<style id='...'>+
# tags, a stream id (a line on a stream falling back to main takes that
# stream's preset), or a room window's +title-preset+/+desc-preset+/
# +creatures-preset+ attribute.
#
# @example
#   Presets.colors(Presets::MONSTERBOLD) # => { fg: 'ffff00', bg: nil }
#   Presets.colors('no-such-preset')     # => nil
module Presets
  # Bold text: creature names (+<pushBold/>+) and familiar notifications.
  MONSTERBOLD = 'monsterbold'

  # Link colors, when a link is colored (see LinkExtractor::DEFAULT_LINK_COLOR).
  LINKS = 'links'

  # The room title style; the room window's default +title-preset+.
  ROOM_NAME = 'roomName'

  # The room description style and preset.
  ROOM_DESC = 'roomDesc'

  # The colors of preset +id+, read from +PRESET+ at the time of the call
  # (so a preset added or changed after startup is seen).
  #
  # Both keys are always present when there is a preset: a preset with
  # only a foreground has +bg: nil+.
  #
  # @param id [String, nil] preset id
  # @param default [Array(String, String), nil] +[fg, bg]+ used when +id+
  #   has no preset
  # @return [Hash{Symbol => String, nil}, nil] +{ fg:, bg: }+, or nil when
  #   +id+ has no preset and there is no default
  def self.colors(id, default = nil)
    preset = PRESET[id] || default
    preset && { fg: preset[0], bg: preset[1] }
  end
end
