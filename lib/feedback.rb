# frozen_string_literal: true

# Lines Profanity writes to a window itself, such as dot-command replies,
# the autocomplete list and the disconnect notice, as opposed to text from
# the game. Each line is drawn whole in one foreground color, in the
# feedback color unless another is given.
#
# {.write} only adds the lines to the window, which stages them with
# +noutrefresh+; it never flushes the screen or takes the render lock. The
# caller decides whether and when to flush. {Application#write_to_client}
# writes to the main window and flushes.
#
# @example A block of lines framed by "* " rows
#   Feedback.write(window, '* Connection closed', banner: true)
module Feedback
  # The row written before and after a block of lines with +banner: true+.
  BANNER = '* '

  # One color run covering all of +text+.
  #
  # @param text [String] the line
  # @param fg [String] hex foreground color
  # @return [Array<Hash>] color regions for +add_string+
  def self.colors(text, fg = FEEDBACK_COLOR)
    [{ start: 0, end: text.length, fg: fg, bg: nil, ul: nil }]
  end

  # Add lines to a window, each in one color. A window that timestamps
  # its lines stamps these too; the stamp is not colored.
  #
  # @param window [#add_string, nil] the window; nil draws nothing
  # @param lines [Array<String>] the lines, oldest first
  # @param fg [String] hex foreground color of the lines
  # @param banner [Boolean] also write a {BANNER} row, in the feedback
  #   color, before and after the lines
  # @return [Boolean] false when +window+ is nil, true otherwise
  def self.write(window, *lines, fg: FEEDBACK_COLOR, banner: false)
    return false unless window

    window.add_string(BANNER, colors(BANNER)) if banner
    lines.each { |line| window.add_string(line, colors(line, fg)) }
    window.add_string(BANNER, colors(BANNER)) if banner
    true
  end
end
