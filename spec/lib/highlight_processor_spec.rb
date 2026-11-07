# frozen_string_literal: true

# Tests HighlightProcessor.apply_highlights: every occurrence of a highlight
# pattern becomes a color region, and patterns that can match the empty
# string (which user highlights often can) never stall the scan.
#
# And HighlightProcessor.render_colored_text: which region's color each
# segment is drawn in, a link's color yielding to every other color.

require 'timeout'

RSpec.describe HighlightProcessor do
  # A regression here would hang forever; fail fast instead.
  def highlight(text)
    Timeout.timeout(1) { described_class.apply_highlights(text, []) }
  end

  def regions(text)
    highlight(text).map { |r| text[r[:start]...r[:end]] }
  end

  it 'colors every occurrence of a pattern with its colors' do
    HIGHLIGHT[/goblin/] = ['ff0000', nil, nil]

    expect(highlight('a goblin and a goblin')).to eq([
                                                       { start: 2, end: 8, fg: 'ff0000', bg: nil, ul: nil },
                                                       { start: 15, end: 21, fg: 'ff0000', bg: nil, ul: nil }
                                                     ])
  end

  it 'returns without coloring anything for a pattern that only matches the empty string' do
    HIGHLIGHT[/\b/] = ['ff0000', nil, nil]

    expect(highlight('a goblin attacks')).to be_empty
  end

  it 'returns for an empty .highlight pattern' do
    HIGHLIGHT[Regexp.new(Regexp.escape(''), Regexp::IGNORECASE)] = ['ff0000', nil, nil]

    expect(highlight('a goblin attacks')).to be_empty
  end

  it 'colors the non-empty matches of a pattern that can also match empty' do
    HIGHLIGHT[/o*/] = ['ff0000', nil, nil]

    expect(regions('foo boot')).to eq(%w[oo oo])
  end

  # Most displayed texts repeat, so the regions found for a text are
  # remembered until HIGHLIGHT changes. Whatever is remembered, every call
  # must give what matching afresh would give.
  describe 'a text highlighted again' do
    let(:room) { 'A goblin and a troll stand near a goblin.' }

    before do
      HIGHLIGHT[/goblin/] = ['ff0000', nil, nil]
      HIGHLIGHT[/troll/] = ['00ff00', '000000', 'true']
    end

    # [text, fg, bg, ul] for each region, in the order given
    def shown(text)
      highlight(text).map { |r| [text[r[:start]...r[:end]], r[:fg], r[:bg], r[:ul]] }
    end

    # Whether highlighting +text+ now tries the patterns on it
    def tries_patterns_for(text)
      tried = false
      allow(HIGHLIGHT).to receive(:each_pair).and_wrap_original do |original, *args, &block|
        tried = true
        original.call(*args, &block)
      end
      highlight(text)
      tried
    end

    it 'gets the same regions, each pattern in order and its matches left to right' do
      first = shown(room)

      expect(shown(room)).to eq(first)
      expect(first).to eq [%w[goblin ff0000] + [nil, nil], %w[goblin ff0000] + [nil, nil],
                           %w[troll 00ff00 000000 true]]
    end

    it 'gets new region hashes, so changing the ones given before changes nothing' do
      described_class.apply_highlights(room, []).each do |region|
        region[:start] = 0
        region[:fg] = 'changed'
      end

      expect(shown(room).map { |text, fg, *| [text, fg] }).to eq [%w[goblin ff0000], %w[goblin ff0000], %w[troll 00ff00]]
    end

    it 'appends to the regions passed in and returns that array' do
      highlight(room)
      link = { start: 0, end: 1, fg: '5555ff', cmd: 'look' }
      given = [link]

      expect(described_class.apply_highlights(room, given)).to be(given)
      expect(given.size).to eq 4
      expect(given.first).to be(link)
    end

    it 'does not try the patterns again for a text it has seen' do
      highlight(room)

      expect(tries_patterns_for(room)).to be false
    end

    it 'colors it with a pattern added since (.highlight)' do
      highlight(room)
      SETTINGS_LOCK.synchronize { HIGHLIGHT[/stand/i] = ['00ffff', nil, nil] }

      expect(shown(room).map(&:first)).to eq %w[goblin goblin troll stand]
    end

    it 'stops coloring it with a pattern removed since (.unhighlight)' do
      highlight(room)
      SETTINGS_LOCK.synchronize { HIGHLIGHT.delete(/goblin/) }

      expect(shown(room).map(&:first)).to eq %w[troll]
    end

    it 'follows the patterns of a reload, in their new order' do
      highlight(room)
      SETTINGS_LOCK.synchronize do
        HIGHLIGHT.replace(/troll/ => ['00ff00', nil, nil], /near/ => ['ffff00', nil, nil], /goblin/ => ['ff0000', nil, nil])
      end

      expect(shown(room).map(&:first)).to eq %w[troll near goblin goblin]
    end

    it 'colors it in the new colors given to a pattern it already has' do
      highlight(room)
      HIGHLIGHT[/goblin/] = ['ffffff', '111111', 'true']

      expect(shown(room).first).to eq %w[goblin ffffff 111111 true]
    end

    it 'colors it in the colors of a pattern changed in place' do
      highlight(room)
      HIGHLIGHT[/troll/][0] = 'abcdef'

      expect(shown(room).last).to eq %w[troll abcdef 000000 true]
    end

    it 'colors nothing once the highlights are cleared' do
      highlight(room)
      CONFIG.reset!

      expect(highlight(room)).to be_empty
    end

    it 'follows HIGHLIGHT replaced by another table that has changed as often' do
      highlight(room)
      other = HighlightTable[/near/ => ['ffff00', nil, nil]]
      other.rehash while other.generation < HIGHLIGHT.generation
      stub_const('HIGHLIGHT', other)

      expect(shown(room).map(&:first)).to eq %w[near]
    end

    it 'matches afresh every time when HIGHLIGHT is a plain Hash' do
      plain = { /goblin/ => ['ff0000', nil, nil] }
      stub_const('HIGHLIGHT', plain)
      highlight(room)
      plain[/troll/] = ['00ff00', nil, nil]

      expect(shown(room).map(&:first)).to eq %w[goblin goblin troll]
    end

    describe 'remembering at most a fixed number of texts' do
      before { stub_const('HighlightProcessor::SPANS_MEMO_CAPACITY', 2) }

      it 'forgets the oldest text first' do
        highlight('one goblin')
        highlight('two goblins')
        highlight('three goblins')

        expect([tries_patterns_for('two goblins'), tries_patterns_for('one goblin')]).to eq [false, true]
      end
    end

    describe 'a long text' do
      let(:limit) { described_class::SPANS_MEMO_MAX_BYTES }

      it 'is remembered at the byte limit' do
        text = "#{'x' * (limit - 7)} goblin"
        highlight(text)

        expect(tries_patterns_for(text)).to be false
      end

      it 'is matched every time past the byte limit' do
        text = "#{'x' * (limit - 6)} goblin"
        highlight(text)

        expect(tries_patterns_for(text)).to be true
        expect(shown(text)).to eq [%w[goblin ff0000] + [nil, nil]]
      end

      it 'counts bytes, not characters' do
        text = "#{[0x00E9].pack('U') * ((limit / 2) - 3)} goblin"
        highlight(text)

        expect(text.length).to be < limit
        expect(tries_patterns_for(text)).to be true
      end
    end
  end

  describe '.render_colored_text' do
    # A window that records each string drawn with the [fg, bg] it was
    # drawn in (nil when drawn uncolored).
    let(:window) do
      Class.new do
        attr_reader :drawn

        def initialize = @drawn = []
        def addstr(str) = @drawn << [str, @attrs]

        def attron(attrs)
          @attrs = attrs
          yield
        ensure
          @attrs = nil
        end
      end.new
    end

    let(:link) { '5555ff' }

    before do
      pairs = []
      allow(described_class).to receive(:get_color_pair_id) { |fg, bg| (pairs << [fg, bg]).size }
      @pair_of = ->(attrs) { attrs && pairs[((attrs & Curses::A_COLOR) >> 8) - 1] }
    end

    def render(text, regions)
      described_class.render_colored_text(window, text, regions)
      window.drawn.map { |str, attrs| [str, @pair_of.(attrs)] }
    end

    it 'draws a link inside a wider colored region in the region\'s color' do
      drawn = render('a jeol moradu', [{ start: 0, end: 13, fg: 'ff0000' },
                                       { start: 2, end: 13, fg: link, cmd: 'look #1' }])

      expect(drawn).to eq [['a ', ['ff0000', nil]], ['jeol moradu', ['ff0000', nil]]]
    end

    it 'draws a link in the link color where no other region gives a foreground' do
      drawn = render('a pouch', [{ start: 0, end: 7, bg: '000033' },
                                 { start: 2, end: 7, fg: link, cmd: 'look #1' }])

      expect(drawn).to eq [['a ', [nil, '000033']], ['pouch', [link, '000033']]]
    end

    it 'draws the smaller of two nested links in its own color' do
      drawn = render('a pouch', [{ start: 0, end: 7, fg: '00ff00', cmd: 'look #1' },
                                 { start: 2, end: 7, fg: link, cmd: 'look #2' }])

      expect(drawn).to eq [['a ', ['00ff00', nil]], ['pouch', [link, nil]]]
    end
  end
end
