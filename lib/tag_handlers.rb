# frozen_string_literal: true

require_relative 'xml_tokenizer'
require_relative 'link_extractor'

# Tag dispatch and handler methods for game server XML processing.
#
# Replaces the 30+ elsif regex chain in GameTextProcessor#run with
# a hash-based dispatch table and focused handler methods. Each XML
# tag type has its own method, making the processing logic easier to
# understand, test, and modify independently.
#
# Expects the including class to provide:
# - @wm, @state, @cmd_buffer, @xml_escapes, @event_bus
# - @line_colors, @open_monsterbold, @open_preset, @open_style,
#   @open_color, @open_link
# - @current_stream, @combat_next_line, @need_update, @need_room_render
# - @room_capture_mode
# - handle_game_text, new_stun, fix_layout_number, parse_room_subtitle,
#   add_prompt
module TagHandlers
  # Dispatch table for opening and self-closing tags.
  TAG_DISPATCH = {
    'prompt'       => :handle_prompt_tag,
    'spell'        => :handle_spell_tag,
    'right'        => :handle_hand_tag,
    'left'         => :handle_hand_tag,
    'roundTime'    => :handle_roundtime_tag,
    'castTime'     => :handle_casttime_tag,
    'compass'      => :handle_compass_tag,
    'progressBar'  => :handle_progress_bar_tag,
    'arbProgress'  => :handle_arb_progress_tag,
    'pushBold'     => :handle_push_bold,
    'b'            => :handle_push_bold,
    'popBold'      => :handle_pop_bold,
    'preset'       => :handle_open_preset,
    'color'        => :handle_open_color,
    'style'        => :handle_style_tag,
    'pushStream'   => :handle_stream_open,
    'component'    => :handle_stream_open,
    'compDef'      => :handle_stream_open,
    'popStream'    => :handle_stream_close,
    'clearStream'  => :handle_clear_stream,
    'indicator'    => :handle_indicator_tag,
    'image'        => :handle_image_tag,
    'LaunchURL'    => :handle_launch_url,
    'a'            => :handle_open_link,
    'd'            => :handle_open_link,
    'streamWindow' => :handle_stream_window,
    'dialogdata'   => :handle_ignored_tag,
    'label'        => :handle_ignored_tag,
    'skin'         => :handle_ignored_tag,
    'output'       => :handle_ignored_tag,
  }.freeze

  # Dispatch table for closing tags (</tagname>).
  CLOSING_TAG_DISPATCH = {
    'preset'    => :handle_close_preset,
    'color'     => :handle_close_color,
    'b'         => :handle_pop_bold,
    'a'         => :handle_close_link,
    'd'         => :handle_close_link,
    'component' => :handle_stream_close,
    'compDef'   => :handle_stream_close,
  }.freeze

  # Dispatch an XML tag to its handler method.
  #
  # @param xml [String] full XML tag string
  # @param text_buffer [String] mutable text accumulator (positions
  #   are tracked via text_buffer.length)
  # @return [void]
  def dispatch_tag(xml, text_buffer)
    # Combat tracking: reset flag on any <popStream id="combat"...> tag.
    # This runs for every tag, before dispatch (matching original behavior).
    @combat_next_line = false if xml.match?(%r{<popStream[^>]*id=["']combat["']})

    name = XmlTokenizer.tag_name(xml)
    closing = xml.start_with?('</')

    table = closing ? CLOSING_TAG_DISPATCH : TAG_DISPATCH
    handler = table[name]

    if handler
      send(handler, xml, text_buffer)
    elsif @combat_next_line
      # Unrecognized tag while combat-next-line is active:
      # flush accumulated text and switch to combat stream.
      flush_text_buffer(text_buffer)
      @current_stream = 'combat'
    end
  end

  private

  # Flush accumulated text through handle_game_text and clear the buffer.
  #
  # @param buf [String] mutable text buffer to flush and clear
  # @return [void]
  def flush_text_buffer(buf)
    handle_game_text(buf.dup) unless buf.empty?
    buf.clear
  end

  # Unescape XML entities in a text segment.
  #
  # @param text [String] text with XML entities (&lt;, &gt;, etc.)
  # @return [String] unescaped text
  def unescape_entities(text)
    result = text.dup
    @xml_escapes.each do |entity, replacement|
      result.gsub!(entity, replacement)
    end
    result
  end

  # ---- Tag handlers ----
  #
  # Each handler receives the full XML tag string and the mutable text
  # buffer. Color region positions use text_buffer.length, which is
  # always correct because the buffer only contains non-tag text.
  # Handlers that need to emit accumulated text before changing state
  # call flush_text_buffer.
  #
  # UI updates are emitted via @event_bus rather than calling window
  # methods directly. This decouples parsing from rendering and enables
  # testing without curses.

  # Explicitly ignored game protocol tags (dialog data, labels, etc.).
  def handle_ignored_tag(_xml, _text_buffer); end

  # Handle <prompt time='...'>text&gt;</prompt> paired tag.
  # Syncs server time offset and updates the prompt display.
  def handle_prompt_tag(xml, _text_buffer)
    return unless (m = xml.match(%r{^<prompt time=(?<q>'|")(?<time>[0-9]+)\k<q>.*?>(?<text>.*?)&gt;</prompt>$}))

    unless @state.skip_server_time_offset
      @state.server_time_offset = Time.now.to_f - m[:time].to_f
      @state.skip_server_time_offset = true
    end

    if @first_prompt
      @first_prompt = false
      @server.puts 'look'
      @server.flush
      if BOOT_PROFILE
        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - BOOT_T0) * 1000).round(1)
        ProfanityLog.write('boot-profile', "first prompt (sent look): #{elapsed}ms")
      end
    end

    new_prompt_text = "#{m[:text]}>"
    if @state.prompt_text != new_prompt_text
      @state.need_prompt = false
      @state.prompt_text = new_prompt_text
      @event_bus.emit(:add_prompt, stream: MAIN_STREAM, text: new_prompt_text)
      @event_bus.emit(:prompt_changed, text: new_prompt_text)
      @need_update = true
    else
      @state.need_prompt = true
    end
  end

  # Handle <spell>name</spell> paired tag.
  def handle_spell_tag(xml, _text_buffer)
    return unless (m = xml.match(%r{^<spell(?:>|\s.*?>)(?<spell>.*?)</spell>$}))

    @event_bus.emit(:indicator_update, id: 'spell', label: m[:spell],
                                       value: m[:spell] == 'None' ? 0 : 1)
    @need_update = true
  end

  # Handle <right>item</right> or <left>item</left> paired tag.
  def handle_hand_tag(xml, _text_buffer)
    return unless (m = xml.match(%r{^<(?<hand>right|left)(?:>|\s.*?>)(?<item>.*?\S*?)</\k<hand>>}))

    @event_bus.emit(:indicator_update, id: m[:hand], label: m[:item],
                                       value: m[:item] == 'Empty' ? 0 : 1)
    @need_update = true
  end

  # Handle <roundTime value='N'/> tag. Sets the countdown end time.
  # The countdown display is polled by Application#tick_countdowns
  # on every input loop iteration (~100ms).
  def handle_roundtime_tag(xml, _text_buffer)
    return unless (m = xml.match(/^<roundTime value=(?<q>'|")(?<value>[0-9]+)\k<q>/))

    @event_bus.emit(:countdown_update, id: 'roundtime', end_time: m[:value].to_i)
    @need_update = true
  end

  # Handle <castTime value='N'/> tag. Sets the secondary countdown end time.
  # The countdown display is polled by Application#tick_countdowns
  # on every input loop iteration (~100ms).
  def handle_casttime_tag(xml, _text_buffer)
    return unless (m = xml.match(/^<castTime value=(?<q>'|")(?<value>[0-9]+)\k<q>/))

    @event_bus.emit(:countdown_update, id: 'roundtime', secondary_end_time: m[:value].to_i)
    @need_update = true
  end

  # Handle <compass>...<dir value="n"/>...</compass> paired tag.
  def handle_compass_tag(xml, _text_buffer)
    current_dirs = xml.scan(/<dir value="(.*?)"/).flatten
    @event_bus.emit(:compass_update, dirs: current_dirs)
    @need_update = true
  end

  # Handle <progressBar .../> tags for vitals, stance, encumbrance, mind.
  # Dispatches to game-specific sub-patterns based on id and text format.
  def handle_progress_bar_tag(xml, _text_buffer)
    if (m = xml.match(/^<progressBar id='encumlevel' value='(?<value>[0-9]+)' text='(?<text>.*?)'/))
      value = m[:text] == 'Overloaded' ? 110 : m[:value].to_i
      @event_bus.emit(:progress_update, id: 'encumbrance', value: value, max: 110)
      @need_update = true
    elsif (m = xml.match(/^<progressBar id='pbarStance' value='(?<value>[0-9]+)'/))
      @event_bus.emit(:progress_update, id: 'stance', value: m[:value].to_i, max: 100)
      @need_update = true
    elsif (m = xml.match(/^<progressBar id='mindState' value='(?<value>.*?)' text='(?<text>.*?)'/))
      value = m[:text] == 'saturated' ? 110 : m[:value].to_i
      @event_bus.emit(:progress_update, id: 'mind', value: value, max: 110)
      @need_update = true
    elsif (m = xml.match(/^<progressBar id='(?<id>.*?)' value='[0-9]+' text='.*?\s+(?<cur>-?[0-9]+)\/(?<max>[0-9]+)'/))
      # GemStone vitals: text contains current/max (e.g., "health 456/456")
      @event_bus.emit(:progress_update, id: m[:id], value: m[:cur].to_i, max: m[:max].to_i)
      @need_update = true
    elsif (m = xml.match(/^<progressBar id='(?<id>health|mana|spirit|stamina|concentration)' value='(?<value>[0-9]+)' text='(?:health|mana|spirit|fatigue|concentration|inner fire) [0-9]+\%'/))
      # DragonRealms vitals: text contains percentage (e.g., "health 75%")
      @event_bus.emit(:progress_update, id: m[:id], value: m[:value].to_i, max: 100)
      @need_update = true
    end
  end

  # Handle <arbProgress id='...' max='...' current='...'/> user-defined progress bars.
  def handle_arb_progress_tag(xml, _text_buffer)
    return unless (m = xml.match(/^<arbProgress id='(?<id>[a-zA-Z0-9]+)' max='(?<max>\d+)' current='(?<cur>\d+)'(?:\s+label='(?<label>.+?)')?(?:\s+colors='(?<colors>\S+?)')?/))

    current = [m[:cur].to_i, m[:max].to_i].min
    data = { id: m[:id], value: current, max: m[:max].to_i }
    data[:label] = m[:label] if m[:label]
    if m[:colors]
      bg, fg = m[:colors].split(',')
      data[:bg] = [bg] if bg
      data[:fg] = [fg] if fg
    end
    @event_bus.emit(:progress_update, **data)
    @need_update = true
  end

  # Handle <pushBold/> or <b> tag. Opens a monster bold color region.
  def handle_push_bold(_xml, text_buffer)
    h = { start: text_buffer.length }
    if PRESET['monsterbold']
      h[:fg] = PRESET['monsterbold'][0]
      h[:bg] = PRESET['monsterbold'][1]
    end
    @open_monsterbold.push(h)
  end

  # Handle <popBold/> or </b> tag. Closes the most recent monster bold region.
  def handle_pop_bold(_xml, text_buffer)
    if (h = @open_monsterbold.pop)
      h[:end] = text_buffer.length
      @line_colors.push(h) if h[:fg] || h[:bg]
    end
  end

  # Handle <preset id='...'> opening tag.
  def handle_open_preset(xml, text_buffer)
    return unless (m = xml.match(/^<preset id=(?<q>'|")(?<id>.*?)\k<q>>$/))

    preset_id = m[:id]
    if preset_id == 'roomDesc' && @wm.room['room']
      flush_text_buffer(text_buffer)
      @room_capture_mode = :desc
    end
    h = { start: text_buffer.length }
    if PRESET[preset_id]
      h[:fg] = PRESET[preset_id][0]
      h[:bg] = PRESET[preset_id][1]
    end
    @open_preset.push(h)
  end

  # Handle </preset> closing tag.
  def handle_close_preset(_xml, text_buffer)
    if @room_capture_mode == :desc
      flush_text_buffer(text_buffer)
    end
    if (h = @open_preset.pop)
      h[:end] = text_buffer.length
      @line_colors.push(h) if h[:fg] || h[:bg]
    end
  end

  # Handle <color fg='...' bg='...' ul='...'> opening tag.
  def handle_open_color(xml, text_buffer)
    h = { start: text_buffer.length }
    if (fg_match = xml.match(/\sfg=(?<q>'|")(?<val>.*?)\k<q>[\s>]/))
      h[:fg] = fg_match[:val].downcase
    end
    if (bg_match = xml.match(/\sbg=(?<q>'|")(?<val>.*?)\k<q>[\s>]/))
      h[:bg] = bg_match[:val].downcase
    end
    if (ul_match = xml.match(/\sul=(?<q>'|")(?<val>.*?)\k<q>[\s>]/))
      h[:ul] = ul_match[:val].downcase
    end
    @open_color.push(h)
  end

  # Handle </color> closing tag.
  def handle_close_color(_xml, text_buffer)
    if (h = @open_color.pop)
      h[:end] = text_buffer.length
      @line_colors.push(h)
    end
  end

  # Handle <style id='...'> tag (both opening and "closing" via empty id).
  # The game protocol uses <style id=""> as a close marker rather than </style>.
  def handle_style_tag(xml, text_buffer)
    return unless (m = xml.match(/^<style id=(?<q>'|")(?<id>.*?)\k<q>/))

    style_id = m[:id]
    if style_id.empty?
      # Empty id = closing style
      if @room_capture_mode == :title || @room_capture_mode == :desc
        flush_text_buffer(text_buffer)
      end
      if @open_style
        @open_style[:end] = text_buffer.length
        if (@open_style[:start] < @open_style[:end]) && (@open_style[:fg] || @open_style[:bg])
          @line_colors.push(@open_style)
        end
        @open_style = nil
      end
    else
      # Non-empty id = opening style
      @open_style = { start: text_buffer.length }
      if PRESET[style_id]
        @open_style[:fg] = PRESET[style_id][0]
        @open_style[:bg] = PRESET[style_id][1]
      end
      @room_capture_mode = :title if style_id == 'roomName'
      @room_capture_mode = :desc if style_id == 'roomDesc' && @wm.room['room']
    end
  end

  # Handle <pushStream>, <component>, or <compDef> stream-opening tag.
  # Flushes accumulated text and switches the current stream.
  def handle_stream_open(xml, text_buffer)
    return unless (m = xml.match(%r{id=(?<q>"|')(?<id>.*?)\k<q>}))

    flush_text_buffer(text_buffer)
    new_stream = m[:id]
    if (exp_match = new_stream.match(/^exp (?<skill>\w+\s?\w+?)/))
      @current_stream = 'exp'
      @event_bus.emit(:exp_set_current, skill: exp_match[:skill])
    else
      @current_stream = new_stream
      if new_stream == 'room' && (sub_match = xml.match(/subtitle=(?<q>"|')(?<sub>.*?)\k<q>/))
        title = parse_room_subtitle(sub_match[:sub])
        unless title.empty?
          @state.room_title = title
          @event_bus.emit(:room_title, text: title)
        end
      end
    end

    @combat_next_line = true if @current_stream == 'combat'
  end

  # Handle <popStream.../>, </component>, or </compDef> stream-closing tag.
  # Flushes accumulated text and clears the current stream.
  def handle_stream_close(_xml, text_buffer)
    if text_buffer.empty? && @current_stream&.start_with?('room')
      # Empty room components (e.g., <component id='room players'></component>)
      # are meaningful — they clear the displayed data. Since flush_text_buffer
      # skips empty text, handle this directly.
      if @wm.room['room']
        result = process_room_stream('')
        update_room_players_indicator(nil) if result == :continue
      elsif @current_stream == 'room players'
        # No RoomWindow -- still clear the indicator
        update_room_players_indicator(nil)
      end
    else
      flush_text_buffer(text_buffer)
    end
    @event_bus.emit(:exp_delete_skill) if @current_stream == 'exp'
    @current_stream = nil
  end

  # Handle <clearStream id="percWindow"/> tag.
  def handle_clear_stream(xml, _text_buffer)
    @event_bus.emit(:clear_spells) if xml.match?(/id=["']percWindow["']/)
  end

  # Handle <a ...> or <d ...> link opening tag.
  def handle_open_link(xml, text_buffer)
    # Always track links for room component streams — the RoomWindow needs
    # pre-computed link positions even when .links is off, so they're ready
    # when toggled on. Room stream text is consumed (never reaches main
    # window), so these extra color regions don't affect other windows.
    return unless @state.blue_links || @current_stream&.start_with?('room')

    preset = PRESET['links'] || LinkExtractor::DEFAULT_LINK_COLOR
    link = { start: text_buffer.length, fg: preset[0], bg: preset[1], priority: 2 }
    link[:cmd] = LinkExtractor.extract_cmd(xml)
    @open_link.push(link)
  end

  # Handle </a> or </d> link closing tag.
  def handle_close_link(_xml, text_buffer)
    if (h = @open_link.pop)
      h[:end] = text_buffer.length
      # For tags without cmd/exist (e.g., exit directions),
      # use the link text itself as the command
      h[:cmd] ||= text_buffer[h[:start]...h[:end]] if h[:start] && h[:end] > h[:start]
      @line_colors.push(h) if h[:fg] || h[:bg]
    end
  end

  # Handle <indicator id='IconXXX' visible='y|n'/> tag.
  def handle_indicator_tag(xml, _text_buffer)
    return unless (m = xml.match(/^<indicator id=(?<q1>'|")Icon(?<icon>[A-Z]+)\k<q1> visible=(?<q2>'|")(?<vis>[yn])\k<q2>/))

    icon = m[:icon].downcase
    active = m[:vis] == 'y'
    @event_bus.emit(:countdown_active, id: icon, active: active)
    @event_bus.emit(:indicator_update, id: icon, value: active)
    @need_update = true
  end

  # Handle <image id='...' name='...'/> body part/injury tag.
  def handle_image_tag(xml, _text_buffer)
    return unless (m = xml.match(/^<image id=(?<q1>'|")(?<id>back|leftHand|rightHand|head|rightArm|abdomen|leftEye|leftArm|chest|rightLeg|neck|leftLeg|nsys|rightEye)\k<q1> name=(?<q2>'|")(?<name>.*?)\k<q2>/))

    if m[:id] == 'nsys'
      rank = m[:name].slice(/[0-9]/)
      @event_bus.emit(:indicator_update, id: 'nsys', value: rank ? rank.to_i : 0)
    else
      fix_value = { 'Injury1' => 1, 'Injury2' => 2, 'Injury3' => 3, 'Scar1' => 4, 'Scar2' => 5, 'Scar3' => 6 }
      @event_bus.emit(:indicator_update, id: m[:id], value: fix_value[m[:name]] || 0)
    end
    @need_update = true
  end

  # Handle <LaunchURL src="..."/> tag.
  def handle_launch_url(xml, _text_buffer)
    return unless (m = xml.match(/^<LaunchURL src="(?<src>[^"]+)"/))

    url = "https://www.play.net#{m[:src]}"
    @event_bus.emit(:launch_url, url: url, remote: @state.remote_url)
    @need_update = true
  end

  # Handle <streamWindow id='room' subtitle='...'/> tag.
  def handle_stream_window(xml, _text_buffer)
    return unless (m = xml.match(/^<streamWindow id='room'.*?subtitle=(?<q>"|')(?<sub>.*?)\k<q>/))

    room = parse_room_subtitle(m[:sub])
    return if room.empty?

    @state.room_title = room
    @event_bus.emit(:indicator_update, id: 'room', label: room, value: 1)
    @event_bus.emit(:room_title, text: room)
    @need_update = true
    @need_room_render = true
  end
end
