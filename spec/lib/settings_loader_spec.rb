# frozen_string_literal: true

# Tests that SettingsLoader applies <notification-stream> and restores the
# default when the element is removed and settings are reloaded.

require 'rexml/document'
require 'tmpdir'
require_relative '../../lib/key_codes'
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
end
