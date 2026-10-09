# frozen_string_literal: true

# Tests the effects window (EffectsWindow) as a user sees it: the rows it
# draws on the virtual screen (spec/support/virtual_screen.rb), their
# colors, and how the countdowns move with the clock. The window is built
# directly for most examples; the last groups build it from layout XML
# with WindowManager and feed it +:effects_update+ events as the parser
# does.

require 'rexml/document'
require_relative '../../../lib/clock'
require_relative '../../../lib/event_bus'
require_relative '../../../lib/window_manager'

RSpec.describe EffectsWindow do
  let(:width) { 30 }
  let(:height) { 6 }
  let(:now) { [1_000_000.0] }
  let(:clock) { Clock.new(now: -> { Time.at(now[0]) }) }
  let(:window) { build_window(height, width) }

  # A distinct color pair number for every fg/bg combination drawn, so the
  # virtual screen's attributes show which colors each cell got.
  let(:pairs) { Hash.new { |hash, key| hash[key] = hash.size + 1 } }

  before do
    allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, bg| pairs[[fg, bg]] }
  end

  # A window showing the given categories (default: only spells, so most
  # examples have one header on row 0 and the effects from row 1). The
  # default of showing every category is checked under 'defaults'.
  def build_window(rows, columns, categories: %i[spells])
    described_class.new(rows, columns, 0, 0).tap do |built|
      built.clock = clock
      built.scrollok(false)
      built.enabled_categories = categories
    end
  end

  # An effect as the backend sends it. +seconds+ is the time left now; nil
  # is an Indefinite effect.
  def effect(name, seconds, percent: 50, id: name)
    { id: id, name: name, percent: percent, end_time: seconds && (now[0] + seconds) }
  end

  # The text of an effect row of the default width: the name, then the
  # 8-column time.
  def effect_row(name, time, columns = width)
    "#{name.ljust(columns - 9)} #{time}"
  end

  # The text of a category's header row: "── Title ──── count".
  def header(title, count, columns = width)
    lead = "\u2500\u2500 #{title} "
    tail = " #{count}"
    lead + ("\u2500" * (columns - lead.length - tail.length)) + tail
  end

  def color_at(target, row, col)
    pairs.key((target.attrs_at(row, col) & Curses::A_COLOR) >> 8)
  end

  # The [fg, bg] colors of every cell of a row.
  def colors_of(target, row)
    (0...target.maxx).map { |col| color_at(target, row, col) }
  end

  def erase_count(target)
    target.call_log.count { |(meth, _args)| meth == :erase }
  end

  # The names of the effects shown, top to bottom, without headers.
  def names_shown(target = window)
    target.rows.grep_v(/\A\u2500|\A\+|\A\z/).map { |row| row.split(/\s{2,}/).first }
  end

  describe '.format_duration' do
    it 'formats seconds as HH:MM:SS' do
      expect([0, 59, 3599, 14_579].map { |seconds| described_class.format_duration(seconds) })
        .to eq %w[00:00:00 00:00:59 00:59:59 04:02:59]
    end

    it 'never shows a negative time and lets very long times grow' do
      expect([described_class.format_duration(-5), described_class.format_duration(360_000)])
        .to eq %w[00:00:00 100:00:00]
    end
  end

  describe 'defaults' do
    it 'shows every category, in the order they are drawn' do
      expect(described_class.new(height, width, 0, 0).enabled_categories).to eq %i[debuffs cooldowns buffs custom spells]
      expect(described_class::DEFAULT_CATEGORIES).to eq described_class::DRAW_ORDER
    end

    it 'keeps CATEGORIES as the set of valid categories, whatever order they are drawn in' do
      expect(described_class::CATEGORIES).to match_array described_class::DRAW_ORDER
      expect(described_class::DRAW_ORDER).to eq %i[debuffs cooldowns buffs custom spells]
      expect(%i[spells buffs debuffs cooldowns custom].map { |name| described_class.category?(name) }).to all(be true)
    end

    it 'draws a header with a count of 0 for a category before any effects arrive' do
      window.redraw

      expect(window.rows.first).to eq header('Spells', 0)
      expect(window.rows.drop(1)).to all(be_empty)
    end
  end

  describe '#apply_effects' do
    it 'draws a row with the name and the time left for each effect, under the header' do
      window.apply_effects(:spells, [effect('Spirit Warding I', 14_579), effect('Strength', 12_007)])

      expect(window.rows.first(3)).to eq [header('Spells', 2),
                                          effect_row('Spirit Warding I', '04:02:59'),
                                          effect_row('Strength', '03:20:07')]
      expect(window.rows.drop(3)).to all(be_empty)
    end

    it 'replaces the category with the new list' do
      window.apply_effects(:spells, [effect('Strength', 600), effect('Blink', 300)])
      window.apply_effects(:spells, [effect('Iron Skin', 900)])

      expect(window.rows.first(2)).to eq [header('Spells', 1), effect_row('Iron Skin', '00:15:00')]
      expect(window.rows.drop(2)).to all(be_empty)
      expect(window.effects_for(:spells).map { |entry| entry[:name] }).to eq ['Iron Skin']
    end

    it 'clears a category when an empty list arrives, leaving the others, and keeps its header' do
      window.enabled_categories = %i[spells debuffs]
      window.apply_effects(:spells, [effect('Strength', 600)])
      window.apply_effects(:debuffs, [effect('Dizzy', 100)])
      window.apply_effects(:spells, [])

      expect(window.rows.first(4)).to eq [header('Debuffs', 1), effect_row('Dizzy', '00:01:40'), header('Spells', 0), '']
    end

    it 'ignores a category that does not exist' do
      expect { window.apply_effects(:potions, [effect('Strength', 600)]) }.not_to raise_error

      expect(window.rows.first).to eq header('Spells', 0)
      expect(window.rows.drop(1)).to all(be_empty)
    end

    it 'does not change what is shown by later changes to the list it was given' do
      list = [effect('Strength', 600)]
      window.apply_effects(:spells, list)
      list.clear

      window.redraw

      expect(window.rows[1]).to eq effect_row('Strength', '00:10:00')
    end

    it 'draws a row for an effect with a missing name or percent without failing' do
      expect { window.apply_effects(:spells, [{ id: '1', name: nil, percent: nil, end_time: now[0] + 50 }]) }
        .not_to raise_error

      expect(window.rows[1]).to eq effect_row('', '00:00:50')
    end
  end

  describe 'ordering' do
    it 'keeps the order the game sent, not sorted by time left' do
      window.apply_effects(:spells, [effect('Mind over Body', nil), effect('Iron Skin', 11_180),
                                     effect('Blink', 30), effect('Strength', 300)])

      expect(window.rows[1, 4]).to eq [effect_row('Mind over Body', '   Indef'),
                                       effect_row('Iron Skin', '03:06:20'),
                                       effect_row('Blink', '00:00:30'),
                                       effect_row('Strength', '00:05:00')]
    end

    it 'keeps the wire order regardless of time left (e.g. a spell circle stays grouped)' do
      window.apply_effects(:spells, [effect('Zeta', 300), effect('Alpha', 300), effect('Mid', 200)])

      expect(names_shown).to eq %w[Zeta Alpha Mid]
    end

    it 'keeps Indefinite effects in the order the game sent them' do
      window.apply_effects(:spells, [effect('Stance', nil), effect('Aura', nil), effect('Brief', 10)])

      expect(names_shown).to eq %w[Stance Aura Brief]
    end

    it 'keeps each category in its own wire order' do
      window.enabled_categories = %i[spells buffs]
      window.apply_effects(:buffs, [effect('Late buff', 900), effect('Early buff', 20)])
      window.apply_effects(:spells, [effect('Late spell', 800), effect('Early spell', 10)])

      expect(names_shown).to eq ['Late buff', 'Early buff', 'Late spell', 'Early spell']
    end

    it 'draws categories top to bottom as debuffs, cooldowns, buffs, custom, spells' do
      big = build_window(12, width, categories: %i[spells buffs cooldowns debuffs custom])
      big.apply_effects(:spells, [effect('Spell', 100)])
      big.apply_effects(:buffs, [effect('Buff', 100)])
      big.apply_effects(:cooldowns, [effect('Cooldown', 100)])
      big.apply_effects(:debuffs, [effect('Debuff', 100)])
      big.apply_effects(:custom, [effect('Custom', 100)])

      expect(big.rows.first(10)).to eq [header('Debuffs', 1), effect_row('Debuff', '00:01:40'),
                                        header('Cooldowns', 1), effect_row('Cooldown', '00:01:40'),
                                        header('Buffs', 1), effect_row('Buff', '00:01:40'),
                                        header('Custom', 1), effect_row('Custom', '00:01:40'),
                                        header('Spells', 1), effect_row('Spell', '00:01:40')]
      expect(big.rows.drop(10)).to all(be_empty)
    end
  end

  describe 'custom timers' do
    let(:custom_window) { build_window(10, width, categories: %i[custom spells]) }

    it 'are valid, drawn just before spells, and named Custom in their header' do
      expect(described_class.category?('custom')).to be true
      expect(described_class::DRAW_ORDER.each_cons(2)).to include(%i[custom spells])
      expect(described_class::CATEGORY_TITLES[:custom]).to eq 'Custom'
    end

    it 'have a header color of their own' do
      expect(described_class::HEADER_COLORS.fetch(:custom)).not_to eq described_class::HEADER_COLORS.values_at(*(described_class::CATEGORIES - [:custom])).first
      expect(described_class::HEADER_COLORS.values.uniq.size).to eq described_class::CATEGORIES.size
    end

    it 'draw under a Custom header, above the spells' do
      custom_window.apply_effects(:spells, [effect('Strength', 100)])
      custom_window.apply_effects(:custom, [effect('My Timer', 300)])

      expect(custom_window.rows.first(4)).to eq [header('Custom', 1), effect_row('My Timer', '00:05:00'),
                                                 header('Spells', 1), effect_row('Strength', '00:01:40')]
    end

    it 'draw the Custom header in the header color of the category' do
      custom_window.apply_effects(:custom, [])

      expect(color_at(custom_window, 0, 0)).to eq [described_class::HEADER_COLORS[:custom], nil]
    end

    it 'keep an empty Custom header with a count of 0' do
      custom_window.apply_effects(:custom, [])

      expect(custom_window.rows[0]).to eq header('Custom', 0)
    end

    it 'are dropped once their time is up, with the header count following' do
      custom_window.apply_effects(:custom, [effect('Short', 5), effect('Long', 600)])
      expect(custom_window.rows[0, 3]).to eq [header('Custom', 2), effect_row('Short', '00:00:05'), effect_row('Long', '00:10:00')]

      now[0] += 10

      expect(custom_window.tick).to be true
      expect(custom_window.rows[0, 3]).to eq [header('Custom', 1), effect_row('Long', '00:09:50'), header('Spells', 0)]
    end

    it 'are dropped when applied already expired' do
      custom_window.apply_effects(:custom, [effect('Gone', 0), effect('Past', -30)])

      expect(custom_window.rows[0]).to eq header('Custom', 0)
      expect(names_shown(custom_window)).to eq []
    end

    it 'stay while there is a fraction of a second left' do
      custom_window.apply_effects(:custom, [effect('Almost', 0.5)])

      expect(custom_window.rows[1]).to start_with('Almost')
    end

    it 'with no end time (Indefinite) always show' do
      custom_window.apply_effects(:custom, [effect('Forever', nil)])
      now[0] += 1_000_000

      custom_window.tick

      expect(custom_window.rows[0, 2]).to eq [header('Custom', 1), effect_row('Forever', '   Indef')]
    end

    it 'leave a game effect at 0 shown, in the ending colors' do
      custom_window.apply_effects(:spells, [effect('Strength', 5)])
      custom_window.apply_effects(:custom, [effect('Short', 5)])
      now[0] += 10
      custom_window.tick

      expect(custom_window.rows[0, 3]).to eq [header('Custom', 0), header('Spells', 1), effect_row('Strength', '00:00:00')]
    end

    it 'are kept by the window after they were hidden, as the tracker sends the whole list' do
      custom_window.apply_effects(:custom, [effect('Short', 5)])
      now[0] += 10
      custom_window.tick

      expect(custom_window.effects_for(:custom).map { |entry| entry[:name] }).to eq ['Short']
    end

    it 'are toggled with toggle_category, as .effects custom does' do
      expect(custom_window.toggle_category('custom')).to be false
      expect(custom_window.enabled_categories).to eq %i[spells]
      expect(custom_window.toggle_category('custom')).to be true
      expect(custom_window.enabled_categories).to eq %i[custom spells]
    end

    it 'are accepted in a comma-separated list of categories' do
      custom_window.enabled_categories = 'Custom, buffs'

      expect(custom_window.enabled_categories).to eq %i[buffs custom]
    end
  end

  describe 'Indefinite effects' do
    it 'show the Indefinite label in place of a countdown' do
      window.apply_effects(:spells, [effect('Rolling Krynch Stance', nil)])

      expect(window.rows[1]).to eq effect_row('Rolling Krynch Stance', '   Indef')
      expect(window.rows[1]).not_to match(/\d:\d/)
    end

    it 'do not redraw on a tick, as nothing about them moves' do
      window.apply_effects(:spells, [effect('Mind over Body', nil)])
      now[0] += 3_600

      expect(window.tick).to be false
    end
  end

  describe 'colors' do
    let(:normal) { described_class::DEFAULT_PALETTES.fetch(:normal) }
    let(:warning) { described_class::DEFAULT_PALETTES.fetch(:warning) }
    let(:ending) { described_class::DEFAULT_PALETTES.fetch(:ending) }

    it 'uses the normal colors with more than a minute left, and for Indefinite effects' do
      window.apply_effects(:spells, [effect('Long', 61, percent: 100), effect('Forever', nil, percent: 100)])

      expect(colors_of(window, 1)).to all(eq([normal.fg_fill, normal.bg_fill]))
      expect(colors_of(window, 2)).to all(eq([normal.fg_fill, normal.bg_fill]))
    end

    it 'uses the warning colors from a minute left, down to the last second' do
      window.apply_effects(:spells, [effect('At a minute', 60, percent: 100), effect('Last second', 1, percent: 100)])

      expect(colors_of(window, 1)).to all(eq([warning.fg_fill, warning.bg_fill]))
      expect(colors_of(window, 2)).to all(eq([warning.fg_fill, warning.bg_fill]))
    end

    it 'uses the ending colors, with a full bar, when the time is up' do
      window.apply_effects(:spells, [effect('Gone', -5, percent: 0)])

      expect(window.rows[1]).to eq effect_row('Gone', '00:00:00')
      expect(colors_of(window, 1)).to all(eq([ending.fg_fill, ending.bg_fill]))
    end

    it 'changes colors on a tick when an effect crosses into the last minute' do
      window.apply_effects(:spells, [effect('Fading', 63, percent: 100)])
      expect(color_at(window, 1, 0)).to eq [normal.fg_fill, normal.bg_fill]

      now[0] += 5
      window.tick

      expect(window.rows[1]).to eq effect_row('Fading', '00:00:58')
      expect(color_at(window, 1, 0)).to eq [warning.fg_fill, warning.bg_fill]
    end

    it 'takes colors a layout sets, keeping the ones it leaves out' do
      window.set_palette(:warning, fg: ['ffffff'], bg: ['aa0000'])
      window.apply_effects(:spells, [effect('Hot', 10, percent: 50)])

      expect(color_at(window, 1, 0)).to eq %w[ffffff aa0000]
      expect(color_at(window, 1, width - 1)).to eq [warning.fg_empty, warning.bg_empty]
    end
  end

  describe 'the fill bar' do
    let(:normal) { described_class::DEFAULT_PALETTES.fetch(:normal) }

    it 'fills a share of the row equal to the percent' do
      window.apply_effects(:spells, [effect('Half', 1_000, percent: 50)])

      expect(colors_of(window, 1).first(15)).to all(eq([normal.fg_fill, normal.bg_fill]))
      expect(colors_of(window, 1).drop(15)).to all(eq([normal.fg_empty, normal.bg_empty]))
    end

    it 'draws an empty bar for 0 percent' do
      window.apply_effects(:spells, [effect('Empty', 1_000, percent: 0)])

      expect(window.rows[1]).to eq effect_row('Empty', '00:16:40')
      expect(colors_of(window, 1)).to all(eq([normal.fg_empty, normal.bg_empty]))
    end

    it 'draws a full bar for 100 percent' do
      window.apply_effects(:spells, [effect('Full', 1_000, percent: 100)])

      expect(window.rows[1]).to eq effect_row('Full', '00:16:40')
      expect(colors_of(window, 1)).to all(eq([normal.fg_fill, normal.bg_fill]))
    end

    it 'keeps a percent outside 0..100 on the bar' do
      expect { window.apply_effects(:spells, [effect('Over', 1_000, percent: 140), effect('Under', 2_000, percent: -3)]) }
        .not_to raise_error

      expect(colors_of(window, 1)).to all(eq([normal.fg_fill, normal.bg_fill]))
      expect(colors_of(window, 2)).to all(eq([normal.fg_empty, normal.bg_empty]))
    end
  end

  describe 'enabled categories' do
    let(:height) { 10 }

    before do
      window.enabled_categories = %i[spells debuffs]
      window.apply_effects(:spells, [effect('Spell', 100)])
      window.apply_effects(:buffs, [effect('Buff', 200)])
      window.apply_effects(:debuffs, [effect('Debuff', 300)])
      window.apply_effects(:cooldowns, [effect('Cooldown', 400)])
    end

    it 'draws only the enabled categories, debuffs then spells' do
      expect(names_shown).to eq %w[Debuff Spell]
    end

    it 'draws the categories in a fixed order whatever order they were enabled in' do
      window.enabled_categories = %i[spells buffs cooldowns debuffs]

      expect(names_shown).to eq %w[Debuff Cooldown Buff Spell]
      expect(window.enabled_categories).to eq %i[debuffs cooldowns buffs spells]
    end

    it 'takes names as strings or a comma-separated list, and ignores unknown ones' do
      window.enabled_categories = 'cooldowns, Buffs ,potions'

      expect(window.enabled_categories).to eq %i[cooldowns buffs]
      expect(names_shown).to eq %w[Cooldown Buff]
    end

    it 'shows nothing, not even a header, when no category is enabled' do
      window.enabled_categories = []

      expect(window.rows).to all(be_empty)
    end

    describe '#show_category' do
      it 'draws the category at once, from the effects already received' do
        before = erase_count(window)

        expect(window.show_category(:buffs)).to be true

        expect(window.category_enabled?(:buffs)).to be true
        expect(names_shown).to eq %w[Debuff Buff Spell]
        expect(erase_count(window)).to be > before
      end

      it 'reports no change for a category already shown or not a category' do
        expect([window.show_category(:spells), window.show_category(:potions)]).to eq [false, false]
        expect(window.enabled_categories).to eq %i[debuffs spells]
      end

      it 'accepts a string name' do
        window.show_category('cooldowns')

        expect(window.category_enabled?(:cooldowns)).to be true
      end
    end

    describe '#hide_category' do
      it 'stops drawing the category at once, header included, and keeps its effects' do
        before = erase_count(window)

        expect(window.hide_category(:spells)).to be true

        expect(names_shown).to eq %w[Debuff]
        expect(window.rows.grep(/Spells/)).to be_empty
        expect(erase_count(window)).to be > before
        expect(window.effects_for(:spells).size).to eq 1
      end

      it 'reports no change for a category already hidden' do
        expect(window.hide_category(:buffs)).to be false
      end
    end

    describe '#toggle_category' do
      it 'turns a category on, then off, reporting whether it is shown' do
        expect(window.toggle_category(:cooldowns)).to be true
        expect(names_shown).to eq %w[Debuff Cooldown Spell]

        expect(window.toggle_category(:cooldowns)).to be false
        expect(names_shown).to eq %w[Debuff Spell]
      end

      it 'returns nil for something that is not a category' do
        expect(window.toggle_category(:potions)).to be_nil
      end
    end

    it 'does not redraw for an event about a category that is not shown' do
      before = erase_count(window)

      window.apply_effects(:cooldowns, [effect('Other cooldown', 50)])

      expect(erase_count(window)).to eq before
    end
  end

  describe 'category headers' do
    it 'head a single shown category too, with its name and how many effects it has' do
      window.apply_effects(:spells, [effect('Strength', 100)])

      expect(window.rows.first(2)).to eq [header('Spells', 1), effect_row('Strength', '00:01:40')]
    end

    it 'head each shown category in the order they are drawn' do
      window.enabled_categories = %i[spells debuffs]
      window.apply_effects(:spells, [effect('Strength', 100), effect('Blink', 50)])
      window.apply_effects(:debuffs, [effect('Dizzy', 20)])

      expect(window.rows).to eq [header('Debuffs', 1),
                                 effect_row('Dizzy', '00:00:20'),
                                 header('Spells', 2),
                                 effect_row('Strength', '00:01:40'),
                                 effect_row('Blink', '00:00:50'),
                                 '']
    end

    it 'are drawn for a shown category with no effects, with a count of 0' do
      window.enabled_categories = %i[spells buffs]
      window.apply_effects(:spells, [effect('Strength', 100)])

      expect(window.rows.first(3)).to eq [header('Buffs', 0), header('Spells', 1), effect_row('Strength', '00:01:40')]
    end

    it 'are all drawn when every category is shown and only one has effects' do
      every = build_window(8, width, categories: described_class::CATEGORIES)
      every.apply_effects(:spells, [effect('Strength', 100)])

      expect(every.rows.first(6)).to eq [header('Debuffs', 0), header('Cooldowns', 0), header('Buffs', 0),
                                         header('Custom', 0), header('Spells', 1), effect_row('Strength', '00:01:40')]
      expect(every.rows.drop(6)).to all(be_empty)
    end

    it 'show the count again when the list changes' do
      window.apply_effects(:spells, [effect('Strength', 100)])
      window.apply_effects(:spells, [])

      expect(window.rows.first).to eq header('Spells', 0)
    end

    it 'are colored for their category and keep the terminal background' do
      window.enabled_categories = %i[spells debuffs]

      expect(color_at(window, 0, 0)).to eq [described_class::HEADER_COLORS[:debuffs], nil]
      expect(color_at(window, 1, 0)).to eq [described_class::HEADER_COLORS[:spells], nil]
    end
  end

  describe 'long names' do
    it 'are cut with an ellipsis to one row, the time column staying aligned' do
      window.apply_effects(:spells, [effect('Elemental Defense III Greater Edition', 100),
                                     effect('Brace', 200)])

      long, short = window.rows[1, 2]
      expect(long).to eq "Elemental Defense II\u2026 00:01:40"
      expect(long.length).to eq width
      expect(short.length).to eq width
      expect(long.index('00:01:40')).to eq short.index('00:03:20')
      expect(window.rows.drop(3)).to all(be_empty)
    end

    it 'leave a name that exactly fits alone' do
      name = 'N' * (width - 9)
      window.apply_effects(:spells, [effect(name, 100)])

      expect(window.rows[1]).to eq "#{name} 00:01:40"
    end

    it 'are cut further in a narrow window' do
      narrow = build_window(3, 12)
      narrow.apply_effects(:spells, [effect('Strength', 100)])

      expect(narrow.rows[1]).to eq "St\u2026 00:01:40"
    end

    it 'leave only the time in a window too narrow for a name' do
      tiny = build_window(3, 6)

      expect { tiny.apply_effects(:spells, [effect('Strength', 100)]) }.not_to raise_error

      expect(tiny.rows[1].length).to be <= 6
    end
  end

  describe 'a window shorter than the list' do
    let(:height) { 4 }

    it 'shows the first rows in wire order and says how many more effects there are' do
      window.apply_effects(:spells, (1..7).map { |n| effect("Spell #{n}", n * 100) })

      expect(window.rows).to eq [header('Spells', 7),
                                 effect_row('Spell 1', '00:01:40'),
                                 effect_row('Spell 2', '00:03:20'),
                                 '+5 more']
    end

    it 'shows all rows when they just fit' do
      window.apply_effects(:spells, (1..3).map { |n| effect("Spell #{n}", n * 100) })

      expect(window.rows).to eq [header('Spells', 3),
                                 effect_row('Spell 1', '00:01:40'),
                                 effect_row('Spell 2', '00:03:20'),
                                 effect_row('Spell 3', '00:05:00')]
    end

    it 'keeps the header of a category whose effects are cut, with its full count' do
      window.enabled_categories = %i[spells debuffs]
      window.apply_effects(:debuffs, [effect('Debuff 1', 100)])
      window.apply_effects(:spells, [effect('Spell 1', 100), effect('Spell 2', 200)])

      expect(window.rows).to eq [header('Debuffs', 1), effect_row('Debuff 1', '00:01:40'), header('Spells', 2), '+2 more']
    end

    it 'draws an empty category at the end when everything fits' do
      window.enabled_categories = %i[spells debuffs]
      window.apply_effects(:debuffs, [effect('Debuff 1', 100), effect('Debuff 2', 200)])

      expect(window.rows).to eq [header('Debuffs', 2), effect_row('Debuff 1', '00:01:40'),
                                 effect_row('Debuff 2', '00:03:20'), header('Spells', 0)]
    end

    it 'counts only effects in "+N more", not the headers left out' do
      window.enabled_categories = %i[spells buffs debuffs]
      window.apply_effects(:debuffs, [effect('Debuff 1', 100), effect('Debuff 2', 200), effect('Debuff 3', 300)])

      expect(window.rows).to eq [header('Debuffs', 3), effect_row('Debuff 1', '00:01:40'),
                                 effect_row('Debuff 2', '00:03:20'), '+1 more']
    end

    it 'cuts empty headers without a "+N more" note when no effect is left out' do
      every = build_window(3, width, categories: described_class::CATEGORIES)

      expect(every.rows).to eq [header('Debuffs', 0), header('Cooldowns', 0), header('Buffs', 0)]
    end

    it 'shows the first effect when only one row is available' do
      one_row = build_window(1, width, categories: %i[spells debuffs])
      one_row.apply_effects(:spells, [effect('Strength', 100), effect('Blink', 50)])
      one_row.apply_effects(:debuffs, [effect('Dizzy', 20)])

      expect(one_row.rows).to eq [effect_row('Dizzy', '00:00:20')]
    end

    it 'shows the first header when only one row is available and there are no effects' do
      one_row = build_window(1, width, categories: described_class::CATEGORIES)

      expect(one_row.rows).to eq [header('Debuffs', 0)]
    end

    it 'does not fail when the effects keep coming' do
      expect { 30.times { |n| window.apply_effects(:spells, (0..n).map { |m| effect("S#{m}", m + 1) }) } }
        .not_to raise_error
      expect(window.rows.length).to eq 4
    end
  end

  describe '#tick' do
    before { window.apply_effects(:spells, [effect('Strength', 100), effect('Blink', 40)]) }

    it 'counts the displayed time down with the clock, with no new event' do
      expect(window.rows[1, 2]).to eq [effect_row('Strength', '00:01:40'), effect_row('Blink', '00:00:40')]

      now[0] += 3

      expect(window.tick).to be true
      expect(window.rows[1, 2]).to eq [effect_row('Strength', '00:01:37'), effect_row('Blink', '00:00:37')]
    end

    it 'returns false and draws nothing when no displayed value changed' do
      before = erase_count(window)
      now[0] += 0.1

      expect(window.tick).to be false
      expect(erase_count(window)).to eq before
    end

    it 'redraws once per displayed second' do
      now[0] += 1
      expect(window.tick).to be true
      expect(window.tick).to be false

      now[0] += 1
      expect(window.tick).to be true
    end

    it 'reads the clock once per tick' do
      readings = 0
      allow(clock).to receive(:server_now) { (readings += 1) && now[0] }

      window.tick

      expect(readings).to eq 1
    end

    it 'shows an effect that runs out in the ending colors until the game drops it' do
      now[0] += 41
      window.tick

      expect(window.rows[2]).to eq effect_row('Blink', '00:00:00')
      expect(color_at(window, 2, 0)).to eq described_class::DEFAULT_PALETTES.fetch(:ending).to_a.values_at(0, 2)
    end

    it 'has nothing more to draw on a tick right after a category was shown' do
      window.apply_effects(:buffs, [effect('Buff', 30)])
      window.show_category(:buffs)
      before = erase_count(window)

      expect(window.tick).to be false
      expect(erase_count(window)).to eq before
    end

    it 'works from the server time, which is behind the clock by the server offset' do
      clock.server_time_offset = 10.0
      window.redraw

      expect(window.rows[2]).to eq effect_row('Blink', '00:00:50')
    end

    it 'reads the real time when it has no clock' do
      clockless = described_class.new(3, width, 0, 0)
      clockless.enabled_categories = %i[spells]
      clockless.apply_effects(:spells, [{ id: '1', name: 'Real', percent: 10, end_time: Time.now.to_f + 3_600 }])

      expect(clockless.rows[1]).to match(/\AReal +01:00:00\z|\AReal +00:59:59\z/)
    end
  end

  describe '#repaint' do
    it 'draws the same rows again from what the window holds' do
      window.apply_effects(:spells, [effect('Strength', 100), effect('Blink', 50)])
      shown = (0...height).map { |row| [window.row(row), colors_of(window, row)] }
      window.erase

      window.repaint

      expect((0...height).map { |row| [window.row(row), colors_of(window, row)] }).to eq shown
    end

    it 'does not read the clock' do
      window.apply_effects(:spells, [effect('Strength', 100)])
      allow(clock).to receive(:server_now).and_raise('read the clock')

      expect { window.repaint }.not_to raise_error
    end

    it 'fits the rows to a new window width' do
      window.apply_effects(:spells, [effect('Elemental Defense III', 100)])
      window.resize(height, 20)

      window.repaint

      expect(window.rows[1]).to eq "Elemental\u2026  00:01:40"
    end
  end

  describe 'drawing errors' do
    it 'are logged instead of raised' do
      allow(window).to receive(:erase).and_raise('curses failed')
      expect(ProfanityLog).to receive(:write).with('effects_window', /curses failed/, backtrace: anything)

      expect { window.apply_effects(:spells, [effect('Strength', 100)]) }.not_to raise_error
    end
  end

  describe 'custom colors for single effects' do
    let(:normal) { described_class::DEFAULT_PALETTES.fetch(:normal) }
    let(:warning) { described_class::DEFAULT_PALETTES.fetch(:warning) }
    let(:ending) { described_class::DEFAULT_PALETTES.fetch(:ending) }

    # The colors of the first effect row, which every example fills with a
    # whole bar (100 percent) unless it says otherwise.
    def row_colors(row = 1) = colors_of(window, row).uniq

    describe 'by id' do
      it 'colors an effect whose id is exactly the rule id, and no other' do
        window.add_color_rule(id: '401', fg: ['ff0000'], bg: ['550000', '220000'])
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100, id: '401'),
                                       effect('Other', 600, percent: 100, id: '4010'),
                                       effect('Third', 600, percent: 100, id: '40')])

        expect(row_colors(1)).to eq [%w[ff0000 550000]]
        expect(row_colors(2)).to eq [[normal.fg_fill, normal.bg_fill]]
        expect(row_colors(3)).to eq [[normal.fg_fill, normal.bg_fill]]
      end

      it 'matches large numeric ids as the game sends them' do
        window.add_color_rule(id: '194442916', bg: ['00aa00'])
        window.apply_effects(:spells, [effect('Hallowed Reprisal', 600, percent: 100, id: '194442916')])

        expect(row_colors).to eq [[normal.fg_fill, '00aa00']]
      end

      it 'takes the id as a number too' do
        window.add_color_rule(id: 401, bg: ['00aa00'])
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100, id: '401')])

        expect(row_colors).to eq [[normal.fg_fill, '00aa00']]
      end
    end

    describe 'by id range' do
      before do
        window.add_color_rule(id_min: 400, id_max: 499, bg: ['00aaff'])
      end

      it 'colors ids inside the range, both ends included' do
        window.apply_effects(:spells, %w[400 450 499 399 500].map { |id| effect("S#{id}", 600, percent: 100, id: id) })

        expect((1..5).map { |row| row_colors(row).first.last })
          .to eq ['00aaff', '00aaff', '00aaff', normal.bg_fill, normal.bg_fill]
      end

      it 'never matches an id that is not a number' do
        window.apply_effects(:spells, ['abc', '4x0', '', '-450', '4 50'].map { |id| effect("S#{id}", 600, percent: 100, id: id) })

        expect((1..5).map { |row| row_colors(row).first.last }).to all(eq(normal.bg_fill))
      end

      it 'never matches an effect with no id' do
        window.apply_effects(:spells, [{ name: 'No id', percent: 100, end_time: now[0] + 600 }])

        expect(row_colors.first.last).to eq normal.bg_fill
      end

      it 'accepts a range with only one end' do
        window.clear_color_rules
        window.add_color_rule(id_min: '1000', bg: ['aa00aa'])
        window.apply_effects(:spells, %w[999 1000 99999].map { |id| effect("S#{id}", 600, percent: 100, id: id) })

        expect((1..3).map { |row| row_colors(row).first.last }).to eq [normal.bg_fill, 'aa00aa', 'aa00aa']
      end
    end

    describe 'by name' do
      it 'matches the whole name, ignoring case' do
        window.add_color_rule(name: 'strength', fg: ['ffd700'])
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100), effect('STRENGTH', 600, percent: 100),
                                       effect('Strength II', 600, percent: 100), effect('Greater Strength', 600, percent: 100)])

        expect((1..4).map { |row| row_colors(row).first.first }).to eq ['ffd700', 'ffd700', normal.fg_fill, normal.fg_fill]
      end
    end

    describe 'by name pattern' do
      it 'matches a regular expression found in the name, ignoring case' do
        window.add_color_rule(name_pattern: 'Sign of .*', bg: ['884400', '221100'])
        window.apply_effects(:spells, [effect('Sign of Haste', 600, percent: 100), effect('sign of swords', 600, percent: 100),
                                       effect('Haste', 600, percent: 100)])

        expect((1..3).map { |row| row_colors(row).first.last }).to eq ['884400', '884400', normal.bg_fill]
      end

      it 'supports alternatives and anchors' do
        window.add_color_rule(name_pattern: '^Spirit Warding (I|II)$', bg: ['0000ff'])
        window.apply_effects(:spells, ['Spirit Warding I', 'Spirit Warding II', 'Spirit Warding III']
                                        .map { |name| effect(name, 600, percent: 100) })

        expect((1..3).map { |row| row_colors(row).first.last }).to eq ['0000ff', '0000ff', normal.bg_fill]
      end

      it 'ignores a rule whose pattern does not compile, logging it, and colors as before' do
        expect(ProfanityLog).to receive(:write).with('effects_window', /Ignoring color rule.*not a valid regexp/)

        expect(window.add_color_rule(name_pattern: '(unclosed', bg: ['ff0000'])).to be false

        window.apply_effects(:spells, [effect('(unclosed', 600, percent: 100)])
        expect(window.color_rules).to be_empty
        expect(row_colors).to eq [[normal.fg_fill, normal.bg_fill]]
      end
    end

    describe 'a rule that cannot be used' do
      before { allow(ProfanityLog).to receive(:write) }

      it 'is skipped when it names nothing to match' do
        expect(window.add_color_rule(bg: ['ff0000'])).to be false
        expect(window.add_color_rule(id: ' ', name: '', bg: ['ff0000'])).to be false
        expect(window.color_rules).to be_empty
      end

      it 'is skipped when a bound is not a whole number or the range is empty' do
        expect([window.add_color_rule(id_min: 'abc'), window.add_color_rule(id_max: '4.5'),
                window.add_color_rule(id_min: 500, id_max: 400)]).to eq [false, false, false]
        expect(window.color_rules).to be_empty
      end

      it 'is skipped when it uses a matcher that does not exist' do
        expect(window.add_color_rule(color: 'red')).to be false
      end

      it 'does not stop later rules from working' do
        window.add_color_rule(name_pattern: '(unclosed')
        window.add_color_rule(name: 'Strength', bg: ['00aa00'])
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100)])

        expect(row_colors.first.last).to eq '00aa00'
      end
    end

    describe 'with several rules' do
      it 'uses the first one added that matches' do
        window.add_color_rule(id_min: 400, id_max: 499, bg: ['111111'])
        window.add_color_rule(name: 'Strength', bg: ['222222'])
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100, id: '401'),
                                       effect('Strength', 600, percent: 100, id: '900')])

        expect(row_colors(1).first.last).to eq '111111'
        expect(row_colors(2).first.last).to eq '222222'
      end

      it 'uses the other when the order is the other way round' do
        window.add_color_rule(name: 'Strength', bg: ['222222'])
        window.add_color_rule(id_min: 400, id_max: 499, bg: ['111111'])
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100, id: '401')])

        expect(row_colors.first.last).to eq '222222'
      end

      it 'needs every matcher of one rule to match' do
        window.add_color_rule(id_min: 400, id_max: 499, name: 'Strength', bg: ['333333'])
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100, id: '401'),
                                       effect('Strength', 600, percent: 100, id: '900'),
                                       effect('Blink', 600, percent: 100, id: '401')])

        expect((1..3).map { |row| row_colors(row).first.last }).to eq ['333333', normal.bg_fill, normal.bg_fill]
      end
    end

    describe 'its colors' do
      it 'leave the normal colors in place where the rule gives none' do
        window.add_color_rule(name: 'Half', bg: ['550000'])
        window.apply_effects(:spells, [effect('Half', 600, percent: 50)])

        expect(color_at(window, 1, 0)).to eq [normal.fg_fill, '550000']
        expect(color_at(window, 1, width - 1)).to eq [normal.fg_empty, normal.bg_empty]
      end

      it 'color the filled and the empty part of the bar separately' do
        window.add_color_rule(name: 'Half', fg: ['ffffff', 'cccccc'], bg: ['550000', '220000'])
        window.apply_effects(:spells, [effect('Half', 600, percent: 50)])

        expect(color_at(window, 1, 0)).to eq %w[ffffff 550000]
        expect(color_at(window, 1, width - 1)).to eq %w[cccccc 220000]
      end

      it 'can be the terminal default' do
        window.add_color_rule(name: 'Half', bg: [nil])
        window.apply_effects(:spells, [effect('Half', 600, percent: 100)])

        expect(color_at(window, 1, 0)).to eq [normal.fg_fill, nil]
      end

      it 'follow a change to the normal colors for what the rule leaves out' do
        window.add_color_rule(name: 'Half', fg: ['ffffff'])
        window.set_palette(:normal, bg: ['123456'])
        window.apply_effects(:spells, [effect('Half', 600, percent: 100)])

        expect(color_at(window, 1, 0)).to eq %w[ffffff 123456]
      end

      it 'apply to an Indefinite effect, which is never in the warning colors' do
        window.add_color_rule(name: 'Stance', bg: ['00aa00'])
        window.apply_effects(:spells, [effect('Stance', nil, percent: 100)])

        expect(row_colors.first.last).to eq '00aa00'
      end

      it 'keep the name and time as they were' do
        window.add_color_rule(name: 'Strength', bg: ['00aa00'])
        window.apply_effects(:spells, [effect('Strength', 600)])

        expect(window.rows[1]).to eq effect_row('Strength', '00:10:00')
      end
    end

    describe 'with the warning and ending colors' do
      before { window.add_color_rule(name: 'Strength', fg: ['ff0000'], bg: ['550000']) }

      it 'show the custom colors with more than a minute left' do
        window.apply_effects(:spells, [effect('Strength', 61, percent: 100)])

        expect(row_colors).to eq [%w[ff0000 550000]]
      end

      it 'give way to the warning colors from a minute left' do
        window.apply_effects(:spells, [effect('Strength', 60, percent: 100)])

        expect(row_colors).to eq [[warning.fg_fill, warning.bg_fill]]
      end

      it 'give way to the ending colors when the time is up' do
        window.apply_effects(:spells, [effect('Strength', -1, percent: 100)])

        expect(row_colors).to eq [[ending.fg_fill, ending.bg_fill]]
      end

      it 'change over on a tick as the time runs down' do
        window.apply_effects(:spells, [effect('Strength', 70, percent: 100)])
        expect(row_colors).to eq [%w[ff0000 550000]]

        now[0] += 15
        expect(window.tick).to be true
        expect(row_colors).to eq [[warning.fg_fill, warning.bg_fill]]

        now[0] += 60
        window.tick
        expect(row_colors).to eq [[ending.fg_fill, ending.bg_fill]]
      end
    end

    describe 'with no rules' do
      it 'colors every effect as before' do
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100, id: '401')])

        expect(window.color_rules).to be_empty
        expect(row_colors).to eq [[normal.fg_fill, normal.bg_fill]]
      end
    end

    describe 'changing the rules' do
      it 'recolors the effects already shown at once' do
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100)])
        before = erase_count(window)

        window.add_color_rule(name: 'Strength', bg: ['00aa00'])

        expect(row_colors.first.last).to eq '00aa00'
        expect(erase_count(window)).to be > before
      end

      it 'goes back to the normal colors when the rules are cleared' do
        window.add_color_rule(name: 'Strength', bg: ['00aa00'])
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100)])

        window.clear_color_rules

        expect(window.color_rules).to be_empty
        expect(row_colors).to eq [[normal.fg_fill, normal.bg_fill]]
      end

      it 'keeps the effects that arrive later colored' do
        window.add_color_rule(name: 'Strength', bg: ['00aa00'])
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100)])
        window.apply_effects(:spells, [effect('Blink', 600, percent: 100), effect('Strength', 600, percent: 100)])

        expect([row_colors(1).first.last, row_colors(2).first.last]).to eq [normal.bg_fill, '00aa00']
      end

      it 'colors rows after a repaint at a new width' do
        window.add_color_rule(name: 'Strength', bg: ['00aa00'])
        window.apply_effects(:spells, [effect('Strength', 600, percent: 100)])
        window.resize(height, 20)

        window.repaint

        expect(row_colors.first.last).to eq '00aa00'
        expect(window.maxx).to eq 20
      end
    end
  end
