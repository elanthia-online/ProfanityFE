# frozen_string_literal: true

# Load the REAL GagPatterns module (replaces the spec_helper stub)
original_verbose = $VERBOSE
$VERBOSE = nil
require_relative '../../lib/gag_patterns'
$VERBOSE = original_verbose

RSpec.describe GagPatterns do
  before(:each) { described_class.load_defaults }

  describe 'when first loaded' do
    # Reload the file to get the module's state before anything calls
    # load_defaults or adds a pattern -- what a settings file with no gags
    # leaves it in.
    def freshly_loaded_gag_patterns
      verbose = $VERBOSE
      $VERBOSE = nil
      load File.expand_path('../../lib/gag_patterns.rb', __dir__)
      described_class
    ensure
      $VERBOSE = verbose
    end

    it 'matches nothing instead of raising before any gag is added' do
      gags = freshly_loaded_gag_patterns

      expect(gags.match_general('A goblin arrives.')).to be_nil
      expect('A goblin swings').not_to match(gags.combat_regexp)
      expect(gags.match_multiline_start('Knowledge from your sanowret crystal')).to be_nil
    end
  end

  describe '.load_defaults' do
    it 'creates regexps that match nothing' do
      expect('anything').not_to match(described_class.combat_regexp)
      expect('anything').not_to match(described_class.general_regexp)
    end

    it 'clears patterns added before load_defaults' do
      described_class.add_general_pattern('test')
      described_class.load_defaults
      expect('test').not_to match(described_class.general_regexp)
    end
  end

  describe '.add_combat_pattern' do
    it 'pattern matches against combat text' do
      described_class.add_combat_pattern('swings a sword')
      expect('A goblin swings a sword at you').to match(described_class.combat_regexp)
    end

    it 'does not bleed into general patterns' do
      described_class.add_combat_pattern('swings')
      expect('swings').not_to match(described_class.general_regexp)
    end

    it 'accepts Regexp objects' do
      described_class.add_combat_pattern(/miss(es)?/i)
      expect('The goblin MISSES').to match(described_class.combat_regexp)
    end

    # String patterns are intentionally treated as regex - the module doc
    # example uses 'You also see .* moth' and XML <gag> elements contain
    # regex patterns, not literal strings. This means metacharacters like
    # () are active. Users who want literal parens must escape them.
    it 'treats string patterns as regex (metacharacters are active)' do
      described_class.add_combat_pattern('attack (melee|ranged)')
      expect('attack melee').to match(described_class.combat_regexp)
      expect('attack ranged').to match(described_class.combat_regexp)
      expect('attack magic').not_to match(described_class.combat_regexp)
    end

    it 'users can escape metacharacters for literal matching' do
      described_class.add_combat_pattern('attack \\(melee\\)')
      expect('attack (melee)').to match(described_class.combat_regexp)
      expect('attack melee').not_to match(described_class.combat_regexp)
    end

    it 'warns on invalid regex and does not add it' do
      expect {
        described_class.add_combat_pattern('[unclosed')
      }.to output(/Invalid combat gag pattern/).to_stderr
      expect('[unclosed').not_to match(described_class.combat_regexp)
    end

    it 'accumulates multiple patterns' do
      described_class.add_combat_pattern('sword')
      described_class.add_combat_pattern('axe')
      expect('sword').to match(described_class.combat_regexp)
      expect('axe').to match(described_class.combat_regexp)
      expect('bow').not_to match(described_class.combat_regexp)
    end

    # Adversarial
    it 'handles pattern that matches empty string' do
      described_class.add_combat_pattern('.*')
      expect('').to match(described_class.combat_regexp)
    end

    it 'handles pattern with anchors' do
      described_class.add_combat_pattern('^start')
      expect('start of line').to match(described_class.combat_regexp)
      expect('not start').not_to match(described_class.combat_regexp)
    end
  end

  describe '.add_general_pattern' do
    it 'matches general text' do
      described_class.add_general_pattern('You also see .* moth')
      expect('You also see a large moth').to match(described_class.general_regexp)
    end

    it 'does not bleed into combat patterns' do
      described_class.add_general_pattern('moth')
      expect('moth').not_to match(described_class.combat_regexp)
    end

    # Adversarial
    it 'handles unicode in patterns' do
      described_class.add_general_pattern("caf#{[0x00E9].pack('U')}")
      expect("a caf#{[0x00E9].pack('U')} appears").to match(described_class.general_regexp)
    end
  end

  describe '.clear_custom' do
    it 'removes all custom patterns from both sets' do
      described_class.add_combat_pattern('sword')
      described_class.add_general_pattern('moth')
      described_class.clear_custom
      expect('sword').not_to match(described_class.combat_regexp)
      expect('moth').not_to match(described_class.general_regexp)
    end

    it 'is idempotent' do
      described_class.clear_custom
      described_class.clear_custom
      expect('test').not_to match(described_class.general_regexp)
    end

    it 'allows re-adding patterns after clear' do
      described_class.add_general_pattern('old')
      described_class.clear_custom
      described_class.add_general_pattern('new')
      expect('old').not_to match(described_class.general_regexp)
      expect('new').to match(described_class.general_regexp)
    end
  end

  describe '.add_multiline_gag' do
    it 'records a start pattern with no end pattern' do
      described_class.add_multiline_gag('Knowledge from your sanowret crystal')
      gag = described_class.match_multiline_start('Knowledge from your sanowret crystal about Life Magic')
      expect(gag).not_to be_nil
      expect(gag[:end]).to be_nil
    end

    it 'records a start and end pattern' do
      described_class.add_multiline_gag('BEGIN block', 'END block')
      gag = described_class.match_multiline_start('BEGIN block here')
      expect(gag[:start]).to be_a(Regexp)
      expect(gag[:end]).to be_a(Regexp)
      expect('the END block now').to match(gag[:end])
    end

    it 'treats a blank end pattern as no end pattern' do
      described_class.add_multiline_gag('start', '   ')
      gag = described_class.match_multiline_start('start here')
      expect(gag[:end]).to be_nil
    end

    it 'accepts Regexp objects for start and end' do
      described_class.add_multiline_gag(/^Knowledge/, /rings clear/)
      gag = described_class.match_multiline_start('Knowledge from your crystal')
      expect(gag).not_to be_nil
      expect('the knowledge rings clear').to match(gag[:end])
    end

    it 'warns on invalid start regex and does not add it' do
      expect {
        described_class.add_multiline_gag('[unclosed')
      }.to output(/Invalid multiline gag pattern/).to_stderr
      expect(described_class.match_multiline_start('[unclosed')).to be_nil
    end

    it 'accumulates multiple multi-line gags' do
      described_class.add_multiline_gag('alpha')
      described_class.add_multiline_gag('beta')
      expect(described_class.match_multiline_start('alpha line')).not_to be_nil
      expect(described_class.match_multiline_start('beta line')).not_to be_nil
    end
  end

  describe '.match_multiline_start' do
    it 'returns nil when no multi-line gags are configured' do
      expect(described_class.match_multiline_start('anything')).to be_nil
    end

    it 'returns nil for a non-matching line' do
      described_class.add_multiline_gag('specific start')
      expect(described_class.match_multiline_start('unrelated text')).to be_nil
    end

    it 'returns the specific gag whose start matched' do
      described_class.add_multiline_gag('alpha', 'end-a')
      described_class.add_multiline_gag('beta', 'end-b')
      gag = described_class.match_multiline_start('beta arrives')
      expect('reach end-b').to match(gag[:end])
      expect('reach end-a').not_to match(gag[:end])
    end
  end

  describe '.replace_custom' do
    it 'replaces all three custom pattern sets' do
      described_class.add_general_pattern('moth')
      described_class.add_combat_pattern('sword')
      described_class.add_multiline_gag('alpha')

      described_class.replace_custom(general: ['bat'], combat: ['axe'], multiline: [{ start: 'beta', end: 'end-b' }])

      expect(described_class.match_general('a moth')).to be_nil
      expect(described_class.match_general('a bat')).to eq(/bat/)
      expect('sword').not_to match(described_class.combat_regexp)
      expect('axe').to match(described_class.combat_regexp)
      expect(described_class.match_multiline_start('alpha line')).to be_nil
      expect(described_class.match_multiline_start('beta line')).to eq(start: /beta/, end: /end-b/)
    end

    it 'clears every set when given no patterns' do
      described_class.add_general_pattern('moth')
      described_class.add_combat_pattern('sword')
      described_class.add_multiline_gag('alpha')

      described_class.replace_custom

      expect(described_class.match_general('moth')).to be_nil
      expect('sword').not_to match(described_class.combat_regexp)
      expect(described_class.match_multiline_start('alpha')).to be_nil
    end

    it 'warns about and skips an invalid pattern, keeping the valid ones' do
      expect {
        described_class.replace_custom(general: ['[unclosed', 'bat'], combat: ['(', 'axe'],
                                       multiline: [{ start: '[', end: nil }, { start: 'beta', end: '   ' }])
      }.to output(/Invalid gag pattern: \[unclosed.*Invalid combat gag pattern: \(.*Invalid multiline gag pattern: \[/m)
        .to_stderr

      expect(described_class.match_general('a bat')).to eq(/bat/)
      expect('axe').to match(described_class.combat_regexp)
      expect(described_class.match_multiline_start('beta line')).to eq(start: /beta/, end: nil)
    end
  end

  describe '.clear_custom with multi-line gags' do
    it 'removes multi-line gags' do
      described_class.add_multiline_gag('start')
      described_class.clear_custom
      expect(described_class.match_multiline_start('start here')).to be_nil
    end
  end

  describe '.match_general' do
    it 'returns the specific pattern that matched, not the union' do
      described_class.add_general_pattern('^A storm bull')
      described_class.add_general_pattern('You also see .* moth')

      expect(described_class.match_general('You also see a large moth')).to eq(/You also see .* moth/)
    end

    it 'returns nil when no general gag matches' do
      described_class.add_general_pattern('moth')

      expect(described_class.match_general('A goblin arrives.')).to be_nil
    end

    it 'ignores combat gags' do
      described_class.add_combat_pattern('swings')

      expect(described_class.match_general('A goblin swings')).to be_nil
    end
  end

  # Each gag is tried alone. A union of them numbered capture groups across
  # every gag, so a later gag's backreference pointed at an earlier gag's
  # group and that gag silently never matched.
  describe 'gags with backreferences' do
    it 'gags a line with a backreference gag listed after another gag with a group' do
      described_class.add_general_pattern('^A (\\w+) arrives')
      described_class.add_general_pattern('(\\w+) and \\1')

      expect(described_class.match_general('moth and moth')).to eq(/(\w+) and \1/)
      expect(described_class.match_general('moth and bat')).to be_nil
    end

    it 'starts a multi-line block with a backreference gag listed after another' do
      described_class.add_multiline_gag('^A (\\w+) arrives')
      described_class.add_multiline_gag('(\\w+) and \\1')

      expect(described_class.match_multiline_start('moth and moth')).to eq(start: /(\w+) and \1/, end: nil)
    end

    it 'loads a named-group gag alongside a numbered-backreference gag' do
      described_class.replace_custom(general: ['(?<who>\\w+) waves', '(\\w+) and \\1'])

      expect(described_class.match_general('The goblin waves')).to eq(/(?<who>\w+) waves/)
      expect(described_class.match_general('moth and moth')).to eq(/(\w+) and \1/)
    end
  end

  describe '.load_defaults with multi-line gags' do
    it 'clears multi-line gags added before load_defaults' do
      described_class.add_multiline_gag('start')
      described_class.load_defaults
      expect(described_class.match_multiline_start('start here')).to be_nil
    end
  end

  # The server thread matches every line while .reload (input thread)
  # replaces the gags. A read in the middle of an update must see the old
  # gags or the new ones, never a mix. The read is injected into each
  # Regexp.union call the update makes, standing in for the server thread
  # being scheduled at that point.
  describe 'reading while the gags are replaced' do
    # Whether each probe line is gagged, read as the server thread does.
    def gag_state
      {
        general_moth: !described_class.match_general('a moth').nil?,
        general_bat: !described_class.match_general('a bat').nil?,
        combat_sword: 'a sword'.match?(described_class.combat_regexp),
        combat_axe: 'an axe'.match?(described_class.combat_regexp),
        multiline_alpha: !described_class.match_multiline_start('alpha line').nil?,
        multiline_beta: !described_class.match_multiline_start('beta line').nil?
      }
    end

    # Run the update, recording gag_state at every Regexp.union call in it.
    def states_read_during
      states = []
      allow(Regexp).to receive(:union).and_wrap_original do |original, *args|
        states << gag_state
        original.call(*args)
      end
      yield
      states
    end

    let(:old_state) do
      { general_moth: true, general_bat: false, combat_sword: true, combat_axe: false,
        multiline_alpha: true, multiline_beta: false }
    end

    before do
      described_class.replace_custom(general: ['moth'], combat: ['sword'], multiline: [{ start: 'alpha' }])
    end

    it 'sees entirely the old or entirely the new gags during replace_custom' do
      new_state = { general_moth: false, general_bat: true, combat_sword: false, combat_axe: true,
                    multiline_alpha: false, multiline_beta: true }

      states = states_read_during do
        described_class.replace_custom(general: ['bat'], combat: ['axe'], multiline: [{ start: 'beta' }])
      end

      expect(states).not_to be_empty
      expect(states).to all(eq(old_state).or(eq(new_state)))
      expect(gag_state).to eq(new_state)
    end

    it 'sees entirely the old gags or none during clear_custom' do
      no_gags = old_state.transform_values { false }

      states = states_read_during { described_class.clear_custom }

      expect(states).not_to be_empty
      expect(states).to all(eq(old_state).or(eq(no_gags)))
      expect(gag_state).to eq(no_gags)
    end

    it 'does not change a gag list a reader already holds when a gag is added' do
      held = described_class.multiline_gags

      described_class.add_multiline_gag('beta')

      expect(held.map { |gag| gag[:start] }).to eq([/alpha/])
      expect(described_class.multiline_gags.map { |gag| gag[:start] }).to eq([/alpha/, /beta/])
    end
  end

  describe 'Regexp.union behavior edge cases' do
    it 'empty union matches nothing (not everything)' do
      described_class.load_defaults
      expect('').not_to match(described_class.general_regexp)
      expect('anything').not_to match(described_class.general_regexp)
    end

    it 'union with one pattern behaves like that pattern' do
      described_class.add_general_pattern('exact')
      expect('exact').to match(described_class.general_regexp)
      expect('inexact').to match(described_class.general_regexp) # substring match
      expect('other').not_to match(described_class.general_regexp)
    end
  end

  describe 'MatchMemo' do
    subject(:memo) { GagPatterns::MatchMemo.new(2) }

    # Fetch +line+ from the memo, counting the times the verdict is computed.
    def fetch_counting(memo, line, verdict, calls)
      memo.fetch(line) do
        calls << line.dup
        verdict
      end
    end

    it 'computes a verdict once and answers the same line from the memo' do
      calls = []

      first = fetch_counting(memo, 'a moth', :moth_gag, calls)
      second = fetch_counting(memo, 'a moth', :other, calls)

      expect([first, second]).to eq(%i[moth_gag moth_gag])
      expect(calls).to eq(['a moth'])
    end

    it 'remembers a nil verdict, the answer for most lines' do
      calls = []

      2.times { fetch_counting(memo, 'A goblin arrives.', nil, calls) }

      expect(calls).to eq(['A goblin arrives.'])
    end

    it 'keys on the line content, so a different line is computed' do
      calls = []

      fetch_counting(memo, 'a moth', :moth_gag, calls)
      verdict = fetch_counting(memo, 'a bat', nil, calls)

      expect(verdict).to be_nil
      expect(calls).to eq(['a moth', 'a bat'])
    end

    it 'forgets the oldest verdict first once full' do
      calls = []
      %w[one two three].each { |line| fetch_counting(memo, line, line.to_sym, calls) }
      calls.clear

      fetch_counting(memo, 'three', :three, calls)
      fetch_counting(memo, 'two', :two, calls)
      fetch_counting(memo, 'one', :one, calls)

      expect(calls).to eq(['one'])
      expect(memo.size).to eq(2)
    end

    it 'is not fooled when the caller changes the line string afterwards' do
      calls = []
      line = +'a moth'
      fetch_counting(memo, line, :moth_gag, calls)

      line.replace('a bat')
      verdict = fetch_counting(memo, line, nil, calls)

      expect(verdict).to be_nil
      expect(calls).to eq(['a moth', 'a bat'])
      expect(fetch_counting(memo, 'a moth', :other, calls)).to eq(:moth_gag)
    end

    it 'remembers a line exactly MAX_LINE_BYTES long' do
      calls = []
      line = 'x' * GagPatterns::MatchMemo::MAX_LINE_BYTES

      2.times { fetch_counting(memo, line, nil, calls) }

      expect(calls.size).to eq(1)
    end

    it 'matches a longer line every time instead of remembering it' do
      calls = []
      line = 'x' * (GagPatterns::MatchMemo::MAX_LINE_BYTES + 1)

      verdicts = Array.new(2) { fetch_counting(memo, line, :long_gag, calls) }

      expect(verdicts).to eq(%i[long_gag long_gag])
      expect(calls.size).to eq(2)
      expect(memo.size).to eq(0)
    end

    it 'measures the length cap in bytes, not characters' do
      calls = []
      line = [0x00E9].pack('U') * ((GagPatterns::MatchMemo::MAX_LINE_BYTES / 2) + 1)

      2.times { fetch_counting(memo, line, nil, calls) }

      expect(calls.size).to eq(2)
    end

    it 'by default keeps a thousand repeating lines, as a few minutes of travel sends' do
      default_memo = GagPatterns::MatchMemo.new
      lines = Array.new(1000) { |i| "You also see a leather pouch #{i}." }
      computed = 0

      2.times do
        lines.each do |line|
          default_memo.fetch(line) do
            computed += 1
            nil
          end
        end
      end

      expect(computed).to eq(1000)
    end

    it 'inspects as a count, not as every remembered line' do
      memo.fetch('a very long remembered line') { nil }

      expect(memo.inspect).to eq('#<GagPatterns::MatchMemo 1/2>')
    end
  end

  # Most server lines repeat (the worn-inventory list every few seconds while
  # crafting, room text on every visit), so verdicts are memoized per
  # snapshot. Each change to the gags publishes a new snapshot with empty
  # memos; these examples match a line, change the gags, then match the same
  # line again, which a stale memo would answer wrongly.
  describe 'repeated lines' do
    # The memos of the published snapshot.
    def memos
      snapshot = described_class.instance_variable_get(:@snapshot)
      [snapshot.general_memo, snapshot.multiline_memo]
    end

    it 'gags a repeated line every time, with the pattern that matched first' do
      described_class.add_general_pattern('moth')
      described_class.add_general_pattern('flutters')

      verdicts = Array.new(3) { described_class.match_general('a moth flutters') }

      expect(verdicts).to eq([/moth/, /moth/, /moth/])
    end

    it 'starts a repeated multi-line block with the first gag whose start matches' do
      described_class.add_multiline_gag('^Knowledge', 'end-a')
      described_class.add_multiline_gag('crystal', 'end-b')

      verdicts = Array.new(2) { described_class.match_multiline_start('Knowledge from your crystal') }

      expect(verdicts).to all(eq(start: /^Knowledge/, end: /end-a/))
    end

    it 'tries the multi-line starts for a repeated line only once' do
      described_class.add_multiline_gag('alpha')
      _, multiline_memo = memos

      3.times { described_class.match_multiline_start('alpha line') }
      3.times { described_class.match_multiline_start('beta line') }

      expect(multiline_memo.size).to eq(2)
    end

    it 'tells apart lines that differ only in case or after a long common start' do
      described_class.add_general_pattern('a moth$')
      start = "You also see #{'a lumpy bundle, ' * 10}"

      expect(described_class.match_general("#{start}A MOTH")).to be_nil
      expect(described_class.match_general("#{start}a moth")).to eq(/a moth$/)
      expect(described_class.match_general('A MOTH')).to be_nil
      expect(described_class.match_general('a moth')).to eq(/a moth$/)
    end

    it 'tries the patterns for a repeated line only once' do
      described_class.add_general_pattern('moth')
      general_memo, = memos

      3.times { described_class.match_general('A goblin arrives.') }
      3.times { described_class.match_general('a moth flutters') }

      expect(general_memo.size).to eq(2)
    end

    it 'applies a gag added after the line was seen' do
      expect(described_class.match_general('a bat squeaks')).to be_nil

      described_class.add_general_pattern('bat')

      expect(described_class.match_general('a bat squeaks')).to eq(/bat/)
    end

    it 'stops gagging a line once replace_custom drops its gag' do
      described_class.replace_custom(general: ['moth'])
      expect(described_class.match_general('a moth')).to eq(/moth/)

      described_class.replace_custom(general: ['bat'])

      expect(described_class.match_general('a moth')).to be_nil
    end

    it 'stops gagging a line once clear_custom drops its gag' do
      described_class.add_general_pattern('moth')
      expect(described_class.match_general('a moth')).to eq(/moth/)

      described_class.clear_custom

      expect(described_class.match_general('a moth')).to be_nil
    end

    it 'starts a multi-line gag added after its start line was seen' do
      expect(described_class.match_multiline_start('Knowledge from your crystal')).to be_nil

      described_class.add_multiline_gag('^Knowledge', 'rings clear')

      expect(described_class.match_multiline_start('Knowledge from your crystal'))
        .to eq(start: /^Knowledge/, end: /rings clear/)
    end

    it 'keeps general and multi-line verdicts for the same line apart' do
      described_class.add_general_pattern('alpha')
      described_class.add_multiline_gag('beta')

      expect(described_class.match_general('alpha beta')).to eq(/alpha/)
      expect(described_class.match_multiline_start('alpha beta')).to eq(start: /beta/, end: nil)
      expect(described_class.match_general('alpha beta')).to eq(/alpha/)
    end

    it 'does not grow a memo while there are no gags of that kind' do
      described_class.load_defaults

      described_class.match_general('anything')
      described_class.match_multiline_start('anything')

      expect(memos.map(&:size)).to eq([0, 0])
    end
  end
end
