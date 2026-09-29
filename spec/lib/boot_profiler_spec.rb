# frozen_string_literal: true

# Tests the --profile boot timings: BootProfiler on its own, and the lines
# the real Application#run and GameTextProcessor#run log through the
# profiler they are given. profanity.rb creates the profiler; lib reads no
# profiling constant of its own.

require 'socket'
require 'rexml/document'
require_relative '../spec_helper'
require_relative '../../lib/boot_profiler'
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
require_relative '../../lib/event_bus'

RSpec.describe BootProfiler do
  # A clock that returns +readings+ (seconds) in turn and counts its calls.
  def clock_reading(*readings)
    calls = 0
    clock = lambda do
      calls += 1
      raise 'clock read more often than expected' if readings.empty?

      readings.shift
    end
    [clock, -> { calls }]
  end

  let(:log) { [] }

  before do
    allow(ProfanityLog).to receive(:write) { |context, message, **| log << [context, message] }
  end

  context 'when enabled' do
    it 'records each mark as [label, ms since creation], rounded to 0.1 ms' do
      clock, = clock_reading(10.0, 10.00004, 10.01234, 11.5)
      profiler = described_class.new(enabled: true, clock: clock)

      profiler.mark('stdlib loaded')
      profiler.mark('curses init')
      profiler.mark('Application.new')

      expect(profiler.timings).to eq [['stdlib loaded', 0.0], ['curses init', 12.3], ['Application.new', 1500.0]]
      expect(log).to be_empty
    end

    it 'logs the marks, with the time since start and since the previous mark' do
      clock, = clock_reading(0.0, 0.0012, 0.0501, 0.0503, 1.2)
      profiler = described_class.new(enabled: true, clock: clock)
      %w[a b c d].each { |label| profiler.mark(label) }

      profiler.log_timings

      expect(log).to eq [['boot-profile', <<~TEXT.chomp]]
        Startup timing:
              1.2ms (+   1.2ms)  a
             50.1ms (+  48.9ms)  b
             50.3ms (+   0.2ms)  c
           1200.0ms (+1149.7ms)  d
      TEXT
    end

    it 'logs an event with the time since start straight away, without recording it' do
      clock, = clock_reading(5.0, 5.0421)
      profiler = described_class.new(enabled: true, clock: clock)

      profiler.log_elapsed('first prompt (sent look)')

      expect(log).to eq [['boot-profile', 'first prompt (sent look): 42.1ms']]
      expect(profiler.timings).to be_empty
    end

    it 'logs a summary with no rows when nothing was marked' do
      profiler = described_class.new(enabled: true, clock: clock_reading(0.0).first)

      profiler.log_timings

      expect(log).to eq [['boot-profile', "Startup timing:\n"]]
    end

    it 'measures from the default monotonic clock' do
      profiler = described_class.new(enabled: true)
      profiler.mark('x')

      expect(profiler.timings.first.last).to be_a(Float).and be >= 0.0
      expect(profiler.elapsed_ms).to be >= profiler.timings.first.last
    end
  end

  context 'when disabled' do
    it 'records and logs nothing, and never reads the clock' do
      clock, calls = clock_reading
      profiler = described_class.new(enabled: false, clock: clock)

      profiler.mark('curses init')
      profiler.log_elapsed('first screen render')
      profiler.log_timings

      expect(profiler).not_to be_enabled
      expect(profiler.timings).to be_empty
      expect(profiler.elapsed_ms).to be_nil
      expect(log).to be_empty
      expect(calls.call).to eq 0
    end

    it 'treats a nil flag (option not given) as disabled' do
      expect(described_class.new(enabled: nil)).not_to be_enabled
    end
  end

  describe 'GameTextProcessor#run' do
    let(:event_bus) { EventBus.new }
    let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }

    # Feed raw server lines through the real server loop.
    def receive_from_server(*lines, **profiler)
      wm = Struct.new(:stream, :indicator, :progress, :countdown, :room,
                      :command_window, :command_window_layout).new({ 'main' => Object.new }, {}, {}, {}, {}, nil, nil)
      processor = GameTextProcessor.new(
        window_mgr: wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
        xml_escapes: { '&gt;' => '>', '&lt;' => '<' }, event_bus: event_bus, **profiler
      )
      queue = lines.map { |line| "#{line}\r\n" }
      server = Object.new
      server.define_singleton_method(:gets) { queue.shift&.dup }
      server.define_singleton_method(:puts) { |*| nil }
      server.define_singleton_method(:flush) { self }
      allow(IO).to receive(:select).and_return(nil)
      processor.run(server)
    end

    let(:session) { ['A goblin waves.', '<prompt time="1700000000">&gt;</prompt>', 'A goblin waves.', '<prompt time="1700000001">&gt;</prompt>'] }

    it 'logs the first server data, first screen render and first prompt once each, in the order they happen' do
      clock, = clock_reading(0.0, 0.001, 0.002, 0.003)
      receive_from_server(*session, boot_profiler: described_class.new(enabled: true, clock: clock))

      expect(log).to eq [
        ['boot-profile', 'first server data received: 1.0ms'],
        ['boot-profile', 'first screen render: 2.0ms'],
        ['boot-profile', 'first prompt (sent look): 3.0ms']
      ]
    end

    it 'logs nothing with a disabled profiler' do
      clock, calls = clock_reading
      receive_from_server(*session, boot_profiler: described_class.new(enabled: false, clock: clock))

      expect(log).to be_empty
      expect(calls.call).to eq 0
    end

    it 'logs nothing when given no profiler' do
      receive_from_server(*session)

      expect(log).to be_empty
    end
  end

  describe 'Application' do
    let(:cli_options) { { char: nil, no_status: true, links: false, room_window_only: false } }

    def application(**profiler)
      Application.new(cli_options, settings_file: File.join(SPEC_HOME, 'settings.xml'),
                                   host: '127.0.0.1', port: 8000, **profiler)
    end

    it "marks 'Application.new' and each startup step of #run, then logs the summary before reading keys" do
      steps = []
      profiler = described_class.new(enabled: true, clock: clock_reading(0.0, 0.001, 0.002, 0.003, 0.004).first)
      allow(profiler).to(receive(:mark).and_wrap_original do |original, label|
        steps << label
        original.call(label)
      end)
      app = application(boot_profiler: profiler)
      %i[load_settings_and_layout connect_server start_server_thread].each do |step|
        allow(app).to receive(step) { steps << step }
      end
      allow(app).to receive(:input_loop) { steps << :input_loop << log.dup }

      app.run

      expect(steps[0..-2]).to eq ['Application.new', :load_settings_and_layout, 'settings + layout',
                                  :connect_server, 'connect_server', :start_server_thread,
                                  'server thread started', :input_loop]
      expect(steps.last).to eq [['boot-profile', <<~TEXT.chomp]]
        Startup timing:
              1.0ms (+   1.0ms)  Application.new
              2.0ms (+   1.0ms)  settings + layout
              3.0ms (+   1.0ms)  connect_server
              4.0ms (+   1.0ms)  server thread started
      TEXT
    end

    it 'passes its profiler to the GameTextProcessor' do
      profiler = described_class.new(enabled: false)
      app = application(boot_profiler: profiler)
      app.connection.attach(StringIO.new)
      allow(GameTextProcessor).to receive(:new).and_call_original

      app.send(:start_server_thread).join

      expect(GameTextProcessor).to have_received(:new).with(a_hash_including(boot_profiler: profiler))
    end

    it 'logs no startup timing when given no profiler' do
      app = application
      %i[load_settings_and_layout connect_server start_server_thread input_loop].each do |step|
        allow(app).to receive(step)
      end

      app.run

      expect(log).to be_empty
    end
  end
end
