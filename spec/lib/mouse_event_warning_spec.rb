# frozen_string_literal: true

# Tests MouseEventWarning.trigger_silently against a Curses.getmouse that
# behaves like the real one with the curses gem under Ruby 3.2 and later:
# the first call warns that Ruby is undefining the allocator of
# Curses::MouseEvent, and no later call warns, whether or not the first
# warning was printed. The stub warns with Kernel#warn, which, like the
# rb_warn Ruby uses, prints nothing while $VERBOSE is nil.
# spec/lib/curses_setup_spec.rb checks the same thing with the real curses
# library and the real client.

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
require_relative '../../lib/key_action_registry'
require_relative '../../lib/mouse_controller'
require_relative '../../lib/application'
require_relative '../../lib/mouse_event_warning'

RSpec.describe MouseEventWarning do
  let(:warning_text) { 'undefining the allocator of T_DATA class Curses::MouseEvent' }
  # $VERBOSE at each Curses.getmouse call.
  let(:verbose_at_getmouse) { [] }
  # What each Curses.getmouse call returns.
  let(:event) { nil }

  around do |example|
    verbose = $VERBOSE
    stderr = $stderr
    $stderr = StringIO.new
    example.run
  ensure
    $stderr = stderr
    $VERBOSE = verbose
  end

  before do
    allow(ProfanityLog).to receive(:write)
    used_up = false
    allow(Curses).to receive(:getmouse) do
      verbose_at_getmouse << $VERBOSE
      warn "warning: #{warning_text}" unless used_up
      used_up = true
      event
    end
  end

  # The client as the input loop sees it, with a text window under row 0,
  # so a mouse event goes through MouseController and MouseScroll.
  let(:app) do
    Application.new({ char: nil, no_status: true, links: true, room_window_only: false },
                    settings_file: File.join(SPEC_HOME, 'settings.xml'), host: '127.0.0.1', port: 8000)
  end

  # Read one mouse event the way the input loop does.
  def mouse_event_through_input_loop
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    LAYOUT['warning'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='4' width='42' value='main'/>
        <window class='command' top='5' left='0' height='1' width='42'/>
      </layout>
    XML
    app.window_mgr.load_layout('warning')
    app.cmd_buffer.window = app.window_mgr.command_window
    app.send(:handle_key, Curses::KEY_MOUSE, nil)
  end

  describe 'the first mouse event of a session' do
    let(:event) { Struct.new(:bstate, :y, :x).new(Curses::BUTTON1_CLICKED, 0, 4) }

    after { SelectionManager.clear_selection }

    # What the client did before MouseEventWarning: the warning went to
    # stderr, which curses shows on the screen.
    it 'prints the warning when nothing used it up first' do
      mouse_event_through_input_loop

      expect($stderr.string).to include(warning_text)
    end

    it 'prints nothing after trigger_silently, through the input loop' do
      described_class.trigger_silently
      mouse_event_through_input_loop

      expect($stderr.string).to eq ''
      expect(verbose_at_getmouse.size).to eq 2
    end

    it 'prints nothing after trigger_silently, through MouseScroll' do
      described_class.trigger_silently
      MouseScroll.new({}, ->(*) {}).process(Curses::KEY_MOUSE)

      expect($stderr.string).to eq ''
    end

    it 'reads mouse events with warnings on again, so later warnings still print' do
      $VERBOSE = false
      described_class.trigger_silently
      mouse_event_through_input_loop
      warn 'a later warning'

      expect(verbose_at_getmouse).to eq [nil, false]
      expect($stderr.string).to eq "a later warning\n"
    end
  end

  describe '.trigger_silently' do
    it 'calls getmouse once, with $VERBOSE nil' do
      described_class.trigger_silently

      expect(verbose_at_getmouse).to eq [nil]
      expect($stderr.string).to eq ''
    end

    [true, false, nil].each do |verbose|
      it "puts $VERBOSE back to #{verbose.inspect}" do
        $VERBOSE = verbose
        described_class.trigger_silently

        expect($VERBOSE).to be verbose
      end
    end

    it 'can be called again without printing anything' do
      2.times { described_class.trigger_silently }

      expect(verbose_at_getmouse).to eq [nil, nil]
      expect($stderr.string).to eq ''
    end

    it 'leaves a curses without mouse support alone' do
      allow(Curses).to receive(:respond_to?).and_call_original
      allow(Curses).to receive(:respond_to?).with(:getmouse).and_return(false)
      $VERBOSE = true

      expect { described_class.trigger_silently }.not_to raise_error
      expect(Curses).not_to have_received(:getmouse)
      expect($VERBOSE).to be true
    end

    describe 'when getmouse raises' do
      before do
        allow(Curses).to receive(:getmouse) do
          verbose_at_getmouse << $VERBOSE
          raise RuntimeError, 'no mouse here'
        end
      end

      [true, false, nil].each do |verbose|
        it "logs the error, goes on and puts $VERBOSE back to #{verbose.inspect}" do
          $VERBOSE = verbose

          expect { described_class.trigger_silently }.not_to raise_error
          expect($VERBOSE).to be verbose
          expect(verbose_at_getmouse).to eq [nil]
          expect(ProfanityLog).to have_received(:write)
            .with('mouse', 'Curses.getmouse failed at startup: RuntimeError: no mouse here')
          expect($stderr.string).to eq ''
        end
      end

      # Only StandardError is rescued: an interrupt (Ctrl+C during startup)
      # still stops the client, with $VERBOSE put back on the way out.
      it 'lets an Interrupt through and still puts $VERBOSE back' do
        allow(Curses).to receive(:getmouse) { raise Interrupt }
        $VERBOSE = false

        expect { described_class.trigger_silently }.to raise_error(Interrupt)
        expect($VERBOSE).to be false
        expect(ProfanityLog).not_to have_received(:write)
      end
    end
  end
end