end

RSpec.describe 'effects window in a layout' do
  let(:now) { [1_000_000.0] }
  let(:clock) { Clock.new(now: -> { Time.at(now[0]) }) }
  let(:window_manager) { WindowManager.new(clock: clock) }
  # Shows spells only, so row 0 is the Spells header and the effects follow
  let(:effects_element) { "<window class='effects' top='0' left='0' height='6' width='30' categories='spells'/>" }
  # Shows every category (the default)
  let(:all_categories_element) { "<window class='effects' top='0' left='0' height='6' width='30'/>" }
  let(:pairs) { Hash.new { |hash, key| hash[key] = hash.size + 1 } }

  before do
    allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, bg| pairs[[fg, bg]] }
  end

  def load_layout(*elements, id: 'effects_test')
    LAYOUT[id] = REXML::Document.new("<layout>#{elements.join}</layout>").root
    window_manager.load_layout(id)
  end

  def effect(name, seconds, percent: 50)
    { id: name, name: name, percent: percent, end_time: seconds && (now[0] + seconds) }
  end

  describe 'the effects registry' do
    it 'starts empty and is not shared between managers' do
      expect(window_manager.effects).to eq({})
      expect(window_manager.effects).not_to equal(WindowManager.new.effects)
    end

    it 'holds the window under "effects" when the element has no value' do
      load_layout(effects_element)

      expect(window_manager.effects.keys).to eq ['effects']
      expect(window_manager.effects['effects']).to be_a(EffectsWindow)
    end

    it 'holds the window under the value of its element' do
      load_layout("<window class='effects' top='0' left='0' height='6' width='30' value='buffs_panel'/>")

      expect(window_manager.effects.keys).to eq ['buffs_panel']
    end

    it 'gives the window the manager clock, and sizes it from the element' do
      load_layout("<window class='effects' top='2' left='5' height='8' width='24'/>")
      window = window_manager.effects['effects']

      expect([window.clock, window.maxy, window.maxx, window.begy, window.begx])
        .to eq [clock, 8, 24, 2, 5]
    end

    it 'is emptied and rebuilt by a layout reload, closing a window the new layout drops' do
      load_layout(effects_element)
      old = window_manager.effects['effects']

      load_layout("<window class='text' top='0' left='0' height='4' width='30' value='main'/>")

      expect(window_manager.effects).to eq({})
      expect(EffectsWindow.list).to be_empty
      expect(old.call_log.map(&:first)).to include(:close)
    end

    it 'keeps its window, with its effects and chosen categories, when the next layout has an effects window of the same key' do
      load_layout(all_categories_element)
      old = window_manager.effects['effects']
      old.apply_effects(:spells, [effect('Strength', 100)])
      old.hide_category(:cooldowns)

      load_layout(all_categories_element)

      expect(window_manager.effects['effects']).to equal(old)
      expect(EffectsWindow.list).to eq [old]
      expect(old.rows.grep(/\AStrength/)).not_to be_empty
      expect(old.enabled_categories).to eq %i[debuffs buffs custom spells]
      expect(old.call_log.map(&:first)).not_to include(:close)
    end

    it 'builds a new window for a different key' do
      load_layout(effects_element)
      old = window_manager.effects['effects']

      load_layout("<window class='effects' top='0' left='0' height='6' width='30' value='other'/>")

      expect(window_manager.effects['other']).not_to equal(old)
      expect(window_manager.effects.keys).to eq ['other']
      expect(EffectsWindow.list.size).to eq 1
    end

    it 'resolves claim_window for the effects registry outside a layout load' do
      expect(window_manager.claim_window(:effects, 'effects', EffectsWindow)).to be_nil
    end
  end

  describe 'layout attributes' do
    it 'choose the categories drawn' do
      load_layout("<window class='effects' top='0' left='0' height='6' width='30' categories='buffs, cooldowns'/>")

      expect(window_manager.effects['effects'].enabled_categories).to eq %i[cooldowns buffs]
    end

    it 'show every category without a categories attribute' do
      load_layout(all_categories_element)

      expect(window_manager.effects['effects'].enabled_categories).to eq %i[debuffs cooldowns buffs custom spells]
    end

    it 'set the colors of each kind of row, keeping the defaults they leave out' do
      load_layout(<<~XML)
        <window class='effects' top='0' left='0' height='6' width='30'
                fg='ffffff' bg='111111,222222' warn_bg='333333' end_fg='nil,eeeeee' end_bg='444444'/>
      XML
      window = window_manager.effects['effects']
      defaults = EffectsWindow::DEFAULT_PALETTES

      expect(window.palette(:normal).to_a).to eq ['ffffff', defaults[:normal].fg_empty, '111111', '222222']
      expect(window.palette(:warning).to_a).to eq(defaults[:warning].to_a.tap { |colors| colors[2] = '333333' })
      expect(window.palette(:ending).to_a).to eq [nil, 'eeeeee', '444444', defaults[:ending].bg_empty]
    end

    it 'draw with the chosen colors' do
      load_layout("<window class='effects' top='0' left='0' height='6' width='30' categories='spells' bg='111111,222222'/>")
      window = window_manager.effects['effects']

      window.apply_effects(:spells, [effect('Half', 1_000, percent: 50)])

      expect([pairs.key((window.attrs_at(1, 0) & Curses::A_COLOR) >> 8),
              pairs.key((window.attrs_at(1, 29) & Curses::A_COLOR) >> 8)])
        .to eq [['9BA2B2', '111111'], ['9BA2B2', '222222']]
    end
  end

  describe 'effectColor children' do
    let(:normal) { EffectsWindow::DEFAULT_PALETTES.fetch(:normal) }
    let(:window) { window_manager.effects['effects'] }
    let(:event_bus) { EventBus.new.tap { |bus| window_manager.subscribe_to_events(bus) } }
    let(:window_with_rules) do
      <<~XML
        <window class='effects' top='0' left='0' height='8' width='30' categories='spells'>
          <effectColor id='401' fg='ff0000' bg='550000,220000'/>
          <effectColor id_min='500' id_max='599' bg='00aaff,003344'/>
          <effectColor name='Strength' fg='ffd700'/>
          <effectColor name_pattern='Sign of .*' bg='884400,221100'/>
        </window>
      XML
    end

    def send_effects(*effects)
      event_bus.emit(:effects_update, category: :spells, effects: effects)
    end

    def effect_with_id(name, id)
      effect(name, 600, percent: 100).merge(id: id)
    end

    def bar_color(row)
      pairs.key((window.attrs_at(row, 0) & Curses::A_COLOR) >> 8)
    end

    it 'builds a rule for each child, in the order written' do
      load_layout(window_with_rules)

      expect(window.color_rules.size).to eq 4
      expect(window.color_rules.map(&:fg)).to eq [['ff0000'], nil, ['ffd700'], nil]
      expect(window.color_rules.map(&:bg)).to eq [%w[550000 220000], %w[00aaff 003344], nil, %w[884400 221100]]
    end

    it 'colors the effects each kind of rule matches' do
      load_layout(window_with_rules)
      event_bus
      send_effects(effect_with_id('Spirit Defense', '401'), effect_with_id('Iron Skin', '550'),
                   effect_with_id('Strength', '509 x'), effect_with_id('Sign of Haste', '1'),
                   effect_with_id('Blink', '1215'))

      expect((1..5).map { |row| bar_color(row) })
        .to eq [%w[ff0000 550000], [normal.fg_fill, '00aaff'], ['ffd700', normal.bg_fill],
                [normal.fg_fill, '884400'], [normal.fg_fill, normal.bg_fill]]
    end

    it 'leaves the warning colors on an effect that is about to run out' do
      load_layout(window_with_rules)
      event_bus
      send_effects(effect('Strength', 30, percent: 100).merge(id: '1'))

      expect(bar_color(1)).to eq EffectsWindow::DEFAULT_PALETTES.fetch(:warning).to_a.values_at(0, 2)
    end

    it 'skips a child that cannot be used and keeps the others' do
      allow(ProfanityLog).to receive(:write)
      load_layout(<<~XML)
        <window class='effects' top='0' left='0' height='8' width='30' categories='spells'>
          <effectColor name_pattern='(unclosed' bg='ff0000'/>
          <effectColor bg='ff0000'/>
          <effectColor id_min='x' bg='ff0000'/>
          <effectColor name='Strength' bg='00aa00'/>
        </window>
      XML

      expect(window.color_rules.map { |rule| rule.bg.first }).to eq ['00aa00']
      expect(ProfanityLog).to have_received(:write).with('effects_window', /Ignoring color rule/).exactly(3).times
    end

    it 'ignores children that are not effectColor' do
      load_layout(<<~XML)
        <window class='effects' top='0' left='0' height='8' width='30' categories='spells'>
          <somethingElse name='Strength' bg='ff0000'/>
          <effectColor name='Strength' bg='00aa00'/>
        </window>
      XML

      expect(window.color_rules.size).to eq 1
    end

    it 'colors as before when the element has no effectColor children' do
      load_layout(effects_element)

      expect(window.color_rules).to be_empty
    end

    it 'gives a window kept across a layout reload exactly the rules of the new layout' do
      load_layout(window_with_rules)
      old = window

      load_layout("<window class='effects' top='0' left='0' height='8' width='30' categories='spells'>" \
                  "<effectColor name='Blink' bg='00aa00'/></window>")
      expect(window).to equal(old)
      expect(window.color_rules.map { |rule| rule.bg.first }).to eq ['00aa00']

      load_layout(effects_element)
      expect(window).to equal(old)
      expect(window.color_rules).to be_empty
    end

    it 'recolors a kept window at once on reload' do
      load_layout(effects_element)
      event_bus
      send_effects(effect_with_id('Strength', '1'))
      expect(bar_color(1)).to eq [normal.fg_fill, normal.bg_fill]

      load_layout("<window class='effects' top='0' left='0' height='8' width='30' categories='spells'>" \
                  "<effectColor name='Strength' bg='00aa00'/></window>")

      expect(bar_color(1)).to eq [normal.fg_fill, '00aa00']
    end

    it 'reads the rules from the cached copy of a layout, as loaded from the settings file' do
      require_relative '../../../lib/settings_loader'
      root = REXML::Document.new("<layout>#{window_with_rules}</layout>").root
      LAYOUT['cached_effects'] = SettingsLoader.rexml_to_cached(root)

      window_manager.load_layout('cached_effects')

      expect(window.color_rules.size).to eq 4
    end
  end

  describe 'events from the parser' do
    let(:event_bus) { EventBus.new.tap { |bus| window_manager.subscribe_to_events(bus) } }
    let(:window) { window_manager.effects['effects'] }

    before do
      load_layout(effects_element)
      event_bus
    end

    it 'fills the window from an :effects_update and replaces the list on the next one' do
      event_bus.emit(:effects_update, category: :spells,
                                      effects: [effect('Strength', 12_007), effect('Blink', 40)])
      expect(window.rows.first).to start_with("\u2500\u2500 Spells ")
      expect(window.rows[1, 2]).to eq ["Strength#{' ' * 13} 03:20:07", "Blink#{' ' * 16} 00:00:40"]

      event_bus.emit(:effects_update, category: :spells, effects: [effect('Iron Skin', 90)])
      expect(window.rows[1]).to eq "Iron Skin#{' ' * 12} 00:01:30"
      expect(window.rows.drop(2)).to all(be_empty)
    end

    it 'sends every effects window the update' do
      load_layout(effects_element,
                  "<window class='effects' top='7' left='0' height='6' width='30' value='second'/>")
      second = window_manager.effects['second']

      event_bus.emit(:effects_update, category: :spells, effects: [effect('Strength', 100)])

      expect(window_manager.effects['effects'].rows[1]).to start_with('Strength')
      expect(second.rows.grep(/\AStrength/)).not_to be_empty
    end

    it 'counts down on tick without further events' do
      event_bus.emit(:effects_update, category: :spells, effects: [effect('Strength', 100)])
      now[0] += 10

      expect(window.tick).to be true
      expect(window.rows[1]).to end_with('00:01:30')
    end

    it 'fills the Custom section from a :custom update and hides a timer that runs out on tick' do
      window.show_category(:custom)
      event_bus.emit(:effects_update, category: :custom, effects: [effect('Pot', 30), effect('Keep', nil)])
      expect(window.rows.grep(/\A\u2500\u2500 Custom /).size).to eq 1
      expect(window.rows.grep(/\A(Pot|Keep)/).size).to eq 2

      now[0] += 40
      window.tick

      expect(window.rows.grep(/\A(Pot|Keep)/).map { |row| row[0, 4] }).to eq ['Keep']
    end

    it 'ticks every window in the registry' do
      event_bus.emit(:effects_update, category: :spells, effects: [effect('Strength', 100)])
      now[0] += 2

      expect(window_manager.effects.each_value.map(&:tick)).to eq [true]
    end
  end
end
