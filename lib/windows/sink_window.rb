# frozen_string_literal: true

=begin
Null-object window that silently discards all content.
=end

# Null-object window for stream suppression.
#
# Answers the messages WindowManager sends a stream window (see
# {StreamWindow}) but discards all input. Does not inherit from BaseWindow or Curses::Window — it's
# a pure duck-type that responds to the same messages without creating
# any Curses resources.
#
# @example Layout XML usage
#   <window class='sink' value='atmospherics'/>
#   <window class='sink' value='combat,assess'/>
class SinkWindow
  # No-op: sinks don't participate in window lists.
  # @return [void]
  def add_string(*); end

  # No-op: sinks discard tab-routed text.
  # @return [void]
  def add_string_to_tab(*); end

  # No-op: sinks discard routed text.
  # @return [void]
  def route_string(*); end

  # No-op: sinks discard rendered lines.
  # @return [void]
  def add_line(*); end

  # No-op: nothing to redraw.
  # @return [void]
  def redraw; end

  # No-op: sinks discard components (see {StreamWindow#component_opened}).
  # @return [void]
  def component_opened(*); end

  # No-op: sinks discard components (see {StreamWindow#component_closed}).
  # @return [void]
  def component_closed; end

  # No-op: nothing to clear (see {StreamWindow#stream_cleared}).
  # @return [void]
  def stream_cleared; end
end
