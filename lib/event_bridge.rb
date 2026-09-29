# frozen_string_literal: true

require_relative 'streams'
require_relative 'feedback'
require_relative 'url_launcher'

# Connects the parser's {EventBus} to the windows of a {WindowManager}.
#
# Each handler looks up its window in the manager's handler hashes when
# the event fires, so it follows layout reloads, and does nothing when
# the layout has no such window. Text goes to stream windows, prompts
# through {WindowManager#add_prompt}, indicator, progress and countdown
# updates to their windows, room parts to the room window, and a new
# prompt to {WindowManager#fit_prompt_to}. A LaunchURL is shown in the
# main window (+--remote-url+) or opened with {UrlLauncher.open}.
#
# @example
#   EventBridge.new(window_manager).subscribe(event_bus)
class EventBridge
  # @param window_manager [WindowManager] whose windows the events update
  # @return [EventBridge]
  def initialize(window_manager)
    @wm = window_manager
  end

  # Subscribe a handler for each event the windows display.
  #
  # @param event_bus [EventBus] the event bus to subscribe to
  # @return [void]
  def subscribe(event_bus)
    # ---- Text display events ----

    event_bus.on(:stream_text) do |data|
      window = @wm.stream[data[:stream]]
      next unless window

      window.route_string(data[:text], data[:colors], data[:stream], indent: data[:indent])
    end

    event_bus.on(:add_prompt) do |data|
      window = @wm.stream[data[:stream] || MAIN_STREAM]
      next unless window
      args = [window, data[:text]]
      args << data[:command] if data[:command]
      @wm.add_prompt(*args)
    end

    # ---- Indicator events ----

    event_bus.on(:indicator_update) do |data|
      window = @wm.indicator[data[:id]]
      next unless window

      # One redraw after all attributes are set (label= would redraw with
      # stale label_colors).
      window.apply_changes(data.slice(:label, :label_colors, :value))
    end

    event_bus.on(:compass_update) do |data|
      dirs = data[:dirs]
      %w[up down out n ne e se s sw w nw].each do |dir|
        window = @wm.indicator["compass:#{dir}"]
        window&.update(dirs.include?(dir))
      end
    end

    # ---- Progress bar events ----

    event_bus.on(:progress_update) do |data|
      window = @wm.progress[data[:id]]
      next unless window

      window.label = data[:label] if data.key?(:label)
      window.fg = data[:fg] if data.key?(:fg)
      window.bg = data[:bg] if data.key?(:bg)
      window.update(data[:value], data[:max])
    end

    # ---- Countdown events ----

    event_bus.on(:countdown_update) do |data|
      window = @wm.countdown[data[:id]]
      next unless window

      window.end_time = data[:end_time] if data.key?(:end_time)
      window.secondary_end_time = data[:secondary_end_time] if data.key?(:secondary_end_time)
      window.tick
    end

    event_bus.on(:countdown_active) do |data|
      window = @wm.countdown[data[:id]]
      next unless window

      window.active = data[:active]
      window.tick
    end

    event_bus.on(:stun) do |data|
      window = @wm.countdown['stunned']
      next unless window

      window.end_time = @wm.clock.server_now + data[:seconds].to_f
      window.tick
    end

    # ---- Prompt resize ----

    event_bus.on(:prompt_changed) do |data|
      @wm.fit_prompt_to(data[:text])
    end

    # ---- Room events ----

    event_bus.on(:room_title) do |data|
      @wm.room[Streams::ROOM]&.update_title(data[:text])
    end

    event_bus.on(:room_desc) do |data|
      @wm.room[Streams::ROOM]&.update_desc(data[:text], links: data[:links] || [])
    end

    event_bus.on(:room_objects) do |data|
      @wm.room[Streams::ROOM]&.update_objects(data[:text], links: data[:links] || [], creatures: data[:creatures] || [])
    end

    event_bus.on(:room_players) do |data|
      @wm.room[Streams::ROOM]&.update_players(data[:text], links: data[:links] || [])
    end

    event_bus.on(:room_exits) do |data|
      @wm.room[Streams::ROOM]&.update_exits(data[:text], links: data[:links] || [])
    end

    event_bus.on(:room_lich_exits) do |data|
      @wm.room[Streams::ROOM]&.update_lich_exits(data[:text])
    end

    event_bus.on(:room_number) do |data|
      @wm.room[Streams::ROOM]&.update_room_number(data[:text])
    end

    event_bus.on(:room_stringprocs) do |data|
      @wm.room[Streams::ROOM]&.update_stringprocs(data[:text])
    end

    event_bus.on(:room_supplemental_clear) do |_data|
      @wm.room[Streams::ROOM]&.clear_supplemental
    end

    event_bus.on(:room_render) do |_data|
      @wm.room[Streams::ROOM]&.render
    end

    # ---- Stream management events ----

    # Whatever window lists the stream: an exp or spell window keeps
    # entries, a text or tabbed window just shows the lines.

    event_bus.on(:exp_set_current) do |data|
      @wm.stream[Streams::EXP]&.component_opened(data[:skill])
    end

    event_bus.on(:exp_delete_skill) do |_data|
      @wm.stream[Streams::EXP]&.component_closed
    end

    event_bus.on(:clear_spells) do |_data|
      @wm.stream[Streams::PERC]&.stream_cleared
    end

    # ---- Special events ----

    event_bus.on(:launch_url) do |data|
      window = @wm.stream[MAIN_STREAM]
      next unless window

      if data[:remote]
        # --remote-url: display URL on screen for copy/paste (SSH/remote sessions)
        window.add_string(' *'.dup)
        window.add_string(" * LaunchURL: #{data[:url]}")
        window.add_string(' *'.dup)
      else
        # Default: open URL in system browser
        UrlLauncher.open(data[:url])
      end
    end

    event_bus.on(:disconnect) do |_data|
      Feedback.write(@wm.stream[MAIN_STREAM], '* Connection closed', '* Press any key to exit...', banner: true)
    end
  end
end
