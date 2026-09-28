# frozen_string_literal: true

# A command typed with a leading dot, such as +.tab 2+, that Profanity
# handles itself instead of sending it to the game.
# {Application::DOT_COMMANDS} lists every one, and
# {Application#execute_command} dispatches through that list, and +.help+
# prints each command's help lines in that order.
#
# A command matches case-insensitively, only at the start of the input and
# only as a whole word: its name followed by whitespace or the end of the
# input, so the Lich script +.tabulate+ is not +.tab+. Input that spans
# lines (from a macro containing a newline) is one command, so a dot-command
# on a later line is not run. What may follow the name depends on +args+:
#
# - +:none+: the handler gets no argument, and any text after the name is
#   ignored.
# - +:optional+: the handler gets the rest of the input with surrounding
#   whitespace stripped, or nil when nothing follows the name.
# - +:required+: the handler gets the rest of the input after the
#   whitespace, as typed. Without it the command does not match, so the
#   input goes to the game like any other unknown dot-command.
#
# @!attribute [r] name
#   @return [String] the command's name, without the dot (e.g. +"tab"+)
# @!attribute [r] args
#   @return [Symbol] the argument shape: +:none+, +:optional+ or +:required+
# @!attribute [r] help
#   @return [Array<String>] the lines +.help+ shows for the command, one
#     per usage (e.g. +.tab+ and +.tab <N|name>+)
# @!attribute [r] handler
#   @return [Proc] the code to run, with the argument if the shape takes
#     one; {Application#execute_command} runs it with +instance_exec+, so
#     it sees the Application's instance variables and methods
DotCommand = Data.define(:name, :args, :help, :handler) do
  # @param name [String] the command's name, without the dot
  # @param args [Symbol] +:none+, +:optional+ or +:required+
  # @param help [Array<String>] the lines +.help+ shows for the command
  # @param handler [Proc] the code to run
  # @raise [ArgumentError] for an unknown argument shape
  def initialize(name:, help:, handler:, args: :none)
    raise ArgumentError, "unknown argument shape #{args.inspect} for .#{name}" unless %i[none optional required].include?(args)

    super
  end

  # Match typed input against this command.
  #
  # @param cmd [String] the command line as typed
  # @return [Array, nil] the arguments to pass to the handler (empty for
  #   +:none+, one element otherwise), or nil if the input is not this
  #   command
  def match(cmd)
    name = Regexp.escape(self.name)
    case args
    when :none
      [] if cmd.match?(/\A\.#{name}(?=\s|\z)/i)
    when :optional
      (m = cmd.match(/\A\.#{name}(?=\s|\z)(?:\s+(?<arg>.+))?/i)) && [m[:arg]&.strip]
    when :required
      (m = cmd.match(/\A\.#{name}\s+(?<arg>.+)/i)) && [m[:arg]]
    end
  end
end
