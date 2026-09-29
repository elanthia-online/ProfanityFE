# frozen_string_literal: true

# Tests StyledText value object: immutable text + color runs bundling,
# #slice, #lstrip, #replace_ranges and its #sub/#gsub/#strip, #wrap
# (word-wrap with run splitting), #<<, #add_run,
# and #dup_with_runs. Includes adversarial edge cases for wrapping.

require 'timeout'
require_relative '../../lib/styled_text'

RSpec.describe StyledText do
  describe '#initialize' do
    it 'creates with empty defaults' do
      st = described_class.new
      expect(st.text).to eq ''
      expect(st.runs).to eq []
    end

    it 'dups the text (no aliasing)' do
      original = +'mutable'
      st = described_class.new(original)
      original.replace('changed')
      expect(st.text).to eq 'mutable'
    end

    it 'dups each run (no aliasing)' do
      run = { start: 0, end: 5, fg: 'ff0000' }
      st = described_class.new('hello', [run])
      run[:fg] = '00ff00'
      expect(st.runs.first[:fg]).to eq 'ff0000'
    end

    it 'handles nil-like input gracefully' do
      st = described_class.new(nil)
      expect(st.text).to eq ''
    end
  end

  describe '#length / #empty? / #blank?' do
    it('length of text') { expect(described_class.new('hello').length).to eq 5 }
    it('empty on empty') { expect(described_class.new('').empty?).to be true }
    it('not empty') { expect(described_class.new('x').empty?).to be false }
    it('blank on whitespace') { expect(described_class.new('   ').blank?).to be true }
    it('blank on empty') { expect(described_class.new('').blank?).to be true }
    it('not blank') { expect(described_class.new('x').blank?).to be false }
  end

  describe '#<<' do
    it 'appends text' do
      st = described_class.new('hello')
      st << ' world'
      expect(st.text).to eq 'hello world'
      expect(st.length).to eq 11
    end

    it 'does not modify existing runs' do
      st = described_class.new('hello', [{ start: 0, end: 5, fg: 'ff0000' }])
      st << ' world'
      expect(st.runs.first[:end]).to eq 5
    end

    it 'returns self for chaining' do
      st = described_class.new
      expect(st << 'a').to equal(st)
    end
  end

  describe '#add_run' do
    it 'adds a run to the list' do
      st = described_class.new('hello')
      st.add_run(start: 0, end: 5, fg: 'ff0000')
      expect(st.runs.length).to eq 1
      expect(st.runs.first).to include(start: 0, end: 5, fg: 'ff0000')
    end

    it 'preserves the cmd attribute' do
      st = described_class.new('link')
      st.add_run(start: 0, end: 4, fg: '0000ff', cmd: 'go north')
      expect(st.runs.first[:cmd]).to eq 'go north'
    end

    it 'returns self for chaining' do
      st = described_class.new('x')
      expect(st.add_run(start: 0, end: 1)).to equal(st)
    end
  end

  describe '#slice' do
    let(:st) do
      described_class.new('Hello world', [
                            { start: 0, end: 5, fg: 'ff0000' }, # "Hello"
                            { start: 6, end: 11, fg: '00ff00' }, # "world"
                          ])
    end

    it 'slices text correctly' do
      expect(st.slice(0...5).text).to eq 'Hello'
    end

    it 'adjusts run positions relative to the slice start' do
      result = st.slice(6...11)
      expect(result.text).to eq 'world'
      expect(result.runs.first).to include(start: 0, end: 5, fg: '00ff00')
    end

    it 'excludes runs entirely outside the range' do
      result = st.slice(0...5)
      expect(result.runs.length).to eq 1
      expect(result.runs.first[:fg]).to eq 'ff0000'
    end

    it 'clamps partially overlapping runs' do
      full = described_class.new('ABCDEFGHIJ', [{ start: 3, end: 8, fg: 'aabbcc' }])
      result = full.slice(5...10)
      expect(result.text).to eq 'FGHIJ'
      expect(result.runs.first).to include(start: 0, end: 3)
    end

    it 'handles empty result' do
      result = st.slice(5...5)
      expect(result.text).to eq ''
      expect(result.runs).to be_empty
    end

    it 'handles range beyond text length' do
      result = st.slice(8...20)
      expect(result.text).to eq 'rld'
      expect(result.runs.first).to include(start: 0, end: 3)
    end

    it 'preserves cmd attributes through slicing' do
      linked = described_class.new('go north', [{ start: 0, end: 8, fg: '0000ff', cmd: 'go north' }])
      result = linked.slice(0...8)
      expect(result.runs.first[:cmd]).to eq 'go north'
    end

    # Adversarial
    it 'returns empty StyledText for empty source' do
      empty = described_class.new('')
      expect(empty.slice(0...0).text).to eq ''
    end

    it 'handles runs with zero length (start == end) — excludes them' do
      zero_run = described_class.new('abc', [{ start: 1, end: 1, fg: 'ff0000' }])
      result = zero_run.slice(0...3)
      expect(result.runs).to be_empty
    end

    it 'does not modify the original' do
      original_text = st.text.dup
      original_runs = st.runs.map(&:dup)
      st.slice(0...5)
      expect(st.text).to eq original_text
      expect(st.runs).to eq original_runs
    end
  end

  describe '#lstrip' do
    it 'removes leading whitespace and adjusts positions' do
      st = described_class.new('  hello', [{ start: 2, end: 7, fg: 'ff0000' }])
      result = st.lstrip
      expect(result.text).to eq 'hello'
      expect(result.runs.first).to include(start: 0, end: 5)
    end

    it 'returns unchanged copy when no leading whitespace' do
      st = described_class.new('hello', [{ start: 0, end: 5, fg: 'ff0000' }])
      result = st.lstrip
      expect(result.text).to eq 'hello'
      expect(result.runs.first).to include(start: 0, end: 5)
    end

    it 'drops runs that end up entirely before position 0' do
      st = described_class.new('   hello', [
                                 { start: 0, end: 2, fg: 'ff0000' }, # entirely in whitespace
                                 { start: 3, end: 8, fg: '00ff00' }, # "hello"
                               ])
      result = st.lstrip
      expect(result.runs.length).to eq 1
      expect(result.runs.first[:fg]).to eq '00ff00'
    end

    it 'clamps runs that partially overlap the stripped region' do
      st = described_class.new('  hello', [{ start: 1, end: 7, fg: 'ff0000' }])
      result = st.lstrip
      expect(result.text).to eq 'hello'
      expect(result.runs.first).to include(start: 0, end: 5)
    end

    it 'does not modify the original' do
      st = described_class.new('  hello', [{ start: 2, end: 7, fg: 'ff0000' }])
      st.lstrip
      expect(st.text).to eq '  hello'
    end

    # Adversarial
    it 'handles all-whitespace text' do
      st = described_class.new('   ')
      result = st.lstrip
      expect(result.text).to eq ''
      expect(result.runs).to be_empty
    end

    it 'handles empty text' do
      result = described_class.new('').lstrip
      expect(result.text).to eq ''
    end

    it 'handles tabs as leading whitespace' do
      st = described_class.new("\t\thello", [{ start: 2, end: 7, fg: 'ff0000' }])
      result = st.lstrip
      expect(result.text).to eq 'hello'
    end
  end

  describe '#replace_ranges' do
    red = { fg: 'ff0000' }

    it 'moves a run on kept text by the change in length before it' do
      st = described_class.new('Khri Avoidance (31)', [red.merge(start: 5, end: 14)])
      result = st.replace_ranges([[0, 5, '']])
      expect(result.text).to eq 'Avoidance (31)'
      expect(result.runs).to eq [red.merge(start: 0, end: 9)]
    end

    it 'puts a run on replaced text onto the whole replacement' do
      st = described_class.new('Persistence of Mana (OM)', [red.merge(start: 0, end: 19)])
      result = st.replace_ranges([[0, 19, 'POM']])
      expect(result.text).to eq 'POM (OM)'
      expect(result.runs).to eq [red.merge(start: 0, end: 3)]
    end

    it 'extends a run on part of a replaced span to the whole replacement' do
      st = described_class.new('Persistence of Mana (OM)', [red.merge(start: 15, end: 19)])
      expect(st.replace_ranges([[0, 19, 'POM']]).runs).to eq [red.merge(start: 0, end: 3)]
    end

    it 'drops a run on deleted text only' do
      st = described_class.new('Bloodthorns (44 roisaen)', [red.merge(start: 15, end: 23)])
      result = st.replace_ranges([[15, 23, '']])
      expect(result.text).to eq 'Bloodthorns (44)'
      expect(result.runs).to be_empty
    end

    it 'shrinks a run by the text deleted inside it' do
      st = described_class.new('(44 roisaen)', [red.merge(start: 0, end: 12)])
      expect(st.replace_ranges([[3, 11, '']]).runs).to eq [red.merge(start: 0, end: 4)]
    end

    it 'keeps runs that touch a replaced span off the replacement' do
      st = described_class.new('ab--cd', [red.merge(start: 0, end: 2), red.merge(start: 4, end: 6)])
      result = st.replace_ranges([[2, 4, '+']])
      expect(result.text).to eq 'ab+cd'
      expect(result.runs).to eq [red.merge(start: 0, end: 2), red.merge(start: 3, end: 5)]
    end

    it 'colors inserted text only when a run spans the insertion point' do
      st = described_class.new('abcd', [red.merge(start: 0, end: 2), red.merge(start: 2, end: 4), red.merge(start: 1, end: 3)])
      result = st.replace_ranges([[2, 2, 'XX']])
      expect(result.text).to eq 'abXXcd'
      expect(result.runs).to eq [red.merge(start: 0, end: 2), red.merge(start: 4, end: 6), red.merge(start: 1, end: 5)]
    end

    it 'applies several edits against the original positions, in any order' do
      st = described_class.new('a  b  c', [red.merge(start: 6, end: 7)])
      result = st.replace_ranges([[4, 6, ' '], [1, 3, ' ']])
      expect(result.text).to eq 'a b c'
      expect(result.runs).to eq [red.merge(start: 4, end: 5)]
    end

    it 'keeps the other attributes of a run' do
      st = described_class.new('xab', [{ start: 1, end: 3, fg: 'ff0000', bg: '000000', ul: 'true' }])
      expect(st.replace_ranges([[0, 1, '']]).runs).to eq [{ start: 0, end: 2, fg: 'ff0000', bg: '000000', ul: 'true' }]
    end
  end

  describe '#sub' do
    it 'replaces like String#sub, backreferences included, and moves the runs' do
      st = described_class.new('Khri Avoidance (31)', [{ start: 5, end: 14, fg: 'ff0000' }])
      result = st.sub(/Khri (\w+)/, '\1!')
      expect(result.text).to eq 'Khri Avoidance (31)'.sub(/Khri (\w+)/, '\1!')
      expect(result.runs).to eq [{ start: 0, end: 10, fg: 'ff0000' }]
    end

    it 'matches a String pattern literally' do
      expect(described_class.new('a.c abc').sub('b', 'X').text).to eq 'a.c aXc'
      expect(described_class.new('abc a.c').sub('.', 'X').text).to eq 'abc aXc'
    end

    it 'returns an unchanged copy when nothing matches' do
      st = described_class.new('Instinct (13)', [{ start: 0, end: 8, fg: 'ff0000' }])
      result = st.sub(/roisaen/, '')
      expect([result.text, result.runs]).to eq [st.text, st.runs]
    end
  end

  describe '#gsub' do
    it 'replaces every match and moves the runs after each one' do
      st = described_class.new('POM  (OM)  x', [{ start: 5, end: 9, fg: 'ff0000' }, { start: 11, end: 12, fg: 'ff0000' }])
      result = st.gsub(/  /, ' ')
      expect(result.text).to eq 'POM (OM) x'
      expect(result.runs).to eq [{ start: 4, end: 8, fg: 'ff0000' }, { start: 9, end: 10, fg: 'ff0000' }]
    end
  end

  describe '#strip' do
    it 'removes leading and trailing whitespace and moves the runs' do
      st = described_class.new('  POM (OM) ', [{ start: 2, end: 5, fg: 'ff0000' }, { start: 0, end: 11, fg: '00ff00' }])
      result = st.strip
      expect(result.text).to eq 'POM (OM)'
      expect(result.runs).to eq [{ start: 0, end: 3, fg: 'ff0000' }, { start: 0, end: 8, fg: '00ff00' }]
    end

    it 'drops every run of an all-whitespace text' do
      result = described_class.new('   ', [{ start: 0, end: 3, fg: 'ff0000' }]).strip
      expect([result.text, result.runs]).to eq ['', []]
    end
  end

  describe '#wrap' do
    # A one- or two-column window asks for width 0 (maxx - 1); a regression
    # would loop forever, so fail fast instead.
    def wrap_within_a_second(styled, width)
      Timeout.timeout(1) { styled.wrap(width, indent: false).map(&:text) }
    end

    it 'wraps one character per line when asked for width 0' do
      expect(wrap_within_a_second(described_class.new('abc'), 0)).to eq %w[a b c]
    end

    it 'treats a negative width like width 1' do
      expect(wrap_within_a_second(described_class.new('abc'), -1)).to eq %w[a b c]
    end

    it 'returns single line when text fits within width' do
      st = described_class.new('Hello', [{ start: 0, end: 5, fg: 'ff0000' }])
      lines = st.wrap(80)
      expect(lines.length).to eq 1
      expect(lines.first.text).to eq 'Hello'
      expect(lines.first.runs.first).to include(start: 0, end: 5)
    end

    it 'wraps at word boundary' do
      st = described_class.new('Hello world')
      lines = st.wrap(8)
      expect(lines.map(&:text)).to eq ['Hello ', '  world']
    end

    it 'splits a run across two lines' do
      st = described_class.new('Hello world', [{ start: 0, end: 11, fg: 'ff0000' }])
      lines = st.wrap(8, indent: false)
      expect(lines.map(&:text)).to eq ['Hello ', 'world']
      expect(lines[0].runs).to eq [{ start: 0, end: 6, fg: 'ff0000' }]
      expect(lines[1].runs).to eq [{ start: 0, end: 5, fg: 'ff0000' }]
    end

    it 'preserves run colors through wrapping' do
      st = described_class.new('AAAAABBBBB', [
                                 { start: 0, end: 5, fg: 'ff0000' },
                                 { start: 5, end: 10, fg: '00ff00' },
                               ])
      lines = st.wrap(5, indent: false)
      expect(lines.map(&:text)).to eq %w[AAAAA BBBBB]
      expect(lines[0].runs).to eq [{ start: 0, end: 5, fg: 'ff0000' }]
      expect(lines[1].runs).to eq [{ start: 0, end: 5, fg: '00ff00' }]
    end

    it 'moves each run to its word on the line the word wraps to' do
      st = described_class.new('The quick brown fox jumps over the lazy dog', [
                                 { start: 4, end: 9, fg: 'ff0000' }, # "quick"
                                 { start: 20, end: 25, fg: '00ff00' }, # "jumps"
                               ])
      lines = st.wrap(15, indent: false)
      expect(lines.map(&:text)).to eq ['The quick ', 'brown fox ', 'jumps over the ', 'lazy dog']
      expect(lines.map(&:runs)).to eq [
        [{ start: 4, end: 9, fg: 'ff0000' }],
        [],
        [{ start: 0, end: 5, fg: '00ff00' }],
        [],
      ]
    end

    it 'handles text that must break mid-word (no spaces)' do
      st = described_class.new('ABCDEFGHIJ', [{ start: 0, end: 10, fg: 'ff0000' }])
      lines = st.wrap(5, indent: false)
      expect(lines.length).to eq 2
      expect(lines[0].text).to eq 'ABCDE'
      expect(lines[1].text).to eq 'FGHIJ'
    end

    it 'preserves cmd attributes through wrapping' do
      st = described_class.new('Click here to go', [
                                 { start: 0, end: 16, fg: '0000ff', cmd: 'go north' }
                               ])
      lines = st.wrap(10, indent: false)
      expect(lines.map(&:text)).to eq ['Click ', 'here to go']
      expect(lines.map(&:runs)).to eq [
        [{ start: 0, end: 6, fg: '0000ff', cmd: 'go north' }],
        [{ start: 0, end: 10, fg: '0000ff', cmd: 'go north' }],
      ]
    end

    # Adversarial
    it 'handles empty text' do
      st = described_class.new('')
      lines = st.wrap(80)
      expect(lines.length).to eq 1
      expect(lines.first.text).to eq ''
    end

    it 'handles width of 1 (indent auto-disabled)' do
      st = described_class.new('abc')
      lines = st.wrap(1)
      # indent is auto-disabled when width <= 3 to prevent infinite loop
      expect(lines.length).to eq 3
      expect(lines.map(&:text)).to eq %w[a b c]
    end

    it 'handles text exactly equal to width' do
      st = described_class.new('12345', [{ start: 0, end: 5, fg: 'ff0000' }])
      lines = st.wrap(5)
      expect(lines.length).to eq 1
      expect(lines.first.text).to eq '12345'
    end

    it 'breaks after a run of spaces that fills the width' do
      st = described_class.new('Hello     world')
      lines = st.wrap(10, indent: false)
      expect(lines.map(&:text)).to eq ['Hello     ', 'world']
    end

    it 'does not modify the original text or runs' do
      st = described_class.new('Hello world', [{ start: 0, end: 11, fg: 'ff0000' }])
      original_text = st.text.dup
      original_runs = st.runs.map(&:dup)
      st.wrap(5)
      expect(st.text).to eq original_text
      expect(st.runs).to eq original_runs
    end

    it 'handles runs with no fg/bg (structural only)' do
      st = described_class.new('Hello world', [{ start: 0, end: 11, cmd: 'test' }])
      lines = st.wrap(8, indent: false)
      expect(lines.map(&:runs)).to eq [[{ start: 0, end: 6, cmd: 'test' }], [{ start: 0, end: 5, cmd: 'test' }]]
    end

    it 'indent: true adds leading spaces to continuation lines' do
      st = described_class.new('Hello world foo bar baz')
      lines = st.wrap(12, indent: true)
      expect(lines.map(&:text)).to eq ['Hello world ', '  foo bar ', '  baz']
    end

    it 'indent: false does not add leading spaces' do
      st = described_class.new('Hello world foo bar baz')
      lines = st.wrap(12, indent: false)
      expect(lines.map(&:text)).to eq ['Hello world ', 'foo bar baz']
    end

    it 'splits a run exactly at a word boundary' do
      # Run ends at "Hello" (5), wrap at width 6 breaks after "Hello "
      st = described_class.new('Hello world', [
                                 { start: 0, end: 5, fg: 'ff0000' },
                                 { start: 6, end: 11, fg: '00ff00' }
                               ])
      lines = st.wrap(6, indent: false)
      expect(lines.map(&:text)).to eq ['Hello ', 'world']
      expect(lines[0].runs).to eq [{ start: 0, end: 5, fg: 'ff0000' }]
      expect(lines[1].runs).to eq [{ start: 0, end: 5, fg: '00ff00' }]
    end

    it 'handles a run that spans exactly the wrap width' do
      st = described_class.new('AAAA BBBB', [
                                 { start: 0, end: 9, fg: 'ff0000' }
                               ])
      lines = st.wrap(4, indent: false)
      expect(lines.map(&:text)).to eq %w[AAAA BBBB]
      expect(lines.map(&:runs)).to eq [[{ start: 0, end: 4, fg: 'ff0000' }], [{ start: 0, end: 4, fg: 'ff0000' }]]
    end

    it 'keeps a run on its word when the space before the word is dropped from the next line' do
      st = described_class.new('AAAA BBBB', [{ start: 5, end: 9, fg: '00ff00' }]) # "BBBB"
      lines = st.wrap(4, indent: false)
      expect(lines.map(&:text)).to eq %w[AAAA BBBB]
      expect(lines.map(&:runs)).to eq [[], [{ start: 0, end: 4, fg: '00ff00' }]]
    end

    it 'handles UTF-8 multi-byte characters in text' do
      st = described_class.new('café résumé', [
                                 { start: 0, end: 4, fg: 'ff0000' },
                                 { start: 5, end: 11, fg: '00ff00' }
                               ])
      lines = st.wrap(6, indent: false)
      expect(lines.map(&:text)).to eq ['café ', 'résumé']
      expect(lines.map(&:runs)).to eq [[{ start: 0, end: 4, fg: 'ff0000' }], [{ start: 0, end: 6, fg: '00ff00' }]]
    end

    it 'wraps CJK text by characters, splitting its run' do
      st = described_class.new('日本語テスト', [
                                 { start: 0, end: 6, fg: 'ff0000' }
                               ])
      lines = st.wrap(3, indent: false)
      expect(lines.map(&:text)).to eq %w[日本語 テスト]
      expect(lines.map(&:runs)).to eq [[{ start: 0, end: 3, fg: 'ff0000' }], [{ start: 0, end: 3, fg: 'ff0000' }]]
    end
  end

  describe '#dup_with_runs' do
    it 'creates independent copy' do
      st = described_class.new('hello', [{ start: 0, end: 5, fg: 'ff0000' }])
      copy = st.dup_with_runs
      copy.runs.first[:fg] = '00ff00'
      expect(st.runs.first[:fg]).to eq 'ff0000'
    end

    it 'creates independent text' do
      st = described_class.new('hello')
      copy = st.dup_with_runs
      copy << ' world'
      expect(st.text).to eq 'hello'
    end
  end

  # ---- Integration: realistic game text scenarios ----

  describe 'realistic game scenarios' do
    it 'bold creature in room description' do
      st = described_class.new('You also see a goblin and a troll.')
      st.add_run(start: 15, end: 21, fg: 'ff0000')  # "goblin"
      st.add_run(start: 28, end: 33, fg: 'ff0000')  # "troll"

      lines = st.wrap(20, indent: false)
      bold_words = lines.flat_map { |line| line.runs.map { |run| line.text[run[:start]...run[:end]] } }
      expect(lines.map(&:text)).to eq ['You also see a ', 'goblin and a troll.']
      expect(bold_words).to eq %w[goblin troll]
    end

    it 'lstrip room text preserves color regions' do
      st = described_class.new('  You also see a goblin.', [
                                 { start: 17, end: 23, fg: 'ff0000' }  # "goblin"
                               ])
      result = st.lstrip
      expect(result.text).to eq 'You also see a goblin.'
      segment = result.text[result.runs.first[:start]...result.runs.first[:end]]
      expect(segment).to eq 'goblin'
    end

    it 'slice extracts a window of text with correct colors' do
      st = described_class.new('The quick brown fox jumps', [
                                 { start: 4, end: 9, fg: 'ff0000' },   # "quick"
                                 { start: 10, end: 15, fg: '00ff00' }, # "brown"
                               ])
      # Extract "quick brown"
      result = st.slice(4...15)
      expect(result.text).to eq 'quick brown'
      expect(result.runs[0]).to include(start: 0, end: 5, fg: 'ff0000')
      expect(result.runs[1]).to include(start: 6, end: 11, fg: '00ff00')
    end
  end
end
