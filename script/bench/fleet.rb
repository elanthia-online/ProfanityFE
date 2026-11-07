# frozen_string_literal: true

# Simulate many attached windows: run N replays of one build at the same
# time and report their total CPU, as cores, and the load average while
# they ran. See README.md.
#
# cores is the windows' total CPU over the median window's stream time
# (connect to close), so the staggered starts and the waits for each
# client to exit don't dilute it. It includes each window's startup (about
# 0.1-0.25 s), which matters only for short fixtures; server_cores leaves
# startup and the input loop out.
#
# Replay at --speed=1 (the default) for numbers that mean "N windows at
# this activity level"; faster replays crowd the same work into less time.
#
# usage: ruby script/bench/fleet.rb [--windows=N] [replay.rb options] FIXTURE.jsonl

require 'open3'
require_relative 'replay_runs'

# @return [Float, nil] the 1-minute load average, where the OS reports one
def load_average
  return File.read('/proc/loadavg').split.first.to_f if File.exist?('/proc/loadavg')

  out, status = Open3.capture2('sysctl', '-n', 'vm.loadavg')
  status.success? ? out[/[\d.]+/].to_f : nil
rescue StandardError
  nil
end

windows = 10
replay_options = []
fixture = nil
ARGV.each do |arg|
  if arg.start_with?('--windows=') then windows = arg.split('=', 2).last.to_i
  elsif arg.start_with?('--') then replay_options << arg
  else fixture = arg
  end
end
abort File.read(__FILE__)[/^# usage:.*?\n/] unless fixture && windows.positive?
code = replay_options.find { |o| o.start_with?('--code=') }&.split('=', 2)&.last
ReplayRuns.check_checkout(code ? File.expand_path(code) : File.expand_path('../..', __dir__))
ReplayRuns.stop_all_on_signal

loads = []
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
sample = -> { loads << [(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round, load_average] }
sampler = Thread.new do
  loop do
    sample.call
    sleep 5
  end
end
runs = Array.new(windows) do |i|
  sleep 0.2 # stagger the boots slightly, as windows opened by hand would be
  Thread.new do
    result, err = ReplayRuns.run("--label=window-#{i + 1}", *replay_options, fixture)
    warn "window #{i + 1}: replay failed: #{err.lines.last(3).join}" unless result
    result
  end
end.map(&:value)
sampler.kill
sample.call
results = runs.compact
abort "every replay failed (#{windows})" if results.empty?

median = ->(values) { values.sort[values.size / 2] }
cpu = results.map { |r| r['cpu_s'] }
server = results.map { |r| r.dig('counters', 'server_thread_cpu') || 0 }
stream = median.call(results.map { |r| r['stream_s'] })
puts JSON.generate(windows: results.size, failed: windows - results.size, stream_s: stream,
                   total_cpu_s: cpu.sum.round(3), cores: (cpu.sum / stream).round(3),
                   server_cores: (server.sum / stream).round(3), per_window_median_s: median.call(cpu),
                   per_window_min_s: cpu.min, per_window_max_s: cpu.max, load_average: loads)
exit 1 if results.size < windows
