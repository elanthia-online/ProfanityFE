# frozen_string_literal: true

# Tests that SettingsLoader applies <notification-stream> and <history-size>
# and restores their defaults when the element is removed and settings are
# reloaded, that a reload replaces every setting or, when the file fails to
# load, none, and that the settings cache never serves stale or foreign settings.

require 'rexml/document'
require 'tmpdir'
require_relative '../../lib/key_codes'
require_relative '../../lib/profanity_settings' # enables the settings cache (APP_DIR)
require_relative '../../lib/settings_loader'

# Load the REAL GagPatterns module (replaces the spec_helper stub) so reload
# specs can check which lines are gagged.
original_verbose = $VERBOSE
$VERBOSE = nil
load File.expand_path('../../lib/gag_patterns.rb', __dir__)
$VERBOSE = original_verbose

RSpec.describe SettingsLoader do
  def write_settings(dir, body)
    path = File.join(dir, 'settings.xml')
    File.write(path, "<settings>#{body}</settings>")
    path
  end

  def load_settings(path, reload: false)
    described_class.load(path, {}, {}, proc {}, reload: reload)
  end

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  describe '<notification-stream>' do
    it 'defaults to familiar when the element is absent' do
      load_settings(write_settings(@dir, ''))
      expect(CONFIG.notification_stream).to eq 'familiar'
    end

    it 'sets the stream from the element text' do
      load_settings(write_settings(@dir, '<notification-stream> ooc </notification-stream>'))
      expect(CONFIG.notification_stream).to eq 'ooc'
    end

    it 'ignores an empty element' do
      load_settings(write_settings(@dir, '<notification-stream></notification-stream>'))
      expect(CONFIG.notification_stream).to eq 'familiar'
    end

    it 'updates the stream on reload' do
      path = write_settings(@dir, '<notification-stream>ooc</notification-stream>')
      load_settings(path)
      File.write(path, '<settings><notification-stream>thoughts</notification-stream></settings>')
      load_settings(path, reload: true)
      expect(CONFIG.notification_stream).to eq 'thoughts'
    end

    it 'restores the default when the element is removed and settings are reloaded' do
      path = write_settings(@dir, '<notification-stream>ooc</notification-stream>')
      load_settings(path)
      expect(CONFIG.notification_stream).to eq 'ooc'

      File.write(path, '<settings></settings>')
      load_settings(path, reload: true)
      expect(CONFIG.notification_stream).to eq 'familiar'
    end
  end

  describe '<history-size>' do
    before { allow(ProfanityLog).to receive(:write) }

    it 'defaults to 1000 when the element is absent' do
      load_settings(write_settings(@dir, ''))
      expect(CONFIG.history_size).to eq 1000
    end

    it 'sets the size from the element text' do
      load_settings(write_settings(@dir, '<history-size> 50 </history-size>'))
      expect(CONFIG.history_size).to eq 50
    end

    it 'accepts 0' do
      load_settings(write_settings(@dir, '<history-size>0</history-size>'))
      expect(CONFIG.history_size).to eq 0
    end

    ['', 'lots', '-5', '2.5'].each do |text|
      it "keeps the default and logs a warning for #{text.inspect}" do
        load_settings(write_settings(@dir, "<history-size>#{text}</history-size>"))
        expect(CONFIG.history_size).to eq 1000
        expect(ProfanityLog).to have_received(:write).with('settings', "Invalid history-size '#{text}' (expected a whole number), using 1000")
      end
    end

    it 'updates the size on reload' do
      path = write_settings(@dir, '<history-size>50</history-size>')
      load_settings(path)
      File.write(path, '<settings><history-size>20</history-size></settings>')
      load_settings(path, reload: true)
      expect(CONFIG.history_size).to eq 20
    end

    it 'restores the default when the element is removed and settings are reloaded' do
      path = write_settings(@dir, '<history-size>50</history-size>')
      load_settings(path)
      File.write(path, '<settings></settings>')
      load_settings(path, reload: true)
      expect(CONFIG.history_size).to eq 1000
    end

    it 'is unchanged by a reload that fails' do
      path = write_settings(@dir, '<history-size>50</history-size>')
      load_settings(path)
      File.write(path, '<settings><history-size>20</history-size><gag>x</gags></settings>')
      load_settings(path, reload: true)
      expect(CONFIG.history_size).to eq 50
    end
  end

  describe 'file encoding' do
    # Under LANG=C / POSIX, Ruby's default external encoding is US-ASCII.
    def with_default_external(encoding)
      original = Encoding.default_external
      verbose = $VERBOSE
      $VERBOSE = nil
      Encoding.default_external = encoding
      yield
    ensure
      Encoding.default_external = original
      $VERBOSE = verbose
    end

    it 'loads a settings file containing non-ASCII text under a C locale' do
      path = write_settings(@dir, '<!-- highlights — for goblins --><notification-stream>ooc</notification-stream>')

      with_default_external(Encoding::US_ASCII) { load_settings(path) }

      expect(CONFIG.notification_stream).to eq 'ooc'
    end
  end

  describe 'key binding conflicts' do
    let(:first_action) { proc {} }
    let(:second_action) { proc {} }
    let(:key_action) { { 'first' => first_action, 'second' => second_action } }
    let(:key_binding) { {} }

    def load_keys(body)
      path = write_settings(@dir, "#{body}<highlight fg='ff0000'>goblin</highlight>")
      described_class.load(path, key_binding, key_action, proc {})
    end

    def expect_conflict_logged(id)
      expect(ProfanityLog).to have_received(:write)
        .with('settings', a_string_including('Key binding conflict', "id='#{id}'", 'later definition wins'))
    end

    before do
      allow(ProfanityLog).to receive(:write)
      HIGHLIGHT.clear
    end

    it 'lets a combo using a bound key as its prefix replace the binding and keeps loading' do
      load_keys("<key id='escape' action='first'/><key id='alt+1' action='second'/>")

      expect(HIGHLIGHT.keys).to eq [/goblin/]
      expect(key_binding[27]).to eq('1' => second_action)
      expect_conflict_logged('alt+1')
    end

    it 'lets a nested combo on a bound key replace the binding and keeps loading' do
      load_keys("<key id='ctrl+x' action='first'/><key id='ctrl+x'><key id='a' action='second'/></key>")

      expect(HIGHLIGHT.keys).to eq [/goblin/]
      expect(key_binding[24]).to eq('a' => second_action)
      expect_conflict_logged('ctrl+x')
    end

    it 'lets an action on a combo prefix replace the combo and logs the conflict' do
      load_keys("<key id='alt+1' action='first'/><key id='escape' action='second'/>")

      expect(key_binding[27]).to be second_action
      expect(HIGHLIGHT.keys).to eq [/goblin/]
      expect_conflict_logged('escape')
    end

    it 'lets a macro on a nested combo prefix replace the combo and logs the conflict' do
      load_keys("<key id='ctrl+x'><key id='a' action='first'/></key><key id='ctrl+x' macro='look'/>")

      expect(key_binding[24]).to be_a(Proc)
      expect(HIGHLIGHT.keys).to eq [/goblin/]
      expect_conflict_logged('ctrl+x')
    end

    it 'merges combos sharing a prefix without logging a conflict' do
      load_keys("<key id='alt+1' action='first'/><key id='alt+2' action='second'/>")

      expect(key_binding[27]).to eq('1' => first_action, '2' => second_action)
      expect(ProfanityLog).not_to have_received(:write)
    end

    it 'rebinds a key to a different action without logging a conflict' do
      load_keys("<key id='ctrl+x' action='first'/><key id='ctrl+x' action='second'/>")

      expect(key_binding[24]).to be second_action
      expect(ProfanityLog).not_to have_received(:write)
    end
  end

  describe 'unknown key ids' do
    let(:action) { proc {} }
    let(:key_binding) { {} }

    def load_keys(body)
      path = write_settings(@dir, "#{body}<highlight fg='ff0000'>goblin</highlight>")
      described_class.load(path, key_binding, { 'act' => action }, proc {})
    end

    before do
      allow(ProfanityLog).to receive(:write)
      HIGHLIGHT.clear
    end

    it 'logs a key id that names no key, binds nothing for it and keeps loading' do
      load_keys("<key id='ctrl+tab' action='act'/><key id='ctrl+x' action='act'/>")

      expect(key_binding).to eq(24 => action)
      expect(HIGHLIGHT.keys).to eq [/goblin/]
      expect(ProfanityLog).to have_received(:write).with('settings', "Unknown key id 'ctrl+tab', binding ignored")
    end

    it 'logs an unknown combo prefix once and skips the keys nested in it' do
      load_keys("<key id='ctrl_x'><key id='a' action='act'/><key id='b' action='act'/></key>")

      expect(key_binding).to be_empty
      expect(ProfanityLog).to have_received(:write).once
      expect(ProfanityLog).to have_received(:write).with('settings', "Unknown key id 'ctrl_x', binding ignored")
    end

    it 'logs an unknown key id nested in a known combo prefix' do
      load_keys("<key id='ctrl+x'><key id='a' action='act'/><key id='plus' action='act'/></key>")

      expect(key_binding).to eq(24 => { 'a' => action })
      expect(ProfanityLog).to have_received(:write).with('settings', "Unknown key id 'plus', binding ignored")
    end
  end

  describe 'key bindings on reload' do
    let(:first_action) { proc {} }
    let(:second_action) { proc {} }
    let(:key_action) { { 'first' => first_action, 'second' => second_action } }
    let(:key_binding) { {} }

    def load_keys(body, reload: false)
      path = write_settings(@dir, body)
      described_class.load(path, key_binding, key_action, proc {}, reload: reload)
    end

    before { allow(ProfanityLog).to receive(:write) }

    it 'drops a key removed from the file when settings are reloaded' do
      load_keys("<key id='ctrl+x' action='first'/><key id='ctrl+y' action='second'/>")

      load_keys("<key id='ctrl+y' action='second'/>", reload: true)

      expect(key_binding).to eq(25 => second_action)
    end

    it 'logs no conflict when a key changes from an action to a combo across a reload' do
      load_keys("<key id='escape' action='first'/>")

      load_keys("<key id='alt+1' action='second'/>", reload: true)

      expect(key_binding).to eq(27 => { '1' => second_action })
      expect(ProfanityLog).not_to have_received(:write)
    end

    it 'logs no conflict when a key changes from a combo to an action across a reload' do
      load_keys("<key id='alt+1' action='first'/>")

      load_keys("<key id='escape' action='second'/>", reload: true)

      expect(key_binding).to eq(27 => second_action)
      expect(ProfanityLog).not_to have_received(:write)
    end

    it 'keeps the existing keys when the reloaded file is malformed' do
      load_keys("<key id='ctrl+x' action='first'/>")

      File.write(File.join(@dir, 'settings.xml'), '<settings><key id=')
      described_class.load(File.join(@dir, 'settings.xml'), key_binding, key_action, proc {}, reload: true)

      expect(key_binding).to eq(24 => first_action)
    end
  end

  describe 'reloading' do
    let(:first_action) { proc {} }
    let(:second_action) { proc {} }
    let(:key_action) { { 'first' => first_action, 'second' => second_action } }
    let(:key_binding) { {} }

    let(:good_settings) do
      <<~XML
        <settings>
          <highlight fg='ff0000'>goblin</highlight>
          <perc-transform pattern='Osrel Meraud' replace='OM'/>
          <gag>^A moth flutters</gag>
          <combat_gag>^You feint</combat_gag>
          <multiline_gag start='^Knowledge from your sanowret' end='^The knowledge fades'/>
          <notification-stream>ooc</notification-stream>
          <key id='ctrl+x' action='first'/>
        </settings>
      XML
    end

    def reload(xml)
      path = File.join(@dir, 'settings.xml')
      File.write(path, xml)
      described_class.load(path, key_binding, key_action, proc {}, reload: true)
    end

    def expect_good_settings_in_effect
      expect(HIGHLIGHT).to eq(/goblin/ => ['ff0000', nil, nil])
      expect(PERC_TRANSFORMS).to eq [[/Osrel Meraud/, 'OM']]
      expect(CONFIG.notification_stream).to eq 'ooc'
      expect(key_binding).to eq(24 => first_action)
      expect(GagPatterns.match_general('A moth flutters by.')).not_to be_nil
      expect('You feint high.').to match(GagPatterns.combat_regexp)
      expect(GagPatterns.match_multiline_start('Knowledge from your sanowret crystal')).not_to be_nil
    end

    before do
      allow(ProfanityLog).to receive(:write)
      path = File.join(@dir, 'settings.xml')
      File.write(path, good_settings)
      described_class.load(path, key_binding, key_action, proc {})
    end

    # BUG FOUND (fixed here): .reload cleared highlights, perc transforms,
    # the notification stream and custom gags before parsing the file, so a
    # typo in the settings file left the user with none of them.
    it 'keeps every setting when the reloaded file is malformed' do
      error = reload(good_settings.sub('</gag>', '</gags>').sub('goblin', 'kobold'))

      expect_good_settings_in_effect
      expect(error).to be_a(REXML::ParseException)
    end

    it 'keeps every setting when the reloaded file is empty' do
      error = reload('')

      expect_good_settings_in_effect
      expect(error).to be_a(StandardError)
    end

    it 'reports the failure and logs the backtrace' do
      reload('<settings><gag>x</gags></settings>')

      expect(ProfanityLog).to have_received(:write)
        .with('settings', a_string_including("Missing end tag for 'gag'"), backtrace: an_instance_of(Array))
    end

    it 'reports a missing file without changing any setting' do
      File.delete(File.join(@dir, 'settings.xml'))

      error = nil
      expect { error = described_class.load(File.join(@dir, 'settings.xml'), key_binding, key_action, proc {}, reload: true) }
        .to output(/Settings file not found/).to_stderr
      expect(error).to be_a(Errno::ENOENT)
      expect_good_settings_in_effect
    end

    it 'reports success with nil' do
      expect(reload(good_settings)).to be_nil
    end

    it 'replaces the gags: a removed gag no longer gags and an added one does' do
      reload(<<~XML)
        <settings>
          <gag>^A bat squeaks</gag>
          <combat_gag>^You lunge</combat_gag>
          <multiline_gag start='^Your ring glows'/>
        </settings>
      XML

      expect(GagPatterns.match_general('A moth flutters by.')).to be_nil
      expect(GagPatterns.match_general('A bat squeaks.')).not_to be_nil
      expect('You feint high.').not_to match(GagPatterns.combat_regexp)
      expect('You lunge low.').to match(GagPatterns.combat_regexp)
      expect(GagPatterns.match_multiline_start('Knowledge from your sanowret crystal')).to be_nil
      expect(GagPatterns.match_multiline_start('Your ring glows brightly.')).not_to be_nil
    end

    it 'replaces highlights, perc transforms, the notification stream and key bindings' do
      reload(<<~XML)
        <settings>
          <highlight fg='00ff00'>kobold</highlight>
          <perc-transform pattern='Mana' replace='M'/>
          <notification-stream>thoughts</notification-stream>
          <key id='ctrl+y' action='second'/>
        </settings>
      XML

      expect(HIGHLIGHT).to eq(/kobold/ => ['00ff00', nil, nil])
      expect(PERC_TRANSFORMS).to eq [[/Mana/, 'M']]
      expect(CONFIG.notification_stream).to eq 'thoughts'
      expect(key_binding).to eq(25 => second_action)
    end

    it "keeps the given highlights after the file's, their colors winning for the same regex" do
      path = File.join(@dir, 'settings.xml')
      File.write(path, good_settings.sub('goblin', 'kobold').sub('<perc', "<highlight fg='ff0000'>troll</highlight><perc"))
      keep = { /troll/ => ['00ffff', nil, nil], /orc/i => ['00ffff', nil, nil] }

      described_class.load(path, key_binding, key_action, proc {}, reload: true, keep_highlights: keep)

      expect(HIGHLIGHT.to_a).to eq [[/kobold/, ['ff0000', nil, nil]], [/troll/, ['00ffff', nil, nil]],
                                    [/orc/i, ['00ffff', nil, nil]]]
    end

    it 'leaves the highlights as they were when the reloaded file is malformed' do
      path = File.join(@dir, 'settings.xml')
      File.write(path, '<settings>')

      error = described_class.load(path, key_binding, key_action, proc {},
                                   reload: true, keep_highlights: { /orc/i => ['00ffff', nil, nil] })

      expect(error).to be_a(StandardError)
      expect_good_settings_in_effect
    end

    it 'skips an invalid pattern and applies the rest of the file' do
      error = nil
      expect {
        error = reload(<<~XML)
          <settings>
            <highlight fg='ff0000'>(</highlight>
            <highlight fg='00ff00'>kobold</highlight>
            <gag>[unclosed</gag>
            <gag>^A bat squeaks</gag>
            <perc-transform pattern='(' replace='x'/>
          </settings>
        XML
      }.to output(/Invalid gag pattern: \[unclosed/).to_stderr

      expect(error).to be_nil
      expect(HIGHLIGHT).to eq(/kobold/ => ['00ff00', nil, nil])
      expect(PERC_TRANSFORMS).to be_empty
      expect(GagPatterns.match_general('A bat squeaks.')).not_to be_nil
    end
  end

  describe 'initial load of a malformed file' do
    it 'loads no layouts and reports the failure' do
      path = write_settings(@dir, "<layout id='default'><window class='text'/></layout><gag>x</gags>")

      error = load_settings(path)

      expect(error).to be_a(REXML::ParseException)
      expect(LAYOUT).to be_empty
    end
  end

  describe 'settings cache' do
    it 'reports a malformed file rather than using the cache of the previous version' do
      path = write_settings(@dir, '<notification-stream>ooc</notification-stream>')
      load_settings(path)

      File.write(path, '<settings><notification-stream>thoughts</notification-stream')
      error = load_settings(path, reload: true)

      expect(CONFIG.notification_stream).to eq 'ooc'
      expect(error).to be_a(REXML::ParseException)
    end

    it 'picks up an edit saved within the same filesystem clock tick as the cache' do
      path = write_settings(@dir, '<notification-stream>ooc</notification-stream>')
      load_settings(path)
      cache_mtime = File.mtime(described_class.cache_path_for(path))

      File.write(path, '<settings><notification-stream>thoughts</notification-stream></settings>')
      File.utime(cache_mtime, cache_mtime, path) # a coarse clock gives both files the same mtime
      load_settings(path, reload: true)

      expect(CONFIG.notification_stream).to eq 'thoughts'
    end

    it 'keeps separate caches for settings files with the same name in different directories' do
      Dir.mktmpdir do |other_dir|
        first = write_settings(@dir, '<notification-stream>ooc</notification-stream>')
        second = write_settings(other_dir, '<notification-stream>thoughts</notification-stream>')
        load_settings(first)

        load_settings(second)

        expect(CONFIG.notification_stream).to eq 'thoughts'
        expect(described_class.cache_path_for(first)).not_to eq described_class.cache_path_for(second)
      end
    end

    it 'reuses the cache without reparsing while the file is unchanged' do
      path = write_settings(@dir, '<notification-stream>ooc</notification-stream>')
      load_settings(path)
      allow(REXML::Document).to receive(:new).and_call_original

      load_settings(path, reload: true)

      expect(REXML::Document).not_to have_received(:new)
      expect(CONFIG.notification_stream).to eq 'ooc'
    end

    it 'rebuilds a cache written in the old format (a bare element tree)' do
      path = write_settings(@dir, '<notification-stream>thoughts</notification-stream>')
      stale_tree = CachedElement.new('settings', {}, nil, [CachedElement.new('notification-stream', {}, 'ooc', [])])
      File.binwrite(described_class.cache_path_for(path), Marshal.dump(stale_tree))

      load_settings(path)

      expect(CONFIG.notification_stream).to eq 'thoughts'
    end
  end
end
