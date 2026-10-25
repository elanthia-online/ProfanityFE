# frozen_string_literal: true

# Ruby (including native curses) warnings must not write into the active
# terminal: a newline there scrolls the screen behind curses' back.
module RuntimeWarnings
  # Bound the memory retained when the log cannot be written.
  PENDING_LIMIT = 65_536
  # Serialize warning writes with startup/shutdown and log-handle changes.
  LOCK = Mutex.new

  class << self
    # Destination for warnings while the curses UI is active.
    # @return [File, nil]
    attr_reader :output

    # Begin routing warnings to the client log.
    # @param path [String] log file path
    # @return [void]
    def start(path:)
      stop
      LOCK.synchronize do
        @active = true
        begin
          @output = File.open(path, 'a')
          @output.sync = true
        rescue IOError, SystemCallError
          close_output
        end
      end
    end

    # Close the log and flush buffered warnings after curses has been closed.
    # Logging failures must not mask startup/shutdown exceptions.
    # @return [void]
    def stop
      pending = LOCK.synchronize do
        @active = false
        close_output
        buffered = @pending || +''
        buffered << "[profanity] #{@dropped} additional warning(s) omitted.\n" if @dropped.to_i.positive?
        @pending = +''
        @dropped = 0
        buffered
      end
      $stderr.write(pending) unless pending.empty?
    rescue IOError, SystemCallError
      nil
    end

    # Handle a warning while the UI is active. If the log fails, retain a
    # bounded backlog for shutdown rather than writing over the curses screen.
    # @param message [String] warning text
    # @return [Boolean] whether the active warning router handled the message
    def write(message)
      LOCK.synchronize do
        return false unless @active

        if @output
          begin
            @output.write(message)
            return true
          rescue IOError, SystemCallError
            close_output
          end
        end
        if @pending.bytesize + message.bytesize <= PENDING_LIMIT
          @pending << message
        else
          @dropped += 1
        end
        true
      end
    end

    private

    # Discard a failed log handle without propagating another I/O failure.
    # Called with LOCK held.
    # @return [void]
    def close_output
      output = @output
      @output = nil
      output&.close
    rescue IOError, SystemCallError
      nil
    end
  end

  # Intercept Ruby's warning API without changing fatal exception reporting.
  module Routing
    # Write warnings to the active log, or delegate to Ruby when inactive.
    # @param message [String] warning text
    # @param options [Hash] keyword options accepted by Ruby's warning API
    # @return [void]
    def warn(message, **options)
      super unless RuntimeWarnings.write(message)
    end
  end
end

Warning.singleton_class.prepend(RuntimeWarnings::Routing)
