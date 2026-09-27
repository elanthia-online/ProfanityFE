# frozen_string_literal: true

# Tests that SettingsLoader applies <notification-stream> and restores the
# default when the element is removed and settings are reloaded, and that
# the settings cache never serves stale or foreign settings.

require 'rexml/document'
require 'tmpdir'
require_relative '../../lib/key_codes'
require_relative '../../lib/profanity_settings' # enables the settings cache (APP_DIR)
require_relative '../../lib/settings_loader'

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
      expect(key_binding[27]).to eq(49 => second_action)
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

      expect(key_binding[27]).to eq(49 => first_action, 50 => second_action)
      expect(ProfanityLog).not_to have_received(:write)
    end

    it 'rebinds a key to a different action without logging a conflict' do
      load_keys("<key id='ctrl+x' action='first'/><key id='ctrl+x' action='second'/>")

      expect(key_binding[24]).to be second_action
      expect(ProfanityLog).not_to have_received(:write)
    end
  end

  describe 'settings cache' do
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
