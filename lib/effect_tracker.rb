# frozen_string_literal: true

require_relative 'clock'

# The active effects (spells, buffs, debuffs, cooldowns) the game server
# sends as +<dialogData>+ blocks, collected into one bucket per category.
#
# A block is read as the tag parser meets it (see TagHandlers): it is
# started with {#start_dialog}, each of its +<progressBar>+ effects is
# added with {#add_effect}, and {#end_dialog} commits it. A commit replaces
# the whole bucket of the category and emits one
#
#   event_bus.emit(:effects_update, category: :spells, effects: [...])
#
# event, each effect a Hash:
#
#   { id: String, name: String, percent: Integer (0..100), end_time: Float or nil }
#
# +end_time+ is a server time, in epoch seconds, as the countdown windows
# use (see Clock#server_now): the time left that the server reported plus
# the clock's reading when the block was committed. nil is an indefinite
# effect, which the server sends with +time='Indefinite'+ (or, per the
# protocol notes, without a +time+); any +time+ that isn't +HH:MM:SS+ is
# read the same way. The effects are in the
# order the server sent them; the window owns any sorting.
#
# The server sends each category as an empty +clear='t'+ block followed by
# the block with the effects. A clear block alone is not committed: the
# block that follows replaces the bucket at once (so no empty bucket is
# emitted between the two). Should that block never come, {#finalize}
# commits the empty bucket.
#
# == Custom timers
#
# A Lich script can add timers of its own with a +<dialogData
# id='ProfanityCustom'>+ block (category +:custom+). Unlike the game's
# categories these are *sticky*: the tracker keeps them, and a block
# *merges* into them instead of replacing them.
#
# - +<progressBar id='X' text='Name' time='HH:MM:SS' value='0..100'/>+ adds
#   timer X, or updates it if X exists (it keeps its place in the list).
#   Only +id+ is required. +text+ defaults to the id, +value+ to 100, and a
#   missing or unreadable +time+ makes the timer indefinite. An +end_time+
#   attribute (server epoch seconds) is used instead of +time+ when given.
# - +<progressBar id='X' clear='t'/>+ removes timer X.
# - +<dialogData id='ProfanityCustom' clear='t'>+ removes every timer, even
#   as an empty block (the game's clear blocks wait for the block that
#   follows them; this one is acted on).
#
# Every committed block emits the whole custom list, in the order the timers
# were first added. A timer whose end time has passed is dropped from the
# set when the next block is committed; the window hides it as soon as it
# reaches 0 (see EffectsWindow), so no periodic event is needed.
#
# This class knows nothing of curses or of the tag parser.
#
# @example
#   tracker = EffectTracker.new(event_bus: bus, pending_render: render, clock: clock)
#   tracker.start_dialog(:buffs)
#   tracker.add_effect('id' => '115', 'value' => '97', 'text' => 'Blink', 'time' => '00:03:17')
#   tracker.end_dialog # emits :effects_update for :buffs
class EffectTracker
  # The +<dialogData>+ ids that hold effects, and the category of each.
  CATEGORIES = {
    'Active Spells' => :spells,
    'Buffs'         => :buffs,
    'Debuffs'       => :debuffs,
    'Cooldowns'     => :cooldowns,
  }.freeze

  # The +<dialogData>+ id of the timers Lich scripts add, and the category
  # they are kept in. Prefixed with +Profanity+ so that it can't clash with
  # an id the game sends.
  CUSTOM_DIALOG_ID = 'ProfanityCustom'

  # The category of the sticky custom timers.
  CUSTOM = :custom

  # A +time+ attribute: hours, minutes and seconds left.
  TIME_FORMAT = /\A(?<hours>[0-9]+):(?<minutes>[0-9]{1,2}):(?<seconds>[0-9]{1,2})\z/

  # The category a +<dialogData>+ id holds the effects of.
  #
  # @param dialog_id [String, nil] the +id+ attribute of a +<dialogData>+
  # @return [Symbol, nil] +:spells+, +:buffs+, +:debuffs+, +:cooldowns+ or
  #   (for +ProfanityCustom+) +:custom+; nil for any other dialog (e.g.
  #   +combat+, +minivitals+)
  def self.category_for(dialog_id)
    dialog_id == CUSTOM_DIALOG_ID ? CUSTOM : CATEGORIES[dialog_id]
  end

  # Seconds left in a +time+ attribute.
  #
  # @example
  #   EffectTracker.parse_seconds('04:02:59') #=> 14579
  #   EffectTracker.parse_seconds(nil)        #=> nil
  #
  # @param time [String, nil] +HH:MM:SS+
  # @return [Integer, nil] nil when there is no +time+, or it is
  #   +Indefinite+ or otherwise malformed (an indefinite effect)
  def self.parse_seconds(time)
    return unless (m = TIME_FORMAT.match(time.to_s.strip))

    (m[:hours].to_i * 3600) + (m[:minutes].to_i * 60) + m[:seconds].to_i
  end

  # @param event_bus [EventBus] receives the +:effects_update+ events
  # @param pending_render [PendingRender] asked for a screen update after each
  # @param clock [Clock] read for the server time (see Clock#server_now) that
  #   the time left is added to
  # @param unescape [#call] decodes the XML entities of an effect name
  #   (given the name as sent, returns it decoded); defaults to no decoding
  def initialize(event_bus:, pending_render:, clock: Clock.new, unescape: nil)
    @event_bus = event_bus
    @pending_render = pending_render
    @clock = clock
    @unescape = unescape || :itself.to_proc
    @buckets = [*CATEGORIES.values, CUSTOM].to_h { |category| [category, []] }
    # The sticky custom timers by id, in the order first added
    @custom = {}
    @open = nil
    @cleared = []
  end

  # Whether a block has been started and not yet ended.
  #
  # @return [Boolean]
  def open?
    !@open.nil?
  end

  # The effects last committed for a category.
  #
  # @param category [Symbol] one of {CATEGORIES}'s values, or +:custom+
  # @return [Array<Hash>] the effects, as {#commit} emitted them
  def effects(category)
    @buckets.fetch(category).dup
  end

  # Begin collecting a block's effects. A block still open is committed
  # first (its end tag never came).
  #
  # @param category [Symbol] one of {CATEGORIES}'s values
  # @param clear [Boolean] whether the block is a +clear='t'+ block
  # @return [void]
  def start_dialog(category, clear: false)
    end_dialog if open?
    @cleared.delete(category)
    @open = { category: category, clear: clear, effects: [] }
  end

  # Add one effect (a +<progressBar>+) to the open block. An effect without
  # an id is dropped. Does nothing when no block is open.
  #
  # @param attrs [Hash{String => String}] the bar's attributes: +id+, +value+
  #   (percent left), +text+ (the name, as sent) and +time+ (+HH:MM:SS+ left,
  #   absent for an indefinite effect). In a custom block also +clear+ (+'t'+
  #   removes the timer) and +end_time+ (server epoch seconds)
  # @return [void]
  def add_effect(attrs)
    return unless @open
    return if (id = attrs['id']).nil? || id.empty?

    @open[:effects] << if @open[:category] == CUSTOM
                         custom_entry(id, attrs)
                       else
                         { id: id, name: @unescape.call(attrs['text'].to_s), percent: percent_of(attrs['value']),
                           seconds: self.class.parse_seconds(attrs['time']) }
                       end
  end

  # End the open block. A +clear+ block with no effects only notes that its
  # category was cleared (see the class comment); any other is committed. A
  # custom block is always committed, a clear one clearing the timers first.
  #
  # @return [void]
  def end_dialog
    return unless @open

    block = @open
    @open = nil
    if block[:category] == CUSTOM
      commit_custom(block)
    elsif block[:clear] && block[:effects].empty?
      @cleared << block[:category] unless @cleared.include?(block[:category])
    else
      commit(block[:category], block[:effects])
    end
  end

  # Replace a category's bucket and emit it. (Custom timers merge: they are
  # committed by {#end_dialog}.)
  #
  # @param category [Symbol] one of {CATEGORIES}'s values
  # @param collected [Array<Hash>] the effects as {#add_effect} collected them
  # @return [void]
  def commit(category, collected = [])
    now = @clock.server_now
    effects = collected.map do |effect|
      seconds = effect[:seconds]
      { id: effect[:id], name: effect[:name], percent: effect[:percent], end_time: seconds && (now + seconds) }
    end
    @buckets[category] = effects
    @event_bus.emit(:effects_update, category: category, effects: effects.map(&:dup))
    @pending_render.request_update
  end

  # Settle everything left open: the open block is committed and each
  # category that was only cleared is committed empty. Called at a prompt,
  # so a missing end tag can't leak into the next block.
  #
  # @return [void]
  def finalize
    end_dialog
    cleared = @cleared
    @cleared = []
    cleared.each { |category| commit(category) }
  end

  # Forget the open block and what was cleared, emitting nothing. The sticky
  # custom timers are kept.
  #
  # @return [void]
  def reset
    @open = nil
    @cleared = []
  end

  private

  # One bar of a custom block: an add or update of a timer, or its removal.
  #
  # @param id [String] the timer's id
  # @param attrs [Hash{String => String}] the bar's attributes
  # @return [Hash]
  def custom_entry(id, attrs)
    return { id: id, remove: true } if attrs['clear'] == 't'

    name = @unescape.call(attrs['text'].to_s)
    { id: id, name: name.strip.empty? ? id : name, percent: percent_of(attrs['value'], default: 100),
      seconds: self.class.parse_seconds(attrs['time']), end_time: epoch_of(attrs['end_time']) }
  end

  # Merge a custom block into the sticky timers and emit them all.
  #
  # @param block [Hash] the block as {#start_dialog} and {#add_effect} built it
  # @return [void]
  def commit_custom(block)
    now = @clock.server_now
    @custom.clear if block[:clear]
    block[:effects].each do |entry|
      if entry[:remove]
        @custom.delete(entry[:id])
      else
        end_time = entry[:end_time] || (entry[:seconds] && (now + entry[:seconds]))
        # Updating a key keeps its place in the hash, so a timer doesn't jump
        @custom[entry[:id]] = { id: entry[:id], name: entry[:name], percent: entry[:percent], end_time: end_time }
      end
    end
    @custom.delete_if { |_id, timer| timer[:end_time] && timer[:end_time] <= now }
    @buckets[CUSTOM] = @custom.values
    @event_bus.emit(:effects_update, category: CUSTOM, effects: @buckets[CUSTOM].map(&:dup))
    @pending_render.request_update
  end

  # @param value [String, nil] an +end_time+ attribute
  # @return [Float, nil] the epoch seconds, nil unless it is a plain number
  def epoch_of(value)
    value&.strip&.match?(/\A[0-9]+(?:\.[0-9]+)?\z/) ? value.to_f : nil
  end

  # The percent a +value+ attribute holds, kept within 0 to 100.
  #
  # @param value [String, nil] the +value+ attribute
  # @param default [Integer] what a missing or unreadable value is
  # @return [Integer] +default+ when it isn't a number
  def percent_of(value, default: 0)
    return default unless value&.strip&.match?(/\A[0-9]+\z/)

    value.to_i.clamp(0, 100)
  end
end
