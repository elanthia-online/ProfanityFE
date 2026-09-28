# frozen_string_literal: true

require 'uri'
require_relative 'xml_tokenizer'
require_relative 'link_extractor'
require_relative 'streams'

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
# - @stream_stack (an empty Array: the open pushStreams, innermost last)
# - @room_capture_mode
# - handle_game_text, new_stun, parse_room_subtitle, add_prompt
module TagHandlers
  # Base URL that every <LaunchURL src="..."/> path is appended to.
  LAUNCH_URL_BASE = 'https://www.play.net'

  # progressBar ids of the DragonRealms vitals, whose text is a percentage.
  DR_VITALS = %w[health mana spirit stamina concentration].freeze

  # Body parts (and +nsys+) an <image> tag can report on.
  IMAGE_IDS = %w[back leftHand rightHand head rightArm abdomen leftEye leftArm chest rightLeg neck leftLeg nsys rightEye].freeze

  # Most pushStreams tracked as open at once. The deepest real nesting is
  # two (the empath familiar double push); the cap only stops unmatched
  # pushes from piling up between prompts.
  MAX_STREAM_DEPTH = 8

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
    # Combat tracking: reset flag on any <popStream> tag, bare or with an id.
    # A combat block closed by a bare <popStream/> must not leave later
    # unrecognized tags routed to combat.
    # This runs for every tag, before dispatch (matching original behavior).
    @combat_next_line = false if xml.start_with?('<popStream')
    # A prompt is the stream resync point: it closes any stream left open.
    resync_streams_at_prompt(text_buffer) if xml.match?(/\A<prompt\b/)

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
      @current_stream = Streams::COMBAT
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
  # Also forgets the last stream-window line, so a main line after the
  # prompt is not taken for the game's copy of it and dropped.
  def handle_prompt_tag(xml, _text_buffer)
    @last_stream_text = nil
    # The text starts after the first >.
    return unless (time = XmlTokenizer.attrs(xml)['time'])&.match?(/\A[0-9]+\z/)
    return unless (m = xml.match(%r{\A.*?>(?<text>.*?)&gt;</prompt>$}))

    unless @state.skip_server_time_offset
      @state.server_time_offset = Time.now.to_f - time.to_f
      @state.skip_server_time_offset = true
    end

    if @first_prompt
      @first_prompt = false
      # Sent once the render lock is released, so a full socket send
      # buffer cannot block drawing (see CursesRenderer.outside_lock).
      CursesRenderer.outside_lock do
        @server.puts 'look'
        @server.flush
      end
      if BOOT_PROFILE
        elapsed = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - BOOT_T0) * 1000).round(1)
        ProfanityLog.write('boot-profile', "first prompt (sent look): #{elapsed}ms")
      end
    end

    new_prompt_text = "#{m[:text]}>"
    if @state.update_prompt(new_prompt_text)
      @event_bus.emit(:add_prompt, stream: MAIN_STREAM, text: new_prompt_text)
      @event_bus.emit(:prompt_changed, text: new_prompt_text)
      @need_update = true
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
    return unless (value = countdown_value(xml))

    @event_bus.emit(:countdown_update, id: 'roundtime', end_time: value)
    @need_update = true
  end

  # Handle <castTime value='N'/> tag. Sets the secondary countdown end time.
  # The countdown display is polled by Application#tick_countdowns
  # on every input loop iteration (~100ms).
  def handle_casttime_tag(xml, _text_buffer)
    return unless (value = countdown_value(xml))

    @event_bus.emit(:countdown_update, id: 'roundtime', secondary_end_time: value)
    @need_update = true
  end

  # The end time a <roundTime> or <castTime> tag carries.
  #
  # @param xml [String] the tag
  # @return [Integer, nil] the value, or nil unless it is all digits
  def countdown_value(xml)
    value = XmlTokenizer.attrs(xml)['value']
    value.to_i if value&.match?(/\A[0-9]+\z/)
  end

  # Handle <compass>...<dir value="n"/>...</compass> paired tag.
  def handle_compass_tag(xml, _text_buffer)
    # attrs reads only the start tag it is given, so each <dir> is read from
    # where it starts.
    current_dirs = xml.to_enum(:scan, /<dir\b/).filter_map do
      XmlTokenizer.attrs(xml[Regexp.last_match.begin(0)..])['value']
    end
    @event_bus.emit(:compass_update, dirs: current_dirs)
    @need_update = true
  end

  # Handle <progressBar .../> tags for vitals, stance, encumbrance, mind.
  # Dispatches to game-specific sub-patterns based on id and text format.
  def handle_progress_bar_tag(xml, _text_buffer)
    id, value, text = XmlTokenizer.attrs(xml).values_at('id', 'value', 'text')
    return unless id && value

    number = value.match?(/\A[0-9]+\z/)
    if id == 'encumlevel' && number && text
      value = text == 'Overloaded' ? 110 : value.to_i
      @event_bus.emit(:progress_update, id: 'encumbrance', value: value, max: 110)
      @need_update = true
    elsif id == 'pbarStance' && number
      @event_bus.emit(:progress_update, id: 'stance', value: value.to_i, max: 100)
      @need_update = true
    elsif id == 'mindState' && text
      value = text == 'saturated' ? 110 : value.to_i
      @event_bus.emit(:progress_update, id: 'mind', value: value, max: 110)
      @need_update = true
    elsif number && (m = text&.match(%r{\s(?<cur>-?[0-9]+)/(?<max>[0-9]+)\z}))
      # GemStone vitals: text contains current/max (e.g., "health 456/456")
      @event_bus.emit(:progress_update, id: id, value: m[:cur].to_i, max: m[:max].to_i)
      @need_update = true
    elsif number && DR_VITALS.include?(id) && text&.match?(/\A(?:health|mana|spirit|fatigue|concentration|inner fire) [0-9]+%\z/)
      # DragonRealms vitals: text contains percentage (e.g., "health 75%")
      @event_bus.emit(:progress_update, id: id, value: value.to_i, max: 100)
      @need_update = true
    end
  end

  # Handle <arbProgress id='...' max='...' current='...'/> user-defined progress bars.
  def handle_arb_progress_tag(xml, _text_buffer)
    id, max, cur, label, colors = XmlTokenizer.attrs(xml).values_at('id', 'max', 'current', 'label', 'colors')
    return unless id&.match?(/\A[a-zA-Z0-9]+\z/) && max&.match?(/\A\d+\z/) && cur&.match?(/\A\d+\z/)

    current = [cur.to_i, max.to_i].min
    data = { id: id, value: current, max: max.to_i }
    data[:label] = label unless label.nil? || label.empty?
    if colors&.match?(/\A\S+\z/)
      bg, fg = colors.split(',')
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
    return if xml.end_with?('/>') # an empty preset has nothing to color
    return unless (preset_id = XmlTokenizer.attrs(xml)['id'])

    if preset_id == 'roomDesc' && @wm.room[Streams::ROOM]
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
    return unless (style_id = XmlTokenizer.attrs(xml)['id'])

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
      @room_capture_mode = :desc if style_id == 'roomDesc' && @wm.room[Streams::ROOM]
    end
  end

  # Handle <pushStream>, <component>, or <compDef> stream-opening tag.
  # Flushes accumulated text and switches the current stream.
  #
  # Only a +<pushStream>+ is recorded on +@stream_stack+, so a later pop
  # can return to it. A component or compDef (including a self-closing
  # +<component id='…'/>+) only switches the current stream: nothing a pop
  # could later restore.
  def handle_stream_open(xml, text_buffer)
    attrs = XmlTokenizer.attrs(xml)
    return unless (new_stream = attrs['id'])

    flush_text_buffer(text_buffer)
    if (exp_match = new_stream.match(/^exp (?<skill>.+)/))
      @current_stream = Streams::EXP
      @event_bus.emit(:exp_set_current, skill: exp_match[:skill])
    else
      @current_stream = new_stream
      if new_stream == Streams::ROOM && (subtitle = attrs['subtitle'])
        title = parse_room_subtitle(subtitle)
        unless title.empty?
          @state.room_title = title
          @event_bus.emit(:room_title, text: title)
        end
      end
    end
    push_open_stream(@current_stream) if xml.start_with?('<pushStream')

    @combat_next_line = true if @current_stream == Streams::COMBAT
  end

  # Handle <popStream.../>, </component>, or </compDef> stream-closing tag.
  # Flushes accumulated text, then returns to the innermost pushStream
  # still open (the main window when none is).
  #
  # A +<popStream>+ first closes its pushStream on +@stream_stack+ (see
  # {#pop_open_stream}); a component or compDef close leaves the stack
  # alone. So after a nested push/pop the outer stream's remaining text
  # keeps going to the outer stream instead of spilling into main.
  def handle_stream_close(xml, text_buffer)
    if text_buffer.empty? && @current_stream&.start_with?(Streams::ROOM)
      # Empty room components (e.g., <component id='room players'></component>)
      # are meaningful — they clear the displayed data. Since flush_text_buffer
      # skips empty text, handle this directly.
      if @wm.room[Streams::ROOM]
        result = process_room_stream('')
        update_room_players_indicator(nil) if result == :continue
      elsif @current_stream == Streams::ROOM_PLAYERS
        # No RoomWindow -- still clear the indicator
        update_room_players_indicator(nil)
      end
    else
      flush_text_buffer(text_buffer)
    end
    @event_bus.emit(:exp_delete_skill) if @current_stream == Streams::EXP
    pop_open_stream(XmlTokenizer.attrs(xml)['id']) if xml.start_with?('<popStream')
    @current_stream = @stream_stack.last
  end

  # Record a pushStream as open, dropping the oldest entry beyond
  # {MAX_STREAM_DEPTH} so unmatched pushes can't accumulate.
  #
  # @param stream [String] the stream the push switched to
  # @return [void]
  def push_open_stream(stream)
    @stream_stack.push(stream)
    @stream_stack.shift while @stream_stack.length > MAX_STREAM_DEPTH
  end

  # Close a pushStream on +@stream_stack+.
  #
  # With an id that is open, close the innermost stream with that id and
  # discard anything opened after it (an inner push that never got its
  # pop). With no id, or an id that isn't open, close the innermost stream.
  # An empty stack stays empty.
  #
  # @param id [String, nil] the popStream's +id+ attribute
  # @return [void]
  def pop_open_stream(id)
    index = id && @stream_stack.rindex(id)
    if index
      @stream_stack.slice!(index..)
    else
      @stream_stack.pop
    end
  end

  # Resynchronize stream routing at a <prompt>.
  #
  # The game only sends a prompt in main-window context, so any stream
  # still open there was never closed (a dropped or missing pop). Close
  # them all: flush text already collected for the stale stream to it,
  # empty the stack and route to main. This is the resync point that keeps
  # one unmatched push from misrouting text for the rest of the session.
  # A no-op in the normal case (nothing open).
  #
  # @param text_buffer [String] mutable text accumulator
  # @return [void]
  def resync_streams_at_prompt(text_buffer)
    return unless @current_stream || !@stream_stack.empty? || @combat_next_line

    flush_text_buffer(text_buffer)
    @stream_stack.clear
    @current_stream = nil
    @combat_next_line = false
  end

  # Handle <clearStream id="percWindow"/> tag.
  def handle_clear_stream(xml, _text_buffer)
    @event_bus.emit(:clear_spells) if XmlTokenizer.attrs(xml)['id'] == Streams::PERC
  end

  # Handle <a ...> or <d ...> link opening tag.
  def handle_open_link(xml, text_buffer)
    # Always track links for room component streams — the RoomWindow needs
    # pre-computed link positions even when .links is off, so they're ready
    # when toggled on. Room stream text is consumed (never reaches main
    # window), so these extra color regions don't affect other windows.
    return unless @state.blue_links || @current_stream&.start_with?(Streams::ROOM)

    preset = PRESET['links'] || LinkExtractor::DEFAULT_LINK_COLOR
    link = { start: text_buffer.length, fg: preset[0], bg: preset[1] }
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
    id, visible = XmlTokenizer.attrs(xml).values_at('id', 'visible')
    return unless (m = id&.match(/\AIcon(?<icon>[A-Z]+)\z/)) && visible&.match?(/\A[yn]\z/)

    icon = m[:icon].downcase
    active = visible == 'y'
    @event_bus.emit(:countdown_active, id: icon, active: active)
    @event_bus.emit(:indicator_update, id: icon, value: active)
    @need_update = true
  end

  # Handle <image id='...' name='...'/> body part/injury tag.
  def handle_image_tag(xml, _text_buffer)
    id, name = XmlTokenizer.attrs(xml).values_at('id', 'name')
    return unless IMAGE_IDS.include?(id) && name

    if id == 'nsys'
      rank = name.slice(/[0-9]/)
      @event_bus.emit(:indicator_update, id: 'nsys', value: rank ? rank.to_i : 0)
    else
      fix_value = { 'Injury1' => 1, 'Injury2' => 2, 'Injury3' => 3, 'Scar1' => 4, 'Scar2' => 5, 'Scar3' => 6 }
      @event_bus.emit(:indicator_update, id: id, value: fix_value[name] || 0)
    end
    @need_update = true
  end

  # Handle <LaunchURL src="..."/> tag.
  #
  # The server sends a path that is appended to the play.net base URL. A src
  # that would make the result point anywhere other than
  # +https://www.play.net/+ (e.g. +@evil.example/+, which becomes userinfo,
  # or +.evil.example/+, which extends the host) is logged and ignored.
  def handle_launch_url(xml, _text_buffer)
    src = XmlTokenizer.attrs(xml)['src']
    return if src.nil? || src.empty?

    url = "#{LAUNCH_URL_BASE}#{src}"
    unless play_net_url?(url)
      ProfanityLog.write('launch_url', "ignored LaunchURL outside play.net: #{src.inspect}")
      return
    end

    @event_bus.emit(:launch_url, url: url, remote: @state.remote_url)
    @need_update = true
  end

  # Whether a URL is an https URL on www.play.net with no userinfo or
  # non-default port.
  #
  # @param url [String] the candidate URL
  # @return [Boolean]
  def play_net_url?(url)
    uri = URI.parse(url)
    uri.scheme == 'https' && uri.host == 'www.play.net' && uri.userinfo.nil? && uri.port == 443
  rescue URI::InvalidURIError
    false
  end

  # Handle <streamWindow id='room' subtitle='...'/> tag.
  def handle_stream_window(xml, _text_buffer)
    id, subtitle = XmlTokenizer.attrs(xml).values_at('id', 'subtitle')
    return unless id == Streams::ROOM && subtitle

    room = parse_room_subtitle(subtitle)
    return if room.empty?

    @state.room_title = room
    @event_bus.emit(:indicator_update, id: 'room', label: room, value: 1)
    @event_bus.emit(:room_title, text: room)
    @need_update = true
    @need_room_render = true
  end
end
