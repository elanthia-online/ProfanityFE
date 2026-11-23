# frozen_string_literal: true

# Tabs are keyed as the game connection keys a stream id
# (Streams.from_settings: % and each character outside ASCII as %XX), so a
# tab named "loot%" is keyed "loot%25". .tab with a name, typed as the
# layout writes it, must select that tab, and the tab bar must show the
# name, not the key. Runs the real client (Application#run) on the virtual
# screen.

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

RSpec.describe 'Tabs named with a %' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'given.xml') }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '192.0.2.10', port: 8000)
  end
  let(:tabbed) { app.window_mgr.stream['main'] }

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
          <window class='tabbed' top='0' left='0' height='8' width='80' tabs='main,loot%,loot%25'/>
          <window class='command' top='8' left='0' height='1' width='80'/>
        </layout>
      </settings>
    XML
  end

  # The tab active after each step, as its name.
  def active_after(*commands)
    active = []
    steps = commands.flat_map { |command| [command, -> { active << ServerText.readable(tabbed.active_tab) }] }
    run_client(keyboard(*steps, 'x'))
    active
  end

  it 'selects the tab .tab names, as the layout writes the name' do
    expect(active_after(".tab loot%\n", ".tab loot%25\n", ".tab main\n")).to eq %w[loot% loot%25 main]
  end

  context 'with tabs named with a character outside ASCII' do
    # "cafe" with an acute e (the source is ASCII)
    let(:cafe) { "caf#{[0xE9].pack('U')}" }

    before do
      File.write(settings_path, <<~XML)
        <settings>
          <key id='enter' action='send_command'/>
          <layout id='default'>
            <window class='tabbed' top='0' left='0' height='8' width='80' tabs='main,#{cafe},caf?'/>
            <window class='command' top='8' left='0' height='1' width='80'/>
          </layout>
        </settings>
      XML
    end

    it 'shows each tab by the name the layout wrote, in the tab bar and the .tab list' do
      run_client(keyboard(".tab\n", 'x'))

      expect(tabbed.rows.first).to include("2:#{cafe}", '3:caf?')
      expect(tabbed.rows.map(&:to_s).join("\n")).to include("* Tabs: 1:main* 2:#{cafe} 3:caf?")
    end

    it 'selects each tab by the name it shows' do
      keys = []
      run_client(keyboard(".tab #{cafe}\n", -> { keys << tabbed.active_tab },
                          ".tab caf?\n", -> { keys << tabbed.active_tab }, 'x'))

      expect(keys).to eq %w[caf%C3%A9 caf?]
    end
  end

  it 'shows the tab names, not their keys, in the tab bar' do
    run_client(keyboard('x'))

    expect(tabbed.rows.first).to include('1:main', '2:loot%', '3:loot%25')
    expect(tabbed.rows.first).not_to include('loot%2525')
  end
end
