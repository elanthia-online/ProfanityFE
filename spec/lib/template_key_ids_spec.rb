# frozen_string_literal: true

# Tests that every <key> id in the bundled templates names a key, so no
# template binding is silently dropped.
#
# Most modified-key names (ctrl+page_down, alt+home...) are not in
# KeyCodes::FALLBACK: key_codes.rb derives them at run time from the
# terminal's ncurses (Curses.keyname), which the specs' Curses stub does not
# provide. So each template is loaded with KEY_NAME built from a keyname
# that names every modified key the derivation knows. That accepts every
# name the application can resolve on some terminal; whether a terminal
# actually delivers a derived key is checked in a PTY, not here.

require 'rexml/document'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'

RSpec.describe 'bundled templates' do
  templates = Dir[File.expand_path('../../templates/*.xml', __dir__)].sort

  # KEY_NAME with every modified-key name that KeyCodes.key_names can derive:
  # each terminfo extended key capability (e.g. kNXT5) at its own code above
  # KEY_MAX, as ncurses numbers them.
  def every_derivable_key_name
    caps = KeyCodes::KEYS.keys.product(KeyCodes::MODIFIERS.keys).map { |stem, mod| "k#{stem}#{mod}" }
    first = KeyCodes::STANDARD_KEY_MAX + 1
    KeyCodes.key_names(->(code) { caps[code - first] if code >= first })
  end

  it 'includes the templates this spec is meant to cover' do
    expect(templates.map { |t| File.basename(t) }).to include('default.xml', 'mahtra.xml', 'eleazzar.xml', 'tysong.xml')
  end

  templates.each do |template|
    it "#{File.basename(template)} has no unknown key id" do
      stub_const('KEY_NAME', every_derivable_key_name)
      logged = []
      allow(ProfanityLog).to receive(:write) { |_context, message| logged << message }
      key_action = Hash.new { |hash, name| hash[name] = proc {} }

      SettingsLoader.load(template, {}, key_action, proc {})

      expect(logged.grep(/Unknown key id/)).to eq []
    end
  end
end
