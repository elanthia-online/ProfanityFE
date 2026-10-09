# frozen_string_literal: true

# Active effects (spells, buffs, debuffs, cooldowns, custom) with live countdowns.

# Live list of the character's active effects.
#
# Each effect is one row: its name on the left, the time it has left as
# +HH:MM:SS+ on the right, and a fill bar behind the whole row that shows
# the share of its duration still left (the +percent+ the game sends). The
# row turns to the warning colors in the last minute, and to the ending
# colors once the time is up but the game hasn't dropped the effect yet.
# An effect without an end time shows {INDEFINITE_LABEL} instead of a
# countdown.
#
# The game sends each category's whole list at once ({#apply_effects},
# fed by +:effects_update+ events through {EventBridge}); the window keeps
# the game's order within a category so related effects (e.g. a spell
# circle) stay grouped and rows do not jump around as their time changes.
# Between events the countdowns run on {#tick}, which the application calls
# about ten times a second (the effects windows are in
# +WindowManager#effects+, by key).
#
# Categories are always drawn top to bottom in {DRAW_ORDER}: debuffs,
# cooldowns, buffs, custom, spells. Every drawn category starts with a
# header row (its title and how many effects it has), even when it has none.
#
# The +custom+ category holds the timers Lich scripts add (see
# {EffectTracker}: the tracker keeps them until they are cleared). Unlike
# the game's effects, which stay at 0 until the game drops them, a custom
# timer is hidden as soon as its time is up, and the header counts only the
# timers still shown. The window does this on {#tick}, so no event is needed
# when a custom timer runs out. A custom timer with no end time (Indefinite)
# is always shown.
#
# Which categories are drawn is up to the user: see {#enabled_categories},
# {#show_category}, {#hide_category} and {#toggle_category}.
#
# Single effects can be given their own bar colors with {#add_color_rule}.
#
# @example A window that shows spells and cooldowns
#   window.enabled_categories = %i[spells cooldowns]
#   window.apply_effects(:spells, [{ id: '101', name: 'Strength', percent: 80, end_time: 1_791_500_000.0 }])
#   window.tick
class EffectsWindow < BaseWindow
  # Resized after the spell window (see {BaseWindow.resize_order}).
  #
  # @return [Integer]
  def self.resize_order
    45
  end

  # The categories of effects: the four the game sends and +custom+, the
  # timers of Lich scripts. This is the set of valid categories; the order
  # they are drawn in is {DRAW_ORDER}.
  CATEGORIES = %i[spells buffs debuffs cooldowns custom].freeze

  # The category whose effects are hidden once their time is up, since no
  # server will drop them.
  EXPIRING_CATEGORY = :custom

  # The order categories are drawn in, top to bottom. Kept apart from
  # {CATEGORIES} (what is valid) so that reordering the display never
  # changes what counts as a category. +custom+ is last, so what scripts add
  # sits below the game's own effects.
  DRAW_ORDER = %i[debuffs cooldowns buffs custom spells].freeze

  # The categories shown until the user or the layout chooses others.
  DEFAULT_CATEGORIES = DRAW_ORDER

  # The title of each category's header row.
  CATEGORY_TITLES = { spells: 'Spells', buffs: 'Buffs', debuffs: 'Debuffs', cooldowns: 'Cooldowns',
                      custom: 'Custom' }.freeze

  # The key a window is registered under in +WindowManager#effects+ when
  # its layout element has no +value+ attribute.
  DEFAULT_KEY = 'effects'

  # What the time column shows for an effect that never runs out.
  INDEFINITE_LABEL = 'Indef'

  # Width of the time column: "HH:MM:SS".
  TIME_WIDTH = 8

  # An effect with this many seconds left or fewer uses the warning colors.
  WARNING_SECONDS = 60

  # Marks a name that was cut to fit.
  ELLIPSIS = "\u2026"

  # Fills the header rows after the category name.
  RULE = "\u2500"

  # The colors of one kind of row: foreground and background of the filled
  # part of the bar, and of the empty part.
  Palette = Struct.new(:fg_fill, :fg_empty, :bg_fill, :bg_empty)

  # The colors used unless a layout chooses others. The fill colors are
  # those of the old effectmon script; the empty part of each bar is a
  # dark shade of the same hue.
  DEFAULT_PALETTES = {
    normal: Palette.new('9BA2B2', '9BA2B2', '395573', '1b2735'),
    warning: Palette.new('9BA2B2', '9BA2B2', '767339', '34321a'),
    ending: Palette.new('9BA2B2', '9BA2B2', '8c4665', '3a1c28')
  }.freeze

  # Foreground of each category's header row.
  HEADER_COLORS = { spells: '7ea6d9', buffs: '7fc4a8', debuffs: 'd9788f', cooldowns: 'd9b36a', custom: 'b48ead' }.freeze

  # Foreground of the "+N more" row.
  MORE_COLOR = '7d8494'

  # One row of the list as it is shown. Comparing two lists of these tells
  # whether the screen would change.
  #
  # @!attribute kind
  #   @return [Symbol] +:header+, +:effect+ or +:more+
  # @!attribute remaining
  #   @return [Integer, nil] whole seconds left; nil when Indefinite
  Line = Struct.new(:kind, :category, :id, :name, :remaining, :percent, :total, keyword_init: true)

  # A request to color certain effects differently (see
  # {EffectsWindow#add_color_rule}). It says which effects it matches by
  # id, id range, name or name pattern, and holds the colors to use. When
  # it gives several matchers, an effect must satisfy all of them.
  class ColorRule
    # @return [Array<String, nil>, nil] foreground colors: filled, empty
    attr_reader :fg

    # @return [Array<String, nil>, nil] background colors: filled, empty
    attr_reader :bg

    # @param id [String, Integer, nil] an effect id, matched exactly
    # @param id_min [String, Integer, nil] lowest numeric id (inclusive)
    # @param id_max [String, Integer, nil] highest numeric id (inclusive)
    # @param name [String, nil] an effect name, matched whole, ignoring case
    # @param name_pattern [String, Regexp, nil] a regular expression found
    #   anywhere in the name, ignoring case
    # @param fg [Array<String, nil>, nil] foreground colors: filled, empty
    # @param bg [Array<String, nil>, nil] background colors: filled, empty
    # @raise [ArgumentError] when it has no matcher, a bound is not a whole
    #   number, the range is empty, or the pattern is not a valid regexp
    def initialize(id: nil, id_min: nil, id_max: nil, name: nil, name_pattern: nil, fg: nil, bg: nil)
      @id = presence(id)
      @id_min = integer(id_min, 'id_min')
      @id_max = integer(id_max, 'id_max')
      @name = presence(name)&.downcase
      @pattern = pattern(name_pattern)
      @fg = fg&.dup&.freeze
      @bg = bg&.dup&.freeze
      raise ArgumentError, 'no id, id_min, id_max, name or name_pattern' unless [@id, @id_min, @id_max, @name, @pattern].any?
      raise ArgumentError, "id_min #{@id_min} is above id_max #{@id_max}" if @id_min && @id_max && @id_min > @id_max
    end

    # @param id [String, nil] an effect's id
    # @param name [String, nil] an effect's name
    # @return [Boolean] whether the effect satisfies every matcher
    def match?(id, name)
      id = id.to_s.strip
      name = name.to_s
      (@id.nil? || id == @id) && id_in_range?(id) &&
        (@name.nil? || name.strip.downcase == @name) && (@pattern.nil? || @pattern.match?(name))
    end

    # The normal colors with this rule's colors on top; a color the rule
    # leaves out stays as in +base+.
    #
    # @param base [Palette]
    # @return [Palette]
    def palette_over(base)
      Palette.new(pick(fg, 0, base.fg_fill), pick(fg, 1, base.fg_empty), pick(bg, 0, base.bg_fill), pick(bg, 1, base.bg_empty))
    end

    private

    def presence(value)
      text = value.to_s.strip
      text.empty? ? nil : text
    end

    def integer(value, label)
      text = presence(value)
      text && Integer(text, 10)
    rescue ArgumentError
      raise ArgumentError, "#{label} #{text.inspect} is not a whole number"
    end

    def pattern(source)
      return source if source.is_a?(Regexp)

      text = presence(source)
      text && Regexp.new(text, Regexp::IGNORECASE)
    rescue RegexpError => e
      raise ArgumentError, "name_pattern #{text.inspect} is not a valid regexp: #{e.message}"
    end

    # A range rule matches only numeric ids.
    def id_in_range?(id)
      return true unless @id_min || @id_max
      return false unless id.match?(/\A\d+\z/)

      number = id.to_i
      (@id_min.nil? || number >= @id_min) && (@id_max.nil? || number <= @id_max)
    end

    def pick(colors, index, default)
      colors && index < colors.length ? colors[index] : default
    end
  end

  # The categories that exist, as symbols.
  #
  # @param name [Symbol, String, nil] a category name
  # @return [Boolean] whether it is one of {CATEGORIES}
  def self.category?(name)
    CATEGORIES.include?(name.to_s.strip.downcase.to_sym)
  end

  # Format a number of seconds as +HH:MM:SS+ (more hours widen the field).
  #
  # @param seconds [Numeric] seconds, never shown below 0
  # @return [String] e.g. "04:02:59"
  def self.format_duration(seconds)
    total = [seconds.to_i, 0].max
    format('%02d:%02d:%02d', total / 3600, total % 3600 / 60, total % 60)
  end

  # Create a new effects window, showing {DEFAULT_CATEGORIES} and no
  # effects.
  #
  # @param args [Array] arguments forwarded to {BaseWindow#initialize}
  def initialize(*args)
    @buckets = CATEGORIES.to_h { |category| [category, [].freeze] }.freeze
    @enabled = DEFAULT_CATEGORIES
    @palettes = DEFAULT_PALETTES.dup
    @color_rules = [].freeze
    @lines = []
    super
  end

  # The categories drawn, in drawing order.
  #
  # @return [Array<Symbol>] a subset of {CATEGORIES}, in {DRAW_ORDER}
  def enabled_categories
    @enabled
  end

  # Choose the categories to draw and redraw. Unknown names are ignored.
  #
  # @param categories [Array<Symbol, String>, String] category names, or a
  #   comma-separated string of them ("spells,buffs")
  # @return [void]
  def enabled_categories=(categories)
    names = categories.is_a?(String) ? categories.split(',') : Array(categories)
    names = names.map { |name| name.to_s.strip.downcase.to_sym }
    change_enabled(names)
  end

  # @param category [Symbol, String] a category name
  # @return [Boolean] whether the category is drawn
  def category_enabled?(category)
    @enabled.include?(category.to_s.strip.downcase.to_sym)
  end

  # Start drawing a category.
  #
  # @param category [Symbol, String] a category name
  # @return [Boolean] true if it was off and is now on; false if it was on
  #   already or is not a category
  def show_category(category)
    category = category.to_s.strip.downcase.to_sym
    return false unless CATEGORIES.include?(category) && !@enabled.include?(category)

    change_enabled(@enabled + [category])
    true
  end

  # Stop drawing a category.
  #
  # @param category [Symbol, String] a category name
  # @return [Boolean] true if it was on and is now off; false if it was off
  #   already or is not a category
  def hide_category(category)
    category = category.to_s.strip.downcase.to_sym
    return false unless @enabled.include?(category)

    change_enabled(@enabled - [category])
    true
  end

  # Draw a category if it is hidden, hide it if it is drawn.
  #
  # @param category [Symbol, String] a category name
  # @return [Boolean, nil] whether the category is drawn now; nil when it
  #   is not a category
  def toggle_category(category)
    return unless self.class.category?(category)

    if category_enabled?(category)
      hide_category(category)
      false
    else
      show_category(category)
      true
    end
  end

  # The effects last received for a category, in the order the game sent
  # them.
  #
  # @param category [Symbol] one of {CATEGORIES}
  # @return [Array<Hash>] frozen; empty for an unknown category
  def effects_for(category)
    @buckets.fetch(category.to_s.strip.downcase.to_sym, [])
  end

  # Replace a category's effects with the list the game just sent, and
  # redraw if that category is drawn.
  #
  # @param category [Symbol] one of {CATEGORIES}; anything else is ignored
  # @param effects [Array<Hash>] effects with +:id+, +:name+, +:percent+
  #   (0..100) and +:end_time+ (server epoch seconds; nil for Indefinite)
  # @return [void]
  def apply_effects(category, effects)
    category = category.to_s.strip.downcase.to_sym
    return unless CATEGORIES.include?(category)

    # Replace rather than mutate, so a draw on another thread always sees
    # a complete list.
    list = Array(effects).grep(Hash).map { |effect| effect.dup.freeze }.freeze
    @buckets = @buckets.merge(category => list).freeze
    redraw if @enabled.include?(category)
  end

  # The colors of a kind of row.
  #
  # @param kind [Symbol] +:normal+, +:warning+ or +:ending+
  # @return [Palette]
  def palette(kind)
    @palettes.fetch(kind)
  end

  # Change the colors of a kind of row. Each list holds the color of the
  # filled part of the bar, then of the empty part; a color left out keeps
  # its current value. A color of +nil+ is the terminal's default.
  #
  # @param kind [Symbol] +:normal+, +:warning+ or +:ending+
  # @param fg [Array<String, nil>, nil] foreground hex colors
  # @param bg [Array<String, nil>, nil] background hex colors
  # @return [void]
  def set_palette(kind, fg: nil, bg: nil)
    current = palette(kind)
    @palettes = @palettes.merge(
      kind => Palette.new(color_at(fg, 0, current.fg_fill), color_at(fg, 1, current.fg_empty),
                          color_at(bg, 0, current.bg_fill), color_at(bg, 1, current.bg_empty))
    )
  end

  # The color rules in force, in the order they are tried.
  #
  # @return [Array<ColorRule>] frozen
  attr_reader :color_rules

  # Color the effects that match, instead of the normal colors. See
  # {ColorRule} for the matchers. Rules are tried in the order they were
  # added and the first that matches an effect wins. A rule never hides
  # the warning and ending colors: an effect with a minute or less left
  # shows those, whatever rules match it.
  #
  # A rule that cannot be used (no matcher, a bound that is not a whole
  # number, a regexp that does not compile) is logged and skipped.
  #
  # @param matchers [Hash] +:id+, +:id_min+, +:id_max+, +:name+ and
  #   +:name_pattern+, as for {ColorRule#initialize}
  # @param fg [Array<String, nil>, nil] foreground colors: filled, empty
  # @param bg [Array<String, nil>, nil] background colors: filled, empty
  # @return [Boolean] true if the rule was added
  def add_color_rule(fg: nil, bg: nil, **matchers)
    rule = ColorRule.new(fg: fg, bg: bg, **matchers)
    @color_rules = [*@color_rules, rule].freeze
    redraw
    true
  rescue ArgumentError => e
    ProfanityLog.write('effects_window', "Ignoring color rule #{matchers.inspect}: #{e.message}")
    false
  end

  # Remove every color rule.
  #
  # @return [void]
  def clear_color_rules
    @color_rules = [].freeze
    redraw
  end

  # Work out what to show from the clock and the effects, and draw it.
  #
  # @return [void]
  def redraw
    @lines = build_lines(server_now)
    draw
  end

  # Draw the window again from the rows the last {#redraw} or {#tick}
  # worked out, at the current size, without reading the clock (see
  # {BaseWindow#repaint}).
  #
  # @return [void]
  def repaint
    draw
  end

  # Recalculate every countdown from one reading of the clock and redraw
  # if anything on screen changed. Cheap enough to call on every pass of
  # the input loop.
  #
  # @return [Boolean] true if the window was redrawn, false if unchanged
  def tick
    lines = build_lines(server_now)
    return false if lines == @lines

    @lines = lines
    draw
    true
  end

  private

  # The server's time now, from the clock the builder set.
  #
  # @return [Float]
  def server_now
    clock ? clock.server_now : Time.now.to_f
  end

  # Take on a new list of drawn categories and redraw.
  #
  # @param categories [Array<Symbol>] in any order
  # @return [void]
  def change_enabled(categories)
    @enabled = DRAW_ORDER.select { |category| categories.include?(category) }.freeze
    redraw
  end

  # @param colors [Array<String, nil>, nil] a list from the layout
  # @param index [Integer] the position to read
  # @param default [String, nil] used when the list has nothing there
  # @return [String, nil]
  def color_at(colors, index, default)
    colors && index < colors.length ? colors[index] : default
  end

  # Whole seconds left until a server end time, never below 0. The same
  # rounding as {CountdownWindow}.
  #
  # @param end_time [Numeric] the server time the effect ends at
  # @param server_now [Float] the server's time now ({Clock#server_now})
  # @return [Integer]
  def seconds_left(end_time, server_now)
    [(end_time.to_f - server_now - COUNTDOWN_OFFSET).ceil, 0].max
  end

  # Every row to show, top to bottom: for each drawn category, in
  # {DRAW_ORDER}, a header row and then its effects in the order the game
  # sent them (so related effects, e.g. a spell circle, stay grouped for
  # easy visual tracking). A category with no effects keeps its header,
  # with a count of 0.
  #
  # @param server_now [Float]
  # @return [Array<Line>]
  def build_lines(server_now)
    @enabled.flat_map do |category|
      effects = effect_lines(category, server_now)
      [Line.new(kind: :header, category: category, total: effects.length), *effects]
    end
  end

  # The category's effects as rows, in the order the game sent them
  # (no reordering, so related effects stay grouped and a row does not
  # jump around as its remaining time changes).
  #
  # @param category [Symbol]
  # @param server_now [Float]
  # @return [Array<Line>] the category's effects, in wire order; for
  #   {EXPIRING_CATEGORY} without those whose time is up
  def effect_lines(category, server_now)
    lines = @buckets.fetch(category).map do |effect|
      end_time = effect[:end_time]
      Line.new(kind: :effect, category: category, id: effect[:id].to_s, name: effect[:name].to_s,
               remaining: end_time && seconds_left(end_time, server_now),
               percent: effect[:percent].to_i.clamp(0, 100))
    end
    category == EXPIRING_CATEGORY ? lines.reject { |line| line.remaining&.zero? } : lines
  end

  # Draw the rows worked out last, top to bottom.
  #
  # @return [void]
  def draw
    erase
    visible_lines.each_with_index { |line, row| draw_line(row, line) }
    noutrefresh
  rescue StandardError => e
    ProfanityLog.write('effects_window', "Error drawing effects: #{e}", backtrace: e.backtrace)
  end

  # The rows that fit. When there are more than the window is high, the
  # last row says how many effects are not shown (headers are not
  # counted). Headers are kept, so an empty category stays visible; only
  # when everything left out is a header of an empty category is nothing
  # said and the rows are simply cut. A window under two rows high has no
  # room for that note and shows the first effects (or, with none, the
  # first headers).
  #
  # @return [Array<Line>]
  def visible_lines
    height = maxy
    return @lines if @lines.length <= height

    if height < 2
      effects = @lines.reject { |line| line.kind == :header }
      return (effects.empty? ? @lines : effects).first(height)
    end

    shown = @lines.first(height - 1)
    hidden = @lines.count { |line| line.kind == :effect } - shown.count { |line| line.kind == :effect }
    hidden.positive? ? [*shown, Line.new(kind: :more, total: hidden)] : @lines.first(height)
  end

  # @param row [Integer] the window row to draw on
  # @param line [Line]
  # @return [void]
  def draw_line(row, line)
    setpos(row, 0)
    case line.kind
    when :header then draw_header(line)
    when :more then draw_segment("+#{line.total} more".ljust(maxx)[0, maxx], MORE_COLOR, nil)
    else draw_effect(line)
    end
  end

  # A category's title, its rule and its effect count.
  #
  # @param line [Line]
  # @return [void]
  def draw_header(line)
    title = "#{RULE * 2} #{CATEGORY_TITLES.fetch(line.category)} "
    tail = " #{line.total}"
    text = title + (RULE * [maxx - title.length - tail.length, 0].max) + tail
    draw_segment(text[0, maxx], HEADER_COLORS.fetch(line.category), nil)
  end

  # An effect's row: the bar's filled part, then its empty part.
  #
  # @param line [Line]
  # @return [void]
  def draw_effect(line)
    width = maxx
    state = row_state(line)
    palette = palette_for(line, state)
    text = effect_text(line, width)
    # An effect that ran out is shown as a full bar in the ending colors
    filled = state == :ending ? width : (width * line.percent / 100.0).round
    draw_segment(text[0, filled], palette.fg_fill, palette.bg_fill) if filled.positive?
    draw_segment(text[filled, width], palette.fg_empty, palette.bg_empty) if filled < width
  end

  # The colors of an effect's row. The warning and ending colors come
  # first: an effect about to expire must warn whatever custom color it
  # has. Only a row that would otherwise be normal takes the colors of the
  # first color rule that matches it. To let custom colors win instead,
  # check the rules before the state here.
  #
  # @param line [Line] an effect
  # @param state [Symbol] its {#row_state}
  # @return [Palette]
  def palette_for(line, state)
    return @palettes.fetch(state) unless state == :normal

    rule = @color_rules.find { |candidate| candidate.match?(line.id, line.name) }
    rule ? rule.palette_over(@palettes.fetch(:normal)) : @palettes.fetch(:normal)
  end

  # @param line [Line] an effect
  # @return [Symbol] +:normal+, +:warning+ (a minute or less left) or
  #   +:ending+ (no time left)
  def row_state(line)
    remaining = line.remaining
    return :normal if remaining.nil?
    return :ending if remaining <= 0

    remaining <= WARNING_SECONDS ? :warning : :normal
  end

  # The text of an effect's row, exactly +width+ columns: the name, cut
  # with an ellipsis if it doesn't fit, a gap and the time column.
  #
  # @param line [Line] an effect
  # @param width [Integer] the window width
  # @return [String]
  def effect_text(line, width)
    time = (line.remaining.nil? ? INDEFINITE_LABEL : self.class.format_duration(line.remaining)).rjust(TIME_WIDTH)
    name_width = width - time.length - 1
    return time.rjust(width)[-width, width] if name_width < 1

    "#{truncate(line.name, name_width).ljust(name_width)} #{time}"
  end

  # @param name [String]
  # @param limit [Integer] columns available (at least 1)
  # @return [String] the name, or its start and an ellipsis if too long
  def truncate(name, limit)
    return name if name.length <= limit

    "#{name[0, limit - 1].rstrip}#{ELLIPSIS}"
  end

  # Draw text in the given colors at the cursor. Uses attrset rather than
  # attron with a block, so the background shows on spaces in every curses
  # implementation (see {CountdownWindow}).
  #
  # @param text [String]
  # @param fg_code [String, nil] foreground hex color
  # @param bg_code [String, nil] background hex color
  # @return [void]
  def draw_segment(text, fg_code, bg_code)
    attrset(Curses.color_pair(get_color_pair_id(fg_code, bg_code)))
    addstr(text)
    attrset(Curses::A_NORMAL)
  end
