class Mouse
  # Configuration states
  CONFIGURING_UP = :up
  CONFIGURING_DOWN = :down
  NOT_CONFIGURING = :not_configuring
  MIN_EVENT_COUNT = 20

  def initialize(write_to_client, key_action)
    @write_to_client = write_to_client
    @key_action = key_action
    @config_state = NOT_CONFIGURING
    @listener_enabled = false
    @button4_mask = nil
    @button5_mask = nil

    load_settings
    # Initialize mouse to avoid warning
    getmouse
  end

  def config
    if configuring?
      reset_configuration
      return
    end

    start_configuration
  end

  def configure(bstate)
    case @config_state
    when CONFIGURING_UP
      handle_up_configuration(bstate)
    when CONFIGURING_DOWN
      handle_down_configuration(bstate)
    end
  end

  def process_mouse(ch)
    return unless ch == Curses::KEY_MOUSE

    process_mouse_event
  rescue => e
    Profanity.log("Mouse event error: #{e.message}")
  end

  def configuring?
    @config_state != NOT_CONFIGURING
  end

  private

  def load_settings
    return unless File.exist?(Settings.file("settings.json"))

    settings = JSON.parse(Settings.read(Settings.file("settings.json")))
    @button4_mask = settings["BUTTON4_PRESSED_MASK"]
    @button5_mask = settings["BUTTON5_PRESSED_MASK"]

    return unless @button4_mask && @button5_mask

    @listener_enabled = true
    Curses.mousemask(@button4_mask | @button5_mask)
  end

  def reset_configuration
    @config_state = NOT_CONFIGURING
    @bstate_counts = {}
  end

  def start_configuration
    @bstate_counts = {}
    @config_state = CONFIGURING_UP
    Curses.mousemask(Curses::ALL_MOUSE_EVENTS | Curses::REPORT_MOUSE_POSITION)
    @write_to_client.call("[PROFANITY] Scroll up with your mouse wheel or trackpad")
  end

  def handle_up_configuration(bstate)
    @bstate_counts[bstate] = (@bstate_counts[bstate] || 0) + 1
    return unless @bstate_counts[bstate] >= MIN_EVENT_COUNT

    @button4_mask = bstate
    @config_state = CONFIGURING_DOWN
    @bstate_counts = {}
    @write_to_client.call("[PROFANITY] Scroll down with your mouse wheel or trackpad")
  end

  def handle_down_configuration(bstate)
    return if bstate == @button4_mask # Ignore up events while still scrolling up

    @bstate_counts[bstate] = (@bstate_counts[bstate] || 0) + 1
    return unless @bstate_counts[bstate] >= MIN_EVENT_COUNT

    complete_configuration(bstate)
  end

  def complete_configuration(bstate)
    @button5_mask = bstate
    @config_state = NOT_CONFIGURING
    @bstate_counts = {}
    @listener_enabled = true
    Curses.mousemask(@button4_mask | @button5_mask)
    @write_to_client.call("[PROFANITY] Scroll wheel configuration complete!")
    save_settings
  end

  def save_settings
    Settings.write(Settings.file("settings.json"), JSON.pretty_generate({
      "BUTTON4_PRESSED_MASK" => @button4_mask,
      "BUTTON5_PRESSED_MASK" => @button5_mask
    }))
  end

  def process_mouse_event
    m = getmouse
    return unless m

    bstate = m.respond_to?(:bstate) ? m.bstate : nil
    return if bstate.nil?

    if configuring?
      configure(bstate)
    else
      handle_mouse_action(bstate)
    end
  end

  def handle_mouse_action(bstate)
    return if @button4_mask.nil? || @button5_mask.nil?

    unless @listener_enabled
      Curses.mousemask(@button4_mask | @button5_mask)
      @listener_enabled = true
    end

    if (bstate & @button4_mask).nonzero?
      @key_action['scroll_current_window_up_one'].call
    elsif (bstate & @button5_mask).nonzero?
      @key_action['scroll_current_window_down_one'].call
    end
  end
end
