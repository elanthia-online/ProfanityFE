# frozen_string_literal: true

# Ruby (including native curses) warnings must not write into the active
# terminal: a newline there scrolls the screen behind curses' back.
module RuntimeWarnings
  class << self
    # Destination for warnings while the curses UI is active.
    # @return [File, nil]
    attr_reader :output

    # Begin routing warnings to the client log.
    # @param path [String] log file path
    # @return [void]
    def start(path:)
      stop
      @output = File.open(path, 'a')
      @output.sync = true
    end

    # Close the log handle and restore the normal warning destination.
    # @return [void]
    def stop
      output = @output
      @output = nil
      output&.close
    end
  end

  # Intercept Ruby's warning API without changing fatal exception reporting.
  module Routing
    # Write warnings to the active log, or delegate to Ruby when inactive.
    # @param message [String] warning text
    # @param options [Hash] keyword options accepted by Ruby's warning API
    # @return [void]
    def warn(message, **options)
      if (output = RuntimeWarnings.output)
        output.write(message)
        nil
      else
        super
      end
    end
  end
end

Warning.singleton_class.prepend(RuntimeWarnings::Routing)
