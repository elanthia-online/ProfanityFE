# frozen_string_literal: true

# Text from the game connection reaches the rest of the client as ASCII:
# ServerText.normalize! puts an ASCII look-alike or "?" in place of each
# character outside ASCII (and "?" for each invalid byte) and deletes NUL
# bytes, before any gag, highlight or window sees the line. Ruby's Regexp and String bugs fixed on
# 2026-11-18 need such characters: a highlight added with .highlight read
# past the end of a buffer on a line with U+00DF (sharp s) in it, and a
# NUL let a case-insensitive backreference match past the end of a line.

require 'rexml/document'
require_relative '../../lib/shared_state'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../../lib/window_manager'
require_relative '../../lib/mouse_scroll'
require_relative '../../lib/autocomplete'
require_relative '../../lib/selection_manager'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/application'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../support/client_run'

RSpec.describe 'Text from the game connection' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'given.xml') }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '192.0.2.10', port: 8000)
  end
  let(:main) { app.window_mgr.stream['main'] }
  let(:matched) { [] }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    allow(ProfanityLog).to receive(:write)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    File.write(settings_path, <<~XML)
      <settings>
        <highlight fg='ff0000'>(?i)(\\w+) \\1</highlight>
        <key id='enter' action='send_command'/>
        <layout id='default'>
          <window class='text' value='main' top='0' left='0' height='12' width='200'/>
          <window class='command' top='12' left='0' height='1' width='200'/>
        </layout>
      </settings>
    XML
    matched = self.matched
    allow(HighlightProcessor).to receive(:scan_highlights).and_wrap_original do |original, text, *rest|
      matched << text.dup
      original.call(text, *rest)
    end
  end

  # The main window's rows, without the blank rows below the text.
  def main_rows = main.rows.reject(&:empty?)

  # Characters outside ASCII, built from code points (the source is ASCII).
  let(:sharp_s) { [0xDF].pack('U') }
  let(:smile) { [0x1F600].pack('U') }

  # Wait (as a keyboard step) until the main window shows +text+.
  def until_shown(text) = wait_until { main.rows.any? { |row| row.include?(text) } }

  it 'shows each character outside ASCII as "?" and gives the highlights only ASCII' do
    # The lines come after .highlight s, so they go through it as well.
    lines = lambda do
      game_server.say(%(Zoe says, "Stra#{sharp_s}e is lovely."), "Kri#{sharp_s} waves. #{smile}",
                      [0x43, 0x61, 0x66, 0xC3].pack('C*'))
    end

    run_client(keyboard(".highlight s\n", until_shown('Highlight added'), lines, until_shown('Caf'), 'x'))

    expect(main_rows).to include('Zoe says, "Stra?e is lovely."', 'Kri? waves. ?', 'Caf?')
    expect(matched).not_to be_empty
    expect(matched.reject(&:ascii_only?)).to eq []
  end

  # A NUL made curses raise when the line was drawn: the line was logged as
  # an error and never shown.
  it 'deletes NUL bytes, so the line is drawn' do
    game_server.say("Hello\0 there, k\0K.")

    run_client(keyboard(until_shown('Hello'), 'x'))

    expect(main_rows).to include('Hello there, kK.')
    expect(matched.grep(/\0/)).to eq []
    expect(ProfanityLog).not_to have_received(:write)
      .with('game_text_processor', a_string_starting_with('error processing line'), any_args)
  end

  it 'leaves ASCII text as it is' do
    game_server.say('A goblin dies. You say, "~!@#$%^&amp;*()_+{}|:&lt;&gt;?"')

    run_client(keyboard(until_shown('goblin'), 'x'))

    expect(main_rows).to include('A goblin dies. You say, "~!@#$%^&*()_+{}|:<>?"')
  end

  # Gags see the line as the windows do (spec_helper stubs GagPatterns, so
  # server_text_encoding_spec shows a gag hiding such a line).
  it 'gives the gags only ASCII' do
    gagged = []
    allow(GagPatterns).to receive(:match_general).and_wrap_original do |original, line, *rest|
      gagged << line.dup
      original.call(line, *rest)
    end
    game_server.say("Kri#{sharp_s} waves.", "k\0K", 'Zoe waves.')

    run_client(keyboard(until_shown('Zoe waves.'), 'x'))

    expect(gagged).not_to be_empty
    expect(gagged.reject(&:ascii_only?)).to eq []
    expect(gagged.grep(/\0/)).to eq []
  end
end
