# frozen_string_literal: true

# Receiving routed stream text and prompts, for the windows that take it.

# The part of a window that {WindowManager} routes stream text and
# prompts to: every window a layout can put in the stream table (text,
# tabbed, exp and spell windows). {SinkWindow} answers the same messages
# without including it. Room, indicator, progress and countdown windows
# get their content through their own update methods instead, so they
# don't include it.
#
# The including window supplies
# +add_string(text, colors = [], indent: nil)+, and may override
# {#prompt_buffer} to have repeated bare prompts suppressed, and
# {#component_opened}, {#component_closed} and {#stream_cleared} to keep
# a stream's content as entries rather than show its lines as they come
# (the exp and spell windows do).
module StreamWindow
  # Route text to this window. Default: +add_string+ it.
  # TabbedTextWindow overrides this to route to the stream's tab.
  #
  # @param text [String] the text to display
  # @param colors [Array<Hash>] color region descriptors
  # @param _stream [String, nil] stream name (used by TabbedTextWindow override)
  # @param indent [Boolean, nil] indent continuation lines (nil = window default)
  # @return [void]
  def route_string(text, colors, _stream = nil, indent: nil)
    add_string(text, colors, indent: indent)
  end

  # A keyed component of a stream opened: the game sends each skill on
  # the exp stream as one (+<component id='exp Parry Ability'>+ has the
  # key "Parry Ability"), and the text up to {#component_closed} is that
  # component's. Default: nothing, so the text shows as it arrives.
  #
  # @param _key [String] the component's key
  # @return [void]
  def component_opened(_key); end

  # The component {#component_opened} announced closed. Default: nothing.
  #
  # @return [void]
  def component_closed; end

  # The game cleared a stream (+<clearStream id="percWindow"/>+) and sends
  # its whole content again next. Default: nothing, so the lines already
  # shown stay, as for any other stream.
  #
  # @return [void]
  def stream_cleared; end

  # Check if the most recent non-empty line of the window's prompt buffer
  # (see {#prompt_buffer}) matches the given prompt text. Used to suppress
  # duplicate bare prompts.
  #
  # @param prompt_text [String] the prompt string to check against
  # @return [Boolean, nil] false for a window without a prompt buffer or
  #   with an empty one, else as {LineBuffer#newest_text?}
  def duplicate_prompt?(prompt_text)
    line_buffer = prompt_buffer
    return false unless line_buffer

    line_buffer.newest_text?(prompt_text)
  end

  # The buffer prompts routed to this window land in, which
  # {#duplicate_prompt?} checks. Default: none, so no prompt is a
  # duplicate.
  #
  # @return [LineBuffer, nil]
  private def prompt_buffer
    nil
  end
end
