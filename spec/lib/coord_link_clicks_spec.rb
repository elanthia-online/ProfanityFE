# frozen_string_literal: true

# Clicks on GemStone coord links in the real client (Application#run) on
# the virtual screen, links on: what reaches the game server. With no
# command table from the server, a coord link sends nothing; with one, it
# sends the table's command; a link without a coord is unchanged.
#
# The exits and offer lines are real GemStone lines (GSIV-Ilten/
# 2026-10-01_21-00-59.xml:36, two of its exits; GSF-Pickasso/
# 2026-10-01_21-27-24.xml:2488, cut after DECLINE). No log has a
# <cmdlist>: the one below is in the form Saga 6c2079e's parser reads.

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

RSpec.describe 'Clicking a GemStone coord link' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: true, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:main) { app.window_mgr.stream['main'] }
  let(:mouse_events) { [] }

  let(:exits_line) do
    'Obvious paths: <a exist="-11069569" coord="2524,1864" noun="northeast">northeast</a>, ' \
      '<a exist="-11069569" coord="2524,1864" noun="east">east</a>'
  end
  let(:offer_line) do
    '<a exist="-11165808" noun="Nexushealbot">Nexushealbot</a> offers you crackers.  Click ' \
      '<a exist="-11165808" coord="2524,1753" noun="">ACCEPT</a> or ' \
      '<a exist="-11165808" coord="2524,1755" noun="">DECLINE</a>.'
  end

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    allow(ProfanityLog).to receive(:write)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    allow(Curses).to receive(:getmouse) { mouse_events.shift }
    SelectionManager.clear_selection
    File.write(settings_path, <<~XML)
      <settings>
        <layout id='default'>
          <window class='text' top='0' left='0' height='6' width='120' value='main'/>
          <window class='command' top='7' left='0' height='1' width='120'/>
        </layout>
      </settings>
    XML
  end

  after { SelectionManager.clear_selection }

  # Keyboard steps: wait for main to show +text+, then click (press and
  # release) on its character at +offset+.
  def click_on(text, offset: 0)
    shown = -> { main.rows.any? { |row| row.include?(text) } }
    press = lambda do |bstate|
      press_after(Curses::KEY_MOUSE) do
        y = main.rows.rindex { |row| row.include?(text) }
        mouse_events << Struct.new(:bstate, :y, :x).new(bstate, y, main.rows[y].index(text) + offset)
      end
    end
    [wait_until(&shown), press[Curses::BUTTON1_PRESSED], press[Curses::BUTTON1_RELEASED]]
  end

  it 'sends nothing for an exit, ACCEPT or DECLINE when no command table arrived, and keeps other links' do
    game_server.say(exits_line, offer_line)

    run_client(keyboard(*click_on('northeast'), *click_on(' east', offset: 1),
                        *click_on('ACCEPT'), *click_on('DECLINE'), *click_on('Nexushealbot')))

    expect(game_server.commands).to eq ['look #-11165808']
  end

  it "sends the command table's command for each coord link" do
    game_server.say('<cmdlist><cli coord="2524,1864" menu="go @" command="go @" menu_cat="4"/>' \
                    '<cli coord="2524,1753" menu="accept" command="accept" menu_cat="0"/></cmdlist>',
                    exits_line, offer_line)

    run_client(keyboard(*click_on('northeast'), *click_on('ACCEPT'), *click_on('DECLINE')))

    expect(game_server.commands).to eq %w[go\ northeast accept]
  end
end
