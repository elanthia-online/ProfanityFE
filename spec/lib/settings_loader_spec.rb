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
