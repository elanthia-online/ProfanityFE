# frozen_string_literal: true

# Tests HighlightProcessor.apply_highlights: every occurrence of a highlight
# pattern becomes a color region, and patterns that can match the empty
# string (which user highlights often can) never stall the scan.

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
end
