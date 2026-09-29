# frozen_string_literal: true

# Simple synchronous publish-subscribe event bus.
#
# Decouples the game text parser from the UI by letting the parser
# emit typed events and letting windows subscribe to the events they
# care about. Enables testing without curses and session replay/logging.
#
# All handlers run synchronously in the emitting thread. This is
# intentional — the game text processor and curses rendering share a
# single CursesRenderer.synchronize block, so async delivery would
# require additional locking.
#
# @example
#   bus = EventBus.new
#   bus.on(:stream_text) { |data| puts data[:text] }
#   bus.emit(:stream_text, stream: 'main', text: 'Hello', colors: [])
class EventBus
  # A bus with no subscribers.
  def initialize
    @subscribers = Hash.new { |h, k| h[k] = [] }
  end

  # Subscribe a handler to an event type.
  #
  # @param event_type [Symbol] the event to listen for
  # @yield [data] called with the event data each time the event fires
  # @yieldparam data [Hash{Symbol => Object}] the keyword arguments given
  #   to {#emit}
  # @return [self] for chaining
  def on(event_type, &handler)
    @subscribers[event_type] << handler
    self
  end

  # Emit an event to all handlers registered when the emit starts.
  #
  # Handlers added or removed by a handler take effect from the next emit;
  # iterating a snapshot keeps them from running (or being skipped) in the
  # current one.
  #
  # @param event_type [Symbol] the event type
  # @param data [Hash] keyword arguments passed to each handler
  # @return [void]
  # @raise [StandardError] whatever a handler raises; later handlers are skipped
  def emit(event_type, **data)
    @subscribers[event_type].dup.each { |h| h.call(data) }
  end

  # Remove a specific handler or all handlers for an event type.
  #
  # @param event_type [Symbol] the event type
  # @param handler [Proc, nil] specific handler to remove, or nil to remove all
  # @return [void]
  def off(event_type, handler = nil)
    if handler
      @subscribers[event_type].delete(handler)
    else
      @subscribers.delete(event_type)
    end
  end

  # Remove all subscribers for all event types.
  #
  # @return [void]
  def clear
    @subscribers.clear
  end

  # Count subscribers for a specific event type or all types.
  #
  # @param event_type [Symbol, nil] event type, or nil for total count
  # @return [Integer]
  def subscriber_count(event_type = nil)
    if event_type
      @subscribers.key?(event_type) ? @subscribers[event_type].size : 0
    else
      @subscribers.values.sum(&:size)
    end
  end
end
