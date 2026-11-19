# frozen_string_literal: true

# The warning about the Ruby running the client (RubyAdvisory.warning),
# shown by the real client (Application#run) on the virtual screen.

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
require_relative '../../lib/ruby_advisory'
require_relative '../support/client_run'

RSpec.describe 'The warning about an affected Ruby' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'given.xml') }
  let(:ruby_warning) { RubyAdvisory.warning(version: '4.0.9', engine: 'ruby') }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '192.0.2.10', port: 8000, ruby_warning: ruby_warning)
  end
  let(:main) { app.window_mgr.stream['main'] }
  let(:first_line) { /\A\* Ruby 4\.0\.9 has security bugs in regular expressions and strings/ }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    allow(ProfanityLog).to receive(:write)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    File.write(settings_path, <<~XML)
      <settings>
        <key id='enter' action='send_command'/>
        <layout id='default'>
          <window class='text' value='main' top='0' left='0' height='12' width='200'/>
          <window class='command' top='12' left='0' height='1' width='200'/>
        </layout>
      </settings>
    XML
  end

  # The main window's rows, without the blank rows below the text (a row
  # loses its trailing spaces, so a banner row reads "*").
  def main_rows = main.rows.reject(&:empty?)

  it 'shows the warning in the main window at startup, framed by banner rows, and prints nothing' do
    status, stderr = run_client(keyboard)

    expect(stderr).to eq ''
    expect(status).to be_nil.or eq(0)
    expect(main_rows).to eq ['*', "* #{ruby_warning[0]}", "* #{ruby_warning[1]}", '*']
  end

  # Shown only from the input loop, it came after the game's first lines,
  # and a login's burst of text could scroll it away.
  it "shows the warning before the game's first lines" do
    game_server.say('Hello from the game.')

    run_client(keyboard)

    expect(main_rows).to eq ['*', "* #{ruby_warning[0]}", "* #{ruby_warning[1]}", '*', 'Hello from the game.']
  end

  it 'shows it once: not again on .reload or .layout' do
    run_client(keyboard(".reload\n", ".layout default\n", 'x'))

    expect(main_rows.grep(first_line).size).to eq 1
  end

  # A layout with no main window, or a terminal too small for it, must not
  # lose the warning.
  it 'keeps the warning while there is no main window, and shows it once there is one' do
    without_main = lambda do
      main_window = app.window_mgr.stream.delete('main')
      app.send(:show_ruby_warning)
      app.window_mgr.stream['main'] = main_window
    end

    run_client(keyboard(without_main, 'x'))

    expect(main_rows.grep(first_line).size).to eq 1
  end

  context 'without a warning' do
    let(:ruby_warning) { nil }

    it 'shows nothing' do
      run_client(keyboard)

      expect(main_rows).to eq []
    end
  end
end
