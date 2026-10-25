# frozen_string_literal: true

require 'tmpdir'
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
require_relative '../../lib/settings_loader'
require_relative '../../lib/cli_options'
require_relative '../support/client_run'

RSpec.describe 'Automatic layout selection in the running client' do
  include ClientRun

  let(:terminal) { { cols: 120, lines: 30 } }
  let(:options) { CliOptions.parse(['--no-status']) }
  let(:settings_path) { File.join(@dir, 'layouts.xml') }
  let(:app) { Application.new(options, settings_file: settings_path, host: '127.0.0.1', port: 8000) }
  let(:main) { app.window_mgr.stream.fetch('main') }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    # Minimal synthetic layouts: no personal template or game-specific settings.
    layouts = { 'mobile' => 0, 'default' => 5, 'wide' => 10 }.map do |id, left|
      <<~XML
        <layout id='#{id}'>
          <window class='tabbed' top='0' left='#{left}' width='cols-#{left}' height='lines-1' tabs='main,combat'/>
          <window class='command' top='lines-1' left='0' width='cols' height='1'/>
        </layout>
      XML
    end
    File.write(settings_path, "<settings>#{layouts.join}</settings>")
    allow(ProfanityLog).to receive(:write)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    allow(Curses).to receive(:cols) { terminal[:cols] }
    allow(Curses).to receive(:lines) { terminal[:lines] }
  end

  it 'selects at startup and preserves history, tabs and input across width tiers' do
    original = nil
    run_client(keyboard(
                 press_after('d') do
                   expect(main.begx).to eq 5
                   original = main
                   main.add_string_to_tab('main', 'Keep this history.')
                 end,
                 'raft',
                 press_after(Curses::KEY_RESIZE) { terminal[:cols] = 60 },
                 press_after('!') do
                   app.key_action.fetch('resize').call
                   expect(main.begx).to eq 0
                   expect(main).to equal(original)
                   expect(main.rows.join).to include('Keep this history.')
                 end,
                 press_after(Curses::KEY_RESIZE) { terminal[:cols] = 200 },
                 press_after('!') do
                   app.key_action.fetch('resize').call
                   expect(main.begx).to eq 10
                   expect(main).to equal(original)
                   expect(main.tab_names).to eq %w[main combat]
                   expect(main.rows.join).to include('Keep this history.')
                 end
               ))
    expect(app.cmd_buffer.window.row(0)).to include('draft!!')
    expect(game_server.commands).to be_empty
  end

  it 'uses the existing resize path without rebuilding within one tier' do
    run_client(keyboard(press_after('a') do
      original = main
      terminal[:cols] = 130
      expect(app.window_mgr).not_to receive(:load_layout)
      app.key_action.fetch('resize').call
      expect(main).to equal(original)
    end))
  end

  it 'holds manual choices, leaves invalid choices unchanged, and resumes auto' do
    run_client(keyboard(press_after('a') do
      app.execute_command('.layout mobile')
      terminal[:cols] = 200
      app.key_action.fetch('resize').call
      expect(main.begx).to eq 0
      app.execute_command('.layout nonexistent')
      app.key_action.fetch('resize').call
      expect(main.begx).to eq 0
      app.execute_command('.layout auto')
      expect(main.begx).to eq 10
    end))
    expect(game_server.commands).to be_empty
  end

  it 'does not auto-switch when disabled on the command line' do
    options[:auto_layout] = false
    terminal[:cols] = 200
    run_client(keyboard(press_after('a') do
      expect(main.begx).to eq 5
      terminal[:cols] = 60
      app.key_action.fetch('resize').call
      expect(main.begx).to eq 5
    end))
  end

  { 89 => 0, 90 => 5, 159 => 5, 160 => 10 }.each do |cols, left|
    it "selects the correct startup layout at #{cols} columns" do
      terminal[:cols] = cols
      run_client(keyboard(press_after('a') { expect(main.begx).to eq left }))
    end
  end
end
