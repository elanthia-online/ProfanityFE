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

  # No-op: stands in for {ExpWindow#set_current} when a sink replaces the exp window.
  # @return [void]
  def set_current(*); end

  # No-op: stands in for {ExpWindow#delete_skill} when a sink replaces the exp window.
  # @return [void]
  def delete_skill(*); end

  # No-op: stands in for {PercWindow#clear_spells} when a sink replaces the spell window.
  # @return [void]
  def clear_spells; end
end
