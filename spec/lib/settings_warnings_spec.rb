# frozen_string_literal: true

# SettingsWarnings on its own, then through the real client
# (Application#run on the virtual screen): a problem in the settings or the
# layout is written to the log and shown in the main window, never printed
# to stderr, which curses draws over the client's screen.

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
require_relative '../../lib/settings_warnings'
# The real GagPatterns over spec_helper's stub, so a bad gag warns.
original_verbose = $VERBOSE
$VERBOSE = nil
require_relative '../../lib/gag_patterns'
$VERBOSE = original_verbose
require_relative '../support/client_run'

RSpec.describe SettingsWarnings do
  before { allow(ProfanityLog).to receive(:write) }

  describe '.add and .take' do
    it 'logs a warning and keeps it until it is taken' do
      described_class.add('Invalid gag pattern: ( - bad')

      expect(ProfanityLog).to have_received(:write).with('settings', 'Invalid gag pattern: ( - bad').once
      expect(described_class.take).to eq ['Invalid gag pattern: ( - bad']
      expect(described_class.take).to eq []
    end

    it 'keeps warnings in the order they came' do
      %w[one two three].each { |message| described_class.add(message) }

      expect(described_class.take).to eq %w[one two three]
    end

    it 'reports the same message once, logged once, even after it was taken' do
      described_class.add('same')
      described_class.add('same')
      expect(described_class.take).to eq ['same']

      described_class.add('same')

      expect(described_class.take).to eq []
      expect(ProfanityLog).to have_received(:write).once
    end

    it 'reports a message again after forget_reported' do
      described_class.add('same')
      described_class.take
      described_class.forget_reported(:settings)

      described_class.add('same')

      expect(described_class.take).to eq ['same']
      expect(ProfanityLog).to have_received(:write).twice
    end

    it 'does not queue a message twice when it is added again before it was taken' do
      described_class.add('same')
      described_class.forget_reported(:settings)
      described_class.add('same')

      expect(described_class.take).to eq ['same']
    end

    it 'forgets only the messages of the kind it is given' do
      described_class.add('bad gag')
      described_class.add('bad expression', kind: :layout)
      described_class.take

      described_class.forget_reported(:settings)
      described_class.add('bad gag')
      described_class.add('bad expression', kind: :layout)
      expect(described_class.take).to eq ['bad gag']

      described_class.forget_reported(:layout)
      described_class.add('bad gag')
      described_class.add('bad expression', kind: :layout)
      expect(described_class.take).to eq ['bad expression']
    end

    it 'refuses a kind it does not know, adding nothing' do
      expect { described_class.add('x', kind: :layouts) }.to raise_error(ArgumentError, /unknown warning kind :layouts/)
      expect(described_class.take).to eq []
      expect(ProfanityLog).not_to have_received(:write)
    end

    it 'refuses to forget a kind it does not know, forgetting nothing' do
      described_class.add('bad gag')
      described_class.take

      expect { described_class.forget_reported(:setting) }.to raise_error(ArgumentError, /unknown warning kind :setting/)
      described_class.add('bad gag')
      expect(described_class.take).to eq []
    end

    # Layout expressions are checked again by .layout, not .reload, so both
    # of SafeArithmetic's warnings must be layout warnings.
    { 'unsafe characters' => 'cols*2.5', 'a malformed call' => 'min(1)' }.each do |problem, expr|
      it "reports a layout expression with #{problem} as a layout warning" do
        SafeArithmetic.evaluate(expr)
        expect(described_class.take.size).to eq 1

        described_class.forget_reported(:settings)
        SafeArithmetic.evaluate(expr)
        expect(described_class.take).to eq []

        described_class.forget_reported(:layout)
        SafeArithmetic.evaluate(expr)
        expect(described_class.take.size).to eq 1
      end
    end

    it 'drops pending warnings and reported messages on reset' do
      described_class.add('gone')
      described_class.reset

      expect(described_class.take).to eq []
      described_class.add('gone')
      expect(described_class.take).to eq ['gone']
    end

    it 'takes each distinct warning exactly once when many threads add them' do
      messages = Array.new(20) { |i| "warning #{i}" }
      threads = Array.new(8) { Thread.new { 50.times { messages.each { |message| described_class.add(message) } } } }
      taken = []
      taken.concat(described_class.take) while threads.any?(&:alive?)
      threads.each(&:join)
      taken.concat(described_class.take)

      expect(taken.sort).to eq messages.sort
      expect(ProfanityLog).to have_received(:write).exactly(20).times
    end
  end

  describe 'in the client' do
    include ClientRun

    let(:settings_path) { File.join(@dir, 'given.xml') }
    let(:app) do
      Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                      settings_file: settings_path, host: '192.0.2.10', port: 8000)
    end
    let(:main) { app.window_mgr.stream['main'] }
    let(:gag_warning) { /\A\* Invalid gag pattern: \(unclosed - end pattern with unmatched/ }
    let(:width_warning) { /\A\* Invalid layout expression \(unsafe characters\): cols\*2\.5\z/ }

    around do |example|
      Dir.mktmpdir { |dir| @dir = dir; example.run }
    end

    before do
      allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
      File.write(settings_path, settings(gag: '(unclosed'))
    end

    # A settings file with Enter bound to send the command line, one gag,
    # and a layout whose thoughts window has an expression that can't be
    # worked out (so it is left out).
    def settings(gag:)
      <<~XML
        <settings>
          <gag>#{gag}</gag>
          <key id='enter' action='send_command'/>
          <layout id='default'>
            <window class='text' value='main' top='0' left='0' height='12' width='70'/>
            <window class='text' value='thoughts' top='12' left='0' height='4' width='cols*2.5'/>
            <window class='command' top='16' left='0' height='1' width='70'/>
          </layout>
        </settings>
      XML
    end

    # The main window's rows that start a warning (a long one wraps onto
    # the next row).
    def warnings_shown = main.rows.select { |row| row.start_with?('* ') }

    it 'shows each problem in the main window at startup, logs it, and prints nothing' do
      status, stderr = run_client(keyboard)

      expect(stderr).to eq ''
      expect(status).to be_nil.or eq(0)
      expect(warnings_shown).to match [a_string_matching(gag_warning), a_string_matching(width_warning)]
      expect(ProfanityLog).to have_received(:write).with('settings', a_string_starting_with('Invalid gag pattern: (unclosed'))
    end

    it 'shows a problem again on .reload while it is still there' do
      run_client(keyboard(".reload\n"))

      expect(warnings_shown.grep(gag_warning).size).to eq 2
    end

    it 'shows nothing new on .reload once the problem is fixed' do
      fix_the_file = -> { File.write(settings_path, settings(gag: '^A bat squeaks')) }

      run_client(keyboard(fix_the_file, ".reload\n"))

      expect(warnings_shown.grep(gag_warning).size).to eq 1
    end

    # The expression is worked out again for each new terminal size; the
    # warning names it as written, so a new size is not a new warning.
    it 'does not repeat a layout warning when the terminal is resized to new sizes' do
      resize_to_new_sizes = lambda do
        [90, 100, 110].each do |cols|
          allow(Curses).to receive(:cols).and_return(cols)
          app.window_mgr.resize(app.cmd_buffer)
        end
      end

      run_client(keyboard(resize_to_new_sizes, 'x'))

      expect(warnings_shown.grep(width_warning).size).to eq 1
    end

    # .reload checks the settings file again, not the layout: a layout
    # warning it forgot would come back on the next resize instead.
    it 'does not show a layout problem again after .reload, even on the next resize' do
      resize = lambda do
        allow(Curses).to receive(:cols).and_return(95)
        app.window_mgr.resize(app.cmd_buffer)
      end

      run_client(keyboard(".reload\n", resize, 'x'))

      expect(warnings_shown.grep(width_warning).size).to eq 1
    end

    it 'shows a layout problem again on .layout' do
      run_client(keyboard(".layout default\n", 'x'))

      expect(warnings_shown.grep(width_warning).size).to eq 2
    end

    it 'shows a layout problem again on .layout, but not on .reload' do
      run_client(keyboard(".reload\n", ".layout default\n", 'x'))

      expect(warnings_shown.grep(width_warning).size).to eq 2
      expect(warnings_shown.grep(gag_warning).size).to eq 2
    end

    # A warning taken with nowhere to show it used to be lost from the
    # screen, and the dedup kept it from coming back.
    it 'keeps warnings while there is no main window, and shows them once there is one' do
      without_main = lambda do
        main_window = app.window_mgr.stream.delete('main')
        SettingsWarnings.add('Invalid gag pattern: [later - premature end of char-class')
        app.send(:show_settings_warnings)
        app.window_mgr.stream['main'] = main_window
      end

      run_client(keyboard(without_main, 'x'))

      expect(warnings_shown).to include('* Invalid gag pattern: [later - premature end of char-class')
    end
  end
end
