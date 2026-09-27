# frozen_string_literal: true

# Tests that KEY_NAME gives the ctrl/alt/shift key names the codes this
# terminal's ncurses actually delivers for them. ncurses numbers those
# modified keys at run time, so the codes differ between ncurses builds:
# the table must come from Curses.keyname, not from fixed numbers.

require 'rexml/document'
require 'tmpdir'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'

RSpec.describe 'KEY_NAME' do
  # terminfo's extended key capabilities for xterm-256color, in the order
  # ncurses numbers them. kDN and kUP (shift+down/up) repeat the standard
  # kind/kri strings, so ncurses gives their codes no name.
  def extended_caps
    %w[DC DN END HOM IC LFT NXT PRV RIT UP].flat_map do |stem|
      (%w[DN UP].include?(stem) ? [nil] : []) + (3..7).map { |mod| "k#{stem}#{mod}" }
    end
  end

  # Curses.keyname for an ncurses build that numbers the extended key
  # capabilities from +first_code+. Codes below KEY_MAX keep their
  # standard names.
  def keyname_numbering_from(first_code)
    names = { 260 => 'KEY_LEFT', 336 => 'KEY_SF', 337 => 'KEY_SR', 393 => 'KEY_SLEFT' }
    extended_caps.each_with_index { |cap, i| names[first_code + i] = cap if cap }
    names.to_proc
  end

  # Real macOS system ncurses (6.0.20150808) with TERM=xterm-256color:
  # kDC3 is 519, so Ctrl+Left (kLFT5) arrives as 547.
  let(:macos_keyname) { keyname_numbering_from(519) }

  # The build the fallback codes came from: kDC3 is 511, so Ctrl+Left is 539.
  let(:fallback_build_keyname) { keyname_numbering_from(511) }

  # Load key_codes.rb as the application does, with Curses.keyname
  # answering like +keyname+, and return the KEY_NAME it builds.
  def key_name_with(keyname)
    stub_const('KEY_NAME', nil) # restores the real table after the example
    Curses.define_singleton_method(:keyname) { |code| keyname&.call(code) }
    original_verbose = $VERBOSE
    $VERBOSE = nil
    load File.expand_path('../../lib/key_codes.rb', __dir__)
    KEY_NAME
  ensure
    $VERBOSE = original_verbose
    Curses.singleton_class.send(:remove_method, :keyname)
  end

  def names_for(table, code) = table.select { |_name, c| c == code }.keys

  context 'with macOS system ncurses' do
    subject(:table) { key_name_with(macos_keyname) }

    it 'names the codes the modified keys arrive as' do
      expect(table).to include(
        'ctrl+left' => 547, 'ctrl+right' => 562, 'ctrl+up' => 568, 'ctrl+down' => 527,
        'alt+left' => 545, 'alt+right' => 560, 'alt+up' => 566, 'alt+down' => 525,
        'alt+page_up' => 555, 'alt+page_down' => 550, 'ctrl+delete' => 521,
        'ctrl+home' => 537, 'ctrl+end' => 532
      )
    end

    it 'gives Ctrl+Left (547) only the name ctrl+left, not alt+page_up' do
      expect(names_for(table, 547)).to eq ['ctrl+left']
    end

    it 'gives no extended code two names' do
      extended = table.values.grep(Integer).select { |code| code > 511 }
      expect(extended.tally.select { |_code, count| count > 1 }).to be_empty
    end
  end

  context 'with the ncurses build the fallback codes came from' do
    subject(:table) { key_name_with(fallback_build_keyname) }

    it 'keeps every fallback code for the modified keys' do
      fallback = {
        'ctrl+delete' => 513, 'alt+down' => 517, 'ctrl+down' => 519, 'alt+left' => 537,
        'ctrl+left' => 539, 'alt+page_down' => 542, 'alt+page_up' => 547, 'alt+right' => 552,
        'ctrl+right' => 554, 'alt+up' => 558, 'ctrl+up' => 560
      }
      expect(table).to include(fallback)
    end

    it 'names a modified key numbered at KEY_MAX (alt+delete, 511)' do
      expect(table).to include('alt+delete' => 511)
    end
  end

  it 'names each xterm modifier combination' do
    keyname = { 600 => 'kLFT2', 601 => 'kLFT4', 602 => 'kLFT6', 603 => 'kLFT7', 604 => 'kLFT8' }.to_proc
    expect(key_name_with(keyname)).to include(
      'shift+left' => 393, # shift+left is the standard KEY_SLEFT, not kLFT2
      'alt+shift+left' => 601, 'ctrl+shift+left' => 602,
      'ctrl+alt+left' => 603, 'ctrl+alt+shift+left' => 604
    )
  end

  it 'never replaces a standard key code' do
    keyname = { 600 => 'kUP2', 601 => 'kDN2', 602 => 'kDC2' }.to_proc
    expect(key_name_with(keyname)).to include('shift+up' => 337, 'shift+down' => 336, 'shift+delete' => 383)
  end

  it 'ignores extended names that are not modified editing keys' do
    keyname = { 600 => 'kxIN', 601 => 'kUP', 602 => 'kLFT9', 603 => 'kBEG5' }.to_proc
    expect(key_name_with(keyname).values.grep(600..603)).to be_empty
  end

  it 'keeps a fallback code ncurses names nothing, and drops one it gives another name' do
    # Only Ctrl+Left is named, at the code the fallback gives alt+page_up.
    table = key_name_with({ 547 => 'kLFT5' }.to_proc)
    expect(table).to include('ctrl+left' => 547, 'alt+right' => 552)
    expect(table).not_to have_key('alt+page_up')
  end

  it 'is the fallback table when ncurses names no extended keys' do
    fallback = key_name_with(nil)
    expect(key_name_with(->(_code) {})).to eq fallback
    expect(fallback).to include('ctrl+left' => 539, 'alt+1' => [27, '1'], 'escape' => 27)
  end

  it 'is frozen' do
    expect(key_name_with(macos_keyname)).to be_frozen
  end

  describe 'a <key> binding in the settings file' do
    # SettingsLoader looks the id up in KEY_NAME, so the binding lands on
    # the code the key really sends.
    it 'fires on the code macOS ncurses delivers for the key' do
      key_name_with(macos_keyname)
      fired = []
      actions = { 'word_left' => proc { fired << :word_left }, 'tab_up' => proc { fired << :tab_up } }
      binding = {}
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'settings.xml')
        File.write(path, "<settings><key id='ctrl+left' action='word_left'/><key id='alt+page_up' action='tab_up'/></settings>")
        SettingsLoader.load(path, binding, actions, proc {})
      end

      [547, 555].each { |code| binding[code]&.call }

      expect(fired).to eq %i[word_left tab_up]
    end
  end
end
