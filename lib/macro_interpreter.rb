# frozen_string_literal: true

# Runs a key macro from the settings file
# (`<key id='ctrl+l' macro='look\r'/>`) on the command line.
#
# Each character of the macro is typed into the {CommandBuffer}, except
# for these escapes:
#
# - `\\` types a literal backslash, `\@` a literal `@`;
# - `\x` clears the command line;
# - `\r` sends the command line (through the +send_command+ callback);
# - `\?` moves the screen cursor back when the macro ends (to the column
#   three less than the position of the `?` in the macro);
# - a bare `@` marks where the cursor ends up (the last one wins; a `\r`
#   after it forgets it).
#
# Any other escaped character is dropped, as is a trailing backslash.
#
# @example
#   macro = MacroInterpreter.new(cmd_buffer: cmd_buffer, send_command: -> { ... })
#   macro.call('say @ to you\r')
class MacroInterpreter
  # @param cmd_buffer [CommandBuffer] the command line the macro types into
  # @param send_command [#call] sends the command line; called with no
  #   arguments for each `\r`
  def initialize(cmd_buffer:, send_command:)
    @cmd_buffer = cmd_buffer
    @send_command = send_command
  end

  # Run the macro, then redraw the command line and flush the screen.
  #
  # @param macro [String] the macro string to execute
  # @return [void]
  def call(macro)
    backslash = false
    at_pos = nil
    backfill = nil
    macro.split('').each_with_index do |ch, i|
      if backslash
        case ch
        when '\\'
          @cmd_buffer.put_ch('\\')
        when 'x'
          @cmd_buffer.clear_and_get
        when 'r'
          at_pos = nil
          @send_command.call
        when '@'
          @cmd_buffer.put_ch('@')
        when '?'
          backfill = i - 3
        end
        backslash = false
      elsif ch == '\\'
        backslash = true
      elsif ch == '@'
        at_pos = @cmd_buffer.pos
      else
        @cmd_buffer.put_ch(ch)
      end
    end
    if at_pos
      @cmd_buffer.cursor_left while at_pos < @cmd_buffer.pos
      @cmd_buffer.cursor_right while at_pos > @cmd_buffer.pos
    end
    if backfill
      @cmd_buffer.window.setpos(0, backfill)
      backfill = nil
    end
    @cmd_buffer.flush_screen
  end
end
