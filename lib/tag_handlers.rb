# frozen_string_literal: true

require 'uri'
require_relative 'xml_tokenizer'
require_relative 'link_extractor'
require_relative 'streams'
require_relative 'presets'
require_relative 'room_title'

# Tag dispatch and handler methods for game server XML processing.
#
# Replaces the 30+ elsif regex chain in GameTextProcessor#run with
# a hash-based dispatch table and focused handler methods. Each XML
# tag type has its own method, making the processing logic easier to
# understand, test, and modify independently.
#
# Expects the including class to provide:
# - @state, @xml_escapes, @event_bus
# - @spans (a SpanTracker: the open color spans and the runs they record)
# - @marks (a SpanTracker with SpanTracker::ROOM_MARKS: the room marks,
#   where the line's bold text and links are, whatever their colors, and
#   each link's command and noun)
# - @router (a StreamRouter: the current stream and the open pushStreams)
# - @pending_render (a PendingRender: screen updates to flush)
# - @room (a RoomAssembler)
# - @prompts (a PromptTracker)
# - @coord_commands (a CoordCommands: the game's commands for coord links)
# - handle_game_text(text, runs, marks)
# - line_gagged? (whether a gag dropped the text of the line being parsed,
#   leaving only its kept tags; see LineFilter#gagged?)
module TagHandlers
  # Base URL that every <LaunchURL src="..."/> path is appended to.
  LAUNCH_URL_BASE = 'https://www.play.net'

  # progressBar ids of the DragonRealms vitals, whose text is a percentage.
  DR_VITALS = %w[health mana spirit stamina concentration].freeze

  # Body parts (and +nsys+) an <image> tag can report on.
  IMAGE_IDS = %w[back leftHand rightHand head rightArm abdomen leftEye leftArm chest rightLeg neck leftLeg nsys rightEye].freeze

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
    'cmdlist'      => :handle_cmdlist_open,
    'cli'          => :handle_ignored_tag,
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
    'cmdlist'   => :handle_ignored_tag,
  }.freeze

  # Dispatch an XML tag to its handler method.
  #
  # @param xml [String] full XML tag string
  # @param text_buffer [String] mutable text accumulator (positions
  #   are tracked via text_buffer.length)
  # @return [void]
  def dispatch_tag(xml, text_buffer)
    name = XmlTokenizer.tag_name(xml)
    closing = xml.start_with?('</')
    # Inside a <cmdlist>, its entries are read and other tags ignored.
    return if @coord_commands.reading? && read_cmdlist_tag(xml, name, closing)

    # Combat tracking: reset flag on any <popStream> tag, bare or with an id.
    # A combat block closed by a bare <popStream/> must not leave later
    # unrecognized tags routed to combat.
    # This runs for every tag, before dispatch (matching original behavior).
    @router.end_combat_routing if name == 'popStream' && !closing
    # A prompt is the stream resync point: it closes any stream left open.
    # It also ends a style left open, at the end of its line.
    if name == 'prompt' && !closing
      resync_streams_at_prompt(text_buffer)
      @spans.prompt
      @marks.prompt
      @room.prompt_seen
    end

    table = closing ? CLOSING_TAG_DISPATCH : TAG_DISPATCH
    handler = table[name]

    if handler
      send(handler, xml, text_buffer)
    elsif @router.combat_routing?
      # Unrecognized tag while combat-next-line is active:
      # flush accumulated text and switch to combat stream.
      flush_text_buffer(text_buffer)
      @router.switch_to_combat
    end
  end

  private

  # Flush accumulated text through handle_game_text and clear the buffer.
  # Spans still open color the flushed text and continue in the text that
  # follows, except links (see SpanTracker::POLICIES).
  #
  # @param buf [String] mutable text buffer to flush and clear
  # @return [void]
  def flush_text_buffer(buf)
    handle_game_text(buf.dup, *split_spans(:flush, buf.length)) unless buf.empty?
    buf.clear
  end

  # Hand off the text parsed so far to both span trackers, the color runs
  # and the room marks, so the two always cover the same text.
  #
  # @param at [Symbol] +:flush+ (a mid-line flush, see
  #   SpanTracker#split_at_flush) or +:line_end+ (the line's last text, see
  #   SpanTracker#split_at_line_end)
  # @param length [Integer] length of the text handed off
  # @return [Array(Array<Hash>, Array<Hash>)] the color runs and the room
  #   marks for that text
  def split_spans(at, length)
    split = at == :flush ? :split_at_flush : :split_at_line_end
    [@spans.public_send(split, length), @marks.public_send(split, length)]
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
  #
  # @param _xml [String] the tag (unused)
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_ignored_tag(_xml, _text_buffer); end

  # Handle <prompt time='...'>text&gt;</prompt> paired tag (see
  # PromptTracker#prompt_tag).
  #
  # @param xml [String] the paired tag, its content included
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_prompt_tag(xml, _text_buffer)
    @prompts.prompt_tag(xml)
  end

  # Handle <spell>name</spell> paired tag.
  #
  # @param xml [String] the paired tag, its content included
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_spell_tag(xml, _text_buffer)
    return unless (spell = XmlTokenizer.content(xml))

    @event_bus.emit(:indicator_update, id: 'spell', label: spell,
                                       value: spell == 'None' ? 0 : 1)
    @pending_render.request_update
  end

  # Handle <right>item</right> or <left>item</left> paired tag.
  #
  # @param xml [String] the paired tag, its content included
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_hand_tag(xml, _text_buffer)
    return unless (item = XmlTokenizer.content(xml))

    @event_bus.emit(:indicator_update, id: XmlTokenizer.tag_name(xml), label: item,
                                       value: item == 'Empty' ? 0 : 1)
    @pending_render.request_update
  end

  # Handle <roundTime value='N'/> tag. Sets the countdown end time.
  # The countdown display is polled by Application#tick_countdowns
  # on every input loop iteration (~100ms).
  #
  # @param xml [String] the tag
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_roundtime_tag(xml, _text_buffer)
    return unless (value = countdown_value(xml))

    @event_bus.emit(:countdown_update, id: 'roundtime', end_time: value)
    @pending_render.request_update
  end

  # Handle <castTime value='N'/> tag. Sets the secondary countdown end time.
  # The countdown display is polled by Application#tick_countdowns
  # on every input loop iteration (~100ms).
  #
  # @param xml [String] the tag
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_casttime_tag(xml, _text_buffer)
    return unless (value = countdown_value(xml))

    @event_bus.emit(:countdown_update, id: 'roundtime', secondary_end_time: value)
    @pending_render.request_update
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
  #
  # @param xml [String] the paired tag, its content included
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_compass_tag(xml, _text_buffer)
    current_dirs = XmlTokenizer.tags(xml, paired: false).filter_map do |tag|
      XmlTokenizer.attrs(tag)['value'] if XmlTokenizer.start_tag_name(tag) == 'dir'
    end
    @event_bus.emit(:compass_update, dirs: current_dirs)
    @pending_render.request_update
  end

  # Handle <progressBar .../> tags for vitals, stance, encumbrance, mind.
  # Dispatches to game-specific sub-patterns based on id and text format.
  #
  # @param xml [String] the tag
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_progress_bar_tag(xml, _text_buffer)
    id, value, text = XmlTokenizer.attrs(xml).values_at('id', 'value', 'text')
    return unless id && value

    number = value.match?(/\A[0-9]+\z/)
    if id == 'encumlevel' && number && text
      value = text == 'Overloaded' ? 110 : value.to_i
      @event_bus.emit(:progress_update, id: 'encumbrance', value: value, max: 110)
      @pending_render.request_update
    elsif id == 'pbarStance' && number
      @event_bus.emit(:progress_update, id: 'stance', value: value.to_i, max: 100)
      @pending_render.request_update
    elsif id == 'mindState' && text
      value = text == 'saturated' ? 110 : value.to_i
      @event_bus.emit(:progress_update, id: 'mind', value: value, max: 110)
      @pending_render.request_update
    elsif number && (m = text&.match(%r{\s(?<cur>-?[0-9]+)/(?<max>[0-9]+)\z}))
      # GemStone vitals: text contains current/max (e.g., "health 456/456")
      @event_bus.emit(:progress_update, id: id, value: m[:cur].to_i, max: m[:max].to_i)
      @pending_render.request_update
    elsif number && DR_VITALS.include?(id) && text&.match?(/\A(?:health|mana|spirit|fatigue|concentration|inner fire) [0-9]+%\z/)
      # DragonRealms vitals: text contains percentage (e.g., "health 75%")
      @event_bus.emit(:progress_update, id: id, value: value.to_i, max: 100)
      @pending_render.request_update
    end
  end

  # Handle <arbProgress id='...' max='...' current='...'/> user-defined progress bars.
  #
  # @param xml [String] the tag
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
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
    @pending_render.request_update
  end

  # Handle <pushBold/> or <b> tag. Opens a monster bold color region.
  #
  # @param _xml [String] the tag (unused)
  # @param text_buffer [String] the text collected so far on the line (tags removed); its length is where the tag sits
  # @return [void]
  def handle_push_bold(_xml, text_buffer)
    @spans.open(:bold, text_buffer.length, **Presets.colors(Presets::MONSTERBOLD).to_h)
    @marks.open(:bold, text_buffer.length, mark: :bold)
  end

  # Handle <popBold/> or </b> tag. Closes the most recent monster bold region.
  #
  # @param _xml [String] the tag (unused)
  # @param text_buffer [String] the text collected so far on the line (tags removed); its length is where the tag sits
  # @return [void]
  def handle_pop_bold(_xml, text_buffer)
    @spans.close(:bold, text_buffer.length)
    @marks.close(:bold, text_buffer.length)
  end

  # Handle <preset id='...'> opening tag.
  #
  # @param xml [String] the tag
  # @param text_buffer [String] the text collected so far on the line (tags removed); its length is where the tag sits
  # @return [void]
  def handle_open_preset(xml, text_buffer)
    return if xml.end_with?('/>') # an empty preset has nothing to color
    return unless (preset_id = XmlTokenizer.attrs(xml)['id'])

    # Unlike a roomDesc style, the preset flushes the text before it.
    @room.start_capture(:desc) { flush_text_buffer(text_buffer) } if preset_id == Presets::ROOM_DESC
    @spans.open(:preset, text_buffer.length, **Presets.colors(preset_id).to_h)
  end

  # Handle </preset> closing tag.
  #
  # @param _xml [String] the tag (unused)
  # @param text_buffer [String] the text collected so far on the line (tags removed); its length is where the tag sits
  # @return [void]
  def handle_close_preset(_xml, text_buffer)
    @room.end_capture(:desc) { flush_text_buffer(text_buffer) }
    @spans.close(:preset, text_buffer.length)
  end

  # Handle <color fg='...' bg='...' ul='...'> opening tag.
  #
  # @param xml [String] the tag
  # @param text_buffer [String] the text collected so far on the line (tags removed); its length is where the tag sits
  # @return [void]
  def handle_open_color(xml, text_buffer)
    attrs = XmlTokenizer.attrs(xml)
    colors = %w[fg bg ul].filter_map { |name| [name.to_sym, attrs[name].downcase] if attrs[name] }.to_h
    @spans.open(:color, text_buffer.length, **colors)
  end

  # Handle </color> closing tag.
  #
  # @param _xml [String] the tag (unused)
  # @param text_buffer [String] the text collected so far on the line (tags removed); its length is where the tag sits
  # @return [void]
  def handle_close_color(_xml, text_buffer)
    @spans.close(:color, text_buffer.length)
  end

  # Handle <style id='...'> tag (both opening and "closing" via empty id).
  # The game protocol uses <style id=""> as a close marker rather than </style>.
  #
  # @param xml [String] the tag
  # @param text_buffer [String] the text collected so far on the line (tags removed); its length is where the tag sits
  # @return [void]
  def handle_style_tag(xml, text_buffer)
    return unless (style_id = XmlTokenizer.attrs(xml)['id'])

    if style_id.empty?
      # Empty id = closing style
      @room.end_capture(:title, :desc) { flush_text_buffer(text_buffer) }
      @spans.close(:style, text_buffer.length)
    else
      # Non-empty id = opening style
      @spans.open(:style, text_buffer.length, **Presets.colors(style_id).to_h)
      # A gagged line's text is gone, so its style tag must not make the
      # next line's text the room title or description.
      return if line_gagged?

      @room.start_capture(:title) if style_id == Presets::ROOM_NAME
      @room.start_capture(:desc, at: text_buffer.length) if style_id == Presets::ROOM_DESC
    end
  end

  # Handle <pushStream>, <component>, or <compDef> stream-opening tag.
  # Flushes accumulated text and switches the current stream (see
  # StreamRouter#open_stream: only a pushStream nests).
  #
  # @param xml [String] the tag
  # @param text_buffer [String] the text collected so far on the line (tags removed); its length is where the tag sits
  # @return [void]
  def handle_stream_open(xml, text_buffer)
    attrs = XmlTokenizer.attrs(xml)
    return unless (new_stream = attrs['id'])

    flush_text_buffer(text_buffer)
    if (exp_match = new_stream.match(/^exp (?<skill>.+)/))
      stream = Streams::EXP
      @event_bus.emit(:exp_set_current, skill: exp_match[:skill])
    else
      stream = new_stream
      if new_stream == Streams::ROOM && (subtitle = attrs['subtitle']) && !subtitle.strip.empty?
        title = RoomTitle.parse(unescape_entities(subtitle))
        @state.room_title = title.plain if title
        # An empty name is no title: it hides the title row, and the
        # terminal title keeps naming the last room.
        @room.subtitle(title.to_s)
      end
    end
    @router.open_stream(stream, push: XmlTokenizer.start_tag_name(xml) == 'pushStream')
  end

  # Handle <popStream.../>, </component>, or </compDef> stream-closing tag.
  # Flushes accumulated text, then returns to the innermost pushStream
  # still open (the main window when none is; see StreamRouter#close_stream).
  #
  # An empty room component clears its section (see #empty_room_close?);
  # the empty popStream that ends a push of the bare room stream sends
  # nothing, so it keeps the title row.
  #
  # @param xml [String] the tag
  # @param text_buffer [String] the text collected so far on the line (tags removed); its length is where the tag sits
  # @return [void]
  def handle_stream_close(xml, text_buffer)
    stream = @router.current_stream
    pop = XmlTokenizer.start_tag_name(xml) == 'popStream'
    if text_buffer.empty? && empty_room_close?(stream, pop)
      # Empty room components (e.g., <component id='room players'></component>)
      # are meaningful — they clear the displayed data. Since flush_text_buffer
      # skips empty text, handle this directly. Without a RoomWindow only an
      # empty room players component does anything: it clears the indicator.
      result = @room.process_room_stream('', stream, @marks.runs)
      @room.update_room_players_indicator(nil) if result == :continue
    else
      flush_text_buffer(text_buffer)
    end
    @event_bus.emit(:exp_delete_skill) if @router.current_stream == Streams::EXP
    @router.close_stream(pop: pop, id: pop ? XmlTokenizer.attrs(xml)['id'] : nil)
  end

  # Whether an empty close of +stream+ sends its room section empty, which
  # clears it: any room stream's close does, except a popStream of the bare
  # room stream. GemStone ends every room push with an empty
  # <popStream id='room'/> after the room compDefs; it ends the push and
  # sends no title, so the title row keeps the room the subtitle named.
  # DragonRealms sends no room push.
  #
  # @param stream [String, nil] the stream being closed
  # @param pop [Boolean] whether the closing tag is a popStream
  # @return [Boolean]
  def empty_room_close?(stream, pop)
    return false unless stream&.start_with?(Streams::ROOM)

    !(pop && stream == Streams::ROOM)
  end

  # Resynchronize stream routing at a <prompt>: flush text already
  # collected for a stale stream to it, then close every stream left open
  # (see StreamRouter#resync). A no-op in the normal case (nothing open).
  #
  # @param text_buffer [String] mutable text accumulator
  # @return [void]
  def resync_streams_at_prompt(text_buffer)
    return unless @router.resync_needed?

    flush_text_buffer(text_buffer)
    @router.resync
  end

  # Handle <clearStream id="percWindow"/> tag.
  #
  # @param xml [String] the tag
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_clear_stream(xml, _text_buffer)
    @event_bus.emit(:clear_spells) if XmlTokenizer.attrs(xml)['id'] == Streams::PERC
  end

  # Handle <cmdlist ...>, the start of the game's command table for coord
  # links (see CoordCommands): its entries are read until </cmdlist>. An
  # empty <cmdlist/> has none.
  #
  # @param xml [String] the tag
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_cmdlist_open(xml, _text_buffer)
    @coord_commands.start unless xml.end_with?('/>')
  end

  # Read a tag inside a <cmdlist>: a <cli> is an entry, </cmdlist> keeps
  # the table, and a prompt discards it (a table cut short) and is then
  # handled as usual. Any other tag is ignored, as the text is (see
  # GameTextProcessor#process_line_tags).
  #
  # @param xml [String] the tag
  # @param name [String, nil] its element name
  # @param closing [Boolean] whether it is an end tag
  # @return [Boolean] true if the tag was read here, false for a prompt
  def read_cmdlist_tag(xml, name, closing)
    if closing
      @coord_commands.finish if name == 'cmdlist'
    elsif name == 'cli'
      attrs = XmlTokenizer.attrs(xml)
      @coord_commands.add(coord: attrs['coord'], command: attrs['command'])
    elsif name == 'prompt'
      @coord_commands.discard
      return false
    end
    true
  end

  # Handle <a ...> or <d ...> link opening tag. A coord link with no
  # command (see LinkExtractor.extract_cmd) is not a link: it gets no
  # link color and no command, so a click on it sends nothing.
  #
  # @param xml [String] the tag
  # @param text_buffer [String] the text collected so far on the line (tags removed); its length is where the tag sits
  # @return [void]
  def handle_open_link(xml, text_buffer)
    cmd = LinkExtractor.extract_cmd(xml, coord_commands: @coord_commands)
    # The room marks record every link: the room window keeps its links
    # while .links is off, so they work once it is turned on. A GS link's
    # noun names what it links to: the logons window takes a custom logon
    # message's character from it.
    @marks.open(:link, text_buffer.length, mark: :link, cmd: cmd, noun: XmlTokenizer.attrs(xml)['noun'])
    # The link's color span: with .links on, and always in a room stream,
    # whose colors go to the room players indicator and to a text window
    # showing that stream (the room window takes its links from the room
    # marks). Room stream text never reaches main.
    return unless @state.blue_links || @router.current_stream&.start_with?(Streams::ROOM)

    # An uncolored span records no run, but still pairs with its </a>.
    colors = cmd == false ? {} : Presets.colors(Presets::LINKS, LinkExtractor::DEFAULT_LINK_COLOR)
    @spans.open(:link, text_buffer.length, fg: colors[:fg], bg: colors[:bg], cmd: cmd)
  end

  # Handle </a> or </d> link closing tag: closes the link's color span and
  # its room mark.
  #
  # @param _xml [String] the tag (unused)
  # @param text_buffer [String] the text collected so far on the line (tags removed); its length is where the tag sits
  # @return [void]
  def handle_close_link(_xml, text_buffer)
    @spans.close(:link, text_buffer.length) { |span| link_text_cmd(span, text_buffer) }
    @marks.close(:link, text_buffer.length) { |span| link_text_cmd(span, text_buffer) }
  end

  # Give a link without a cmd, coord or exist attribute (e.g. an exit
  # direction) its text as its command. A coord link with no command
  # (+:cmd+ false) keeps none.
  #
  # @param span [Hash] the closed link span, with +:start+, +:end+ and
  #   +:cmd+
  # @param text_buffer [String] the text collected so far on the line
  # @return [void]
  def link_text_cmd(span, text_buffer)
    return unless span[:cmd].nil? && span[:start] && span[:end] > span[:start]

    span[:cmd] = text_buffer[span[:start]...span[:end]]
  end

  # Handle <indicator id='IconXXX' visible='y|n'/> tag.
  #
  # @param xml [String] the tag
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_indicator_tag(xml, _text_buffer)
    id, visible = XmlTokenizer.attrs(xml).values_at('id', 'visible')
    return unless (m = id&.match(/\AIcon(?<icon>[A-Z]+)\z/)) && visible&.match?(/\A[yn]\z/)

    icon = m[:icon].downcase
    active = visible == 'y'
    @event_bus.emit(:countdown_active, id: icon, active: active)
    @event_bus.emit(:indicator_update, id: icon, value: active)
    @pending_render.request_update
  end

  # Handle <image id='...' name='...'/> body part/injury tag.
  #
  # @param xml [String] the tag
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
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
    @pending_render.request_update
  end

  # Handle <LaunchURL src="..."/> tag.
  #
  # The server sends a path that is appended to the play.net base URL. A src
  # that would make the result point anywhere other than
  # +https://www.play.net/+ (e.g. +@evil.example/+, which becomes userinfo,
  # or +.evil.example/+, which extends the host) is logged and ignored.
  #
  # @param xml [String] the tag
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_launch_url(xml, _text_buffer)
    src = XmlTokenizer.attrs(xml)['src']
    return if src.nil? || src.empty?

    url = "#{LAUNCH_URL_BASE}#{src}"
    unless play_net_url?(url)
      ProfanityLog.write('launch_url', "ignored LaunchURL outside play.net: #{src.inspect}")
      return
    end

    @event_bus.emit(:launch_url, url: url, remote: @state.remote_url)
    @pending_render.request_update
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
  #
  # @param xml [String] the tag
  # @param _text_buffer [String] the text collected so far on the line (unused)
  # @return [void]
  def handle_stream_window(xml, _text_buffer)
    id, subtitle = XmlTokenizer.attrs(xml).values_at('id', 'subtitle')
    # A blank subtitle sends no title at all: it changes nothing.
    return unless id == Streams::ROOM && subtitle && !subtitle.strip.empty?

    title = RoomTitle.parse(unescape_entities(subtitle))
    if title
      @state.room_title = title.plain
      # The room indicator names the room without its brackets, as before.
      @event_bus.emit(:indicator_update, id: 'room', label: title.plain, value: 1)
    end
    # An empty name is no title: it hides the title row, and the terminal
    # title and the room indicator keep naming the last room.
    @room.subtitle(title.to_s)
    @pending_render.request_room_render
    @pending_render.request_update
  end
end