end

# Builds an effects window from a layout element:
#
#   <window class='effects' top='0' left='0' height='20' width='40'
#           value='effects' categories='spells,buffs,debuffs,cooldowns,custom'
#           fg='9BA2B2,9BA2B2' bg='395573,1b2735'
#           warn_fg='...' warn_bg='...' end_fg='...' end_bg='...'>
#     <effectColor id='401' fg='ff0000' bg='550000,220000'/>
#     <effectColor id_min='400' id_max='499' bg='00aaff,003344'/>
#     <effectColor name='Strength' fg='ffd700'/>
#     <effectColor name_pattern='Sign of .*' bg='884400,221100'/>
#   </window>
#
# - +value+: the key of the window in +WindowManager#effects+ (default
#   "effects"); a window of the previous layout with the same key is kept,
#   with its effects and its chosen categories.
# - +categories+: comma-separated categories to show: spells, buffs,
#   debuffs, cooldowns, custom (default all five, or, on a kept window, the
#   categories it shows). They are always drawn in the order debuffs,
#   cooldowns, buffs, custom, spells, each under its own header.
# - +fg+ / +bg+: colors of ordinary rows, as "filled,empty" (the filled and
#   the empty part of the bar); a color left out keeps its default.
# - +warn_fg+ / +warn_bg+: the same for an effect with a minute or less
#   left. +end_fg+ / +end_bg+: the same for an effect with no time left.
#
# Each +<effectColor>+ child gives the effects it matches their own colors
# (see {EffectsWindow#add_color_rule}). The first one, in the order
# written, that matches an effect wins. It matches by any of:
# - +id+: the effect id, exactly (e.g. "401").
# - +id_min+ / +id_max+: a numeric id range, both ends included; either end
#   may be left out. An id that is not a number never matches a range.
# - +name+: the whole effect name, ignoring case.
# - +name_pattern+: a regular expression found anywhere in the name,
#   ignoring case. A pattern that does not compile is logged and its rule
#   skipped.
# When it gives more than one of these, the effect must match all of them;
# a rule with none is skipped. Its colors are +fg+ and +bg+, written like
# the ones above ("filled,empty"); a color left out stays as in the normal
# colors. A row in the warning or ending colors keeps them: custom colors
# only replace the normal ones. A kept window gets exactly the rules of the
# new layout; without any +<effectColor>+ the window colors as before.
BaseWindow.register_type('effects') do |height, width, top, left, element, wm|
  key = element.attributes['value'] || EffectsWindow::DEFAULT_KEY
  window = wm.claim_window(:effects, key, EffectsWindow) || EffectsWindow.new(height, width, top, left)
  window.scrollok(false)
  window.clock = wm.clock
  window.enabled_categories = element.attributes['categories'] if element.attributes['categories']
  { normal: %w[fg bg], warning: %w[warn_fg warn_bg], ending: %w[end_fg end_bg] }.each do |kind, (fg_attr, bg_attr)|
    next unless element.attributes[fg_attr] || element.attributes[bg_attr]

    window.set_palette(kind, fg: BaseWindow.parse_color_attrs(element, fg_attr),
                             bg: BaseWindow.parse_color_attrs(element, bg_attr))
  end
  window.clear_color_rules
  element.elements.each do |child|
    next unless child.name == 'effectColor'

    window.add_color_rule(id: child.attributes['id'], id_min: child.attributes['id_min'],
                          id_max: child.attributes['id_max'], name: child.attributes['name'],
                          name_pattern: child.attributes['name_pattern'],
                          fg: BaseWindow.parse_color_attrs(child, 'fg'), bg: BaseWindow.parse_color_attrs(child, 'bg'))
  end
  wm.effects[key] = window
  window.redraw
  window
end
