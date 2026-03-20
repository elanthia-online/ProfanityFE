# frozen_string_literal: true

# Tests StyledText value object: immutable text + color runs bundling,
# #slice, #lstrip, #wrap (word-wrap with run splitting), #<<, #add_run,
# and #dup_with_runs. Includes adversarial edge cases for wrapping.

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

    it 'preserves cmd and priority attributes' do
      st = described_class.new('link')
      st.add_run(start: 0, end: 4, fg: '0000ff', cmd: 'go north', priority: 2)
      expect(st.runs.first[:cmd]).to eq 'go north'
      expect(st.runs.first[:priority]).to eq 2
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

  describe '#wrap' do
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
      expect(lines.first.text).to match(/^Hello/)
      expect(lines.length).to be >= 2
    end

    it 'splits a run across two lines' do
      st = described_class.new('Hello world', [{ start: 0, end: 11, fg: 'ff0000' }])
      lines = st.wrap(8, indent: false)
      # First line should have run clamped to its length
      expect(lines.first.runs.first[:end]).to be <= lines.first.text.length
      # Second line should have remaining run starting at 0
      if lines.length > 1 && lines[1].runs.any?
        expect(lines[1].runs.first[:start]).to eq 0
      end
    end

    it 'preserves run colors through wrapping' do
      st = described_class.new('AAAAABBBBB', [
                                 { start: 0, end: 5, fg: 'ff0000' },
                                 { start: 5, end: 10, fg: '00ff00' },
                               ])
      lines = st.wrap(5, indent: false)
      expect(lines[0].runs.first[:fg]).to eq 'ff0000'
      expect(lines[1].runs.first[:fg]).to eq '00ff00'
    end

    it 'run positions are valid indices into the line text' do
      st = described_class.new('The quick brown fox jumps over the lazy dog', [
                                 { start: 4, end: 9, fg: 'ff0000' }, # "quick"
                                 { start: 20, end: 25, fg: '00ff00' }, # "jumps"
                               ])
      lines = st.wrap(15, indent: false)
      lines.each do |line|
        line.runs.each do |run|
          expect(run[:start]).to be >= 0
          expect(run[:end]).to be <= line.text.length
          expect(run[:start]).to be < run[:end]
          # The text at the run position should exist
          segment = line.text[run[:start]...run[:end]]
          expect(segment).not_to be_nil
          expect(segment.length).to be > 0
        end
      end
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
      all_cmds = lines.flat_map { |l| l.runs.select { |r| r[:cmd] }.map { |r| r[:cmd] } }
      expect(all_cmds).to all(eq 'go north')
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

    it 'handles text with trailing space at width boundary' do
      st = described_class.new('Hello     world')
      lines = st.wrap(10, indent: false)
      # Should break at a space, not leave trailing spaces
      expect(lines.first.text.length).to be <= 10
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
      expect(lines.flat_map(&:runs).any? { |r| r[:cmd] == 'test' }).to be true
    end

    it 'indent: true adds leading spaces to continuation lines' do
      st = described_class.new('Hello world foo bar baz')
      lines = st.wrap(12, indent: true)
      if lines.length > 1
        expect(lines[1].text).to start_with('  ')
      end
    end

    it 'indent: false does not add leading spaces' do
      st = described_class.new('Hello world foo bar baz')
      lines = st.wrap(12, indent: false)
      if lines.length > 1
        # Should not have indent-added leading spaces
        # (may have natural spaces from word breaks)
        expect(lines[1].text).not_to start_with('  ')
      end
    end

    it 'splits a run exactly at a word boundary' do
      # Run ends at "Hello" (5), wrap at width 6 breaks after "Hello "
      st = described_class.new('Hello world', [
                                 { start: 0, end: 5, fg: 'ff0000' },
                                 { start: 6, end: 11, fg: '00ff00' }
                               ])
      lines = st.wrap(6, indent: false)
      expect(lines[0].text.strip).to eq 'Hello'
      expect(lines[0].runs.first[:fg]).to eq 'ff0000'
      expect(lines[1].runs.first[:fg]).to eq '00ff00'
    end

    it 'handles a run that spans exactly the wrap width' do
      st = described_class.new('AAAA BBBB', [
                                 { start: 0, end: 9, fg: 'ff0000' }
                               ])
      lines = st.wrap(4, indent: false)
      lines.each do |line|
        line.runs.each do |run|
          expect(run[:start]).to be >= 0
          expect(run[:end]).to be <= line.text.length
        end
      end
    end

    it 'handles UTF-8 multi-byte characters in text' do
      st = described_class.new('café résumé', [
                                 { start: 0, end: 4, fg: 'ff0000' },
                                 { start: 5, end: 11, fg: '00ff00' }
                               ])
      lines = st.wrap(6, indent: false)
      all_text = lines.map(&:text).join
      expect(all_text.gsub(/\s+/, ' ').strip).to include('café')
      expect(all_text.gsub(/\s+/, ' ').strip).to include('résumé')
    end

    it 'handles CJK characters without crashing' do
      st = described_class.new('日本語テスト', [
                                 { start: 0, end: 6, fg: 'ff0000' }
                               ])
      lines = st.wrap(3, indent: false)
      expect(lines.flat_map { |l| l.runs }).to all(
        satisfy { |r| r[:start] >= 0 && r[:end] <= lines.find { |l| l.runs.include?(r) }.text.length }
      )
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
      # Verify bold runs point at the right text in each line
      lines.each do |line|
        line.runs.each do |run|
          segment = line.text[run[:start]...run[:end]]
          expect(%w[goblin troll]).to include(segment), "Expected creature name, got #{segment.inspect}"
        end
      end
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
