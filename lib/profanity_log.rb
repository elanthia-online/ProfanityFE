# frozen_string_literal: true

=begin
Shared logging utility for ProfanityFE.
Provides a single method to append log messages to the log file,
with graceful fallback to $stderr if the file is not writable.
=end

# Centralized logging for ProfanityFE.
#
# Replaces the duplicated File.open/rescue pattern found throughout
# the codebase with a single utility method.
#
# The log file path is set once with {configure} (profanity.rb does so
# right after it resolves --log-file, --log-dir and --char). Until then
# {write} prints to $stderr, as it does when the file can't be written,
# until profanity.rb turns that off ({stderr_fallback}) as curses takes
# over the terminal.
#
# @example
#   ProfanityLog.configure(path: '/home/user/.profanity/mahtra.log')
#   ProfanityLog.write('autocomplete', 'no suggestions found')
module ProfanityLog
  @stderr_fallback = true

  class << self
    # @return [String, nil] path of the log file, or nil until {configure}
    #   is called
    attr_reader :path

    # Whether {write} prints a message to $stderr when it can't write it to
    # the file. True until profanity.rb sets it to false just before curses
    # starts: from then on stderr is drawn over the client's screen, so a
    # message that can't be written is dropped instead.
    #
    # @return [Boolean]
    attr_accessor :stderr_fallback

    # Set the log file that {write} appends to.
    #
    # @param path [String] path of the log file
    # @return [String] the path
    def configure(path:)
      @path = path
    end

    # Write a message to the log file, falling back to $stderr on failure
    # or when no path has been configured, unless {stderr_fallback} is off
    # (then the message is dropped). The backtrace goes only to the file.
    #
    # @param context [String] source identifier (e.g., 'autocomplete', 'mouse')
    # @param message [String] the log message
    # @param backtrace [Array<String>, nil] optional backtrace lines to append
    # @return [void]
    def write(context, message, backtrace: nil)
      raise IOError, 'ProfanityLog.path is not configured' unless path

      File.open(path, 'a') do |f|
        f.puts "[#{context}] #{message}"
        backtrace&.first(BACKTRACE_LIMIT)&.each { |line| f.puts line }
      end
    rescue StandardError
      $stderr.puts "[#{context}] #{message}" if stderr_fallback
    end
  end
end
