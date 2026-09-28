# frozen_string_literal: true

# Stream ids: the names the game gives its text streams (the +id+ of
# +<pushStream>+, +<component>+ and +<clearStream>+) and the keys
# {WindowManager#stream} and {WindowManager#room} file windows under.
#
# A layout's text windows can list any stream, so this is not a closed
# list of what the game sends: it names the streams the code itself
# tests for or routes by.
#
# @example
#   @wm.stream[Streams::EXP]&.delete_skill
#   Streams::FALLBACK_TO_MAIN.include?(@current_stream)
module Streams
  # The primary game output window; also where text with no stream goes.
  MAIN = 'main'

  # The room stream, and the key of the room window in {WindowManager#room}.
  # Room component streams ("room desc", "room exits", ...) all start with it.
  ROOM = 'room'

  # Room component stream with the room's title.
  ROOM_TITLE = 'room title'

  # Room component stream with the room's description.
  ROOM_DESC = 'room desc'

  # The other id a room description component is accepted under.
  ROOM_DESC_ALT = 'roomDesc'

  # Room component stream with the room's objects (and creatures).
  ROOM_OBJS = 'room objs'

  # Room component stream with the other players in the room.
  ROOM_PLAYERS = 'room players'

  # Room component stream with the room's obvious exits.
  ROOM_EXITS = 'room exits'

  # The experience stream. A stream id of "exp <skill>" is read as this
  # stream with that skill current.
  EXP = 'exp'

  # The active spells stream (the percWindow).
  PERC = 'percWindow'

  # Combat messages.
  COMBAT = 'combat'

  # Deaths.
  DEATH = 'death'

  # Arrivals and departures.
  LOGONS = 'logons'

  # Speech.
  SPEECH = 'speech'

  # Thoughts; also where LNet chat arrives.
  THOUGHTS = 'thoughts'

  # LNet chat, split off {THOUGHTS} when the layout has a window for it.
  LNET = 'lnet'

  # Familiar messages; also the default notification stream
  # ({Config::DEFAULT_NOTIFICATION_STREAM}).
  FAMILIAR = 'familiar'

  # Voln messages.
  VOLN = 'voln'

  # Assess output.
  ASSESS = 'assess'

  # Out-of-character messages.
  OOC = 'ooc'

  # Shop listings.
  SHOP = 'shopWindow'

  # Moon status.
  MOON = 'moonWindow'

  # Atmospheric messages.
  ATMOSPHERICS = 'atmospherics'

  # Streams shown in the main window when the layout has no window for
  # them; text on any other stream with no window isn't shown in main.
  # Highlights apply to text on these streams even without a window.
  FALLBACK_TO_MAIN = [DEATH, LOGONS, THOUGHTS, VOLN, FAMILIAR, ASSESS, OOC, SHOP, COMBAT, MOON, ATMOSPHERICS].freeze

  # Streams whose lines get a timestamp with --speech-ts when they go to
  # their own window.
  TIMESTAMPED_IN_WINDOW = [SPEECH, THOUGHTS, FAMILIAR].freeze

  # Streams whose lines get a timestamp with --speech-ts when they fall
  # back to main (see {FALLBACK_TO_MAIN}). Deliberately not {SPEECH}: a
  # speech line is timestamped only in a speech window (a maintainer
  # decision; speech isn't in {FALLBACK_TO_MAIN} either).
  TIMESTAMPED_IN_MAIN = [THOUGHTS, FAMILIAR].freeze
end
