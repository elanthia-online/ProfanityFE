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
