# frozen_string_literal: true

# The screen updates asked for since the last flush.
#
# Parsing a server line only records that something changed; {ServerReader}
# draws the screen once no more server data is waiting, so a burst of lines
# is drawn once. A room render is asked for separately and drawn at the
# next flush.
class PendingRender
  def initialize
    @update = false
    @room_render = false
  end

  # Ask for the screen to be flushed.
  #
  # @return [void]
  def request_update
    @update = true
  end

  # Ask for the room window to be rendered at the next flush.
  #
  # @return [void]
  def request_room_render
    @room_render = true
  end

  # @return [Boolean] whether a flush was asked for since the last one
  def update_requested?
    @update
  end

  # @return [Boolean] whether a room render is waiting for the next flush
  def room_render_requested?
    @room_render
  end

  # Forget the flush request (the flush is being done).
  #
  # @return [void]
  def clear_update
    @update = false
  end

  # Forget the room render request (the render is being done).
  #
  # @return [void]
  def clear_room_render
    @room_render = false
  end
end
