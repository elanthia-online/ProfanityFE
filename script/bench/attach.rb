# frozen_string_literal: true

# Attach real ProfanityFE windows to running Lich sessions for a while and
# measure what they cost: each window's CPU, each Lich's CPU over the same
# time, and the load average. Linux only (reads /proc). See README.md.
#
# This is the live counterpart of fleet.rb: the same client against real
# game streams. Each window runs in its own pseudo-terminal with its own
# temporary HOME and the given settings file. Nothing is typed into any
# window, so nothing is sent to the game. Windows get 5 s to boot and
# connect before measuring starts; a window whose client has exited by
# then (a wrong port, say) is reported under "failed" and left out of the
# totals. At the end, or as soon as the 1-minute load average goes over
# --max-load, every window this script started is sent TERM; nothing else
# is touched.
#
# Lich needs a detachable-client listener that accepts several clients at
# once if a window is already attached to a session (Lich 5.23 does).
#
# usage: ruby script/bench/attach.rb [--code=DIR] [--settings=FILE] [--seconds=120]
#          [--max-load=12] [--label=NAME] NAME:PORT:LICH_PID ... [-- profanity.rb options]

require 'json'
require 'optparse'
require 'pty'
require 'io/console'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

repo = File.expand_path('../..', __dir__)
options = { code: repo, settings: File.join(repo, 'templates', 'default.xml'), seconds: 120.0,
            max_load: 12.0, label: 'attach', ruby: RbConfig.ruby }
client_args = []
if (dashes = ARGV.index('--'))
  client_args = ARGV[(dashes + 1)..]
  ARGV.slice!(dashes..)
end
parser = OptionParser.new do |o|
  o.banner = 'usage: ruby script/bench/attach.rb [options] NAME:PORT:LICH_PID ... [-- profanity.rb options]'
  o.on('--code=DIR', 'ProfanityFE checkout to run (default: this one)') { |v| options[:code] = File.expand_path(v) }
  o.on('--settings=FILE', 'settings XML (default: templates/default.xml)') { |v| options[:settings] = File.expand_path(v) }
  o.on('--seconds=N', Float, 'how long to measure (default 120)') { |v| options[:seconds] = v }
  o.on('--max-load=N', Float, 'stop early above this 1-minute load (default 12)') { |v| options[:max_load] = v }
  o.on('--label=NAME', 'label for the JSON output') { |v| options[:label] = v }
  o.on('--ruby=PATH', 'Ruby to run the client with (default: this one)') { |v| options[:ruby] = v }
end
parser.parse!
abort parser.help if ARGV.empty?
abort 'attach.rb reads /proc and runs on Linux only' unless File.directory?('/proc/self')
abort "no profanity.rb in #{options[:code]}" unless File.file?(File.join(options[:code], 'profanity.rb'))
abort "no settings file #{options[:settings]}" unless File.file?(options[:settings])
targets = ARGV.map do |target|
  name, port, lich = target.split(':')
  unless name && port.to_s.match?(/\A\d+\z/) && lich.to_s.match?(/\A\d+\z/)
    abort "bad target #{target.inspect}: want NAME:PORT:LICH_PID"
  end
  abort "no process #{lich} (Lich for #{name})" unless File.exist?("/proc/#{lich}/stat")

  { name: name, port: Integer(port), lich: Integer(lich) }
end

clock_ticks = Integer(`getconf CLK_TCK`.strip) rescue 100
# User + system CPU ticks of a process (fields 14 and 15 of /proc/PID/stat,
# counted after the command name, which may hold spaces and parentheses),
# or nil once it is gone.
cpu_ticks = lambda do |pid|
  File.read("/proc/#{pid}/stat").split(') ').last.split[11, 2].sum(&:to_i)
rescue Errno::ENOENT, Errno::ESRCH
  nil
end
load_average = -> { File.read('/proc/loadavg').split.first.to_f }
monotonic = -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }

home = Dir.mktmpdir('pfe-attach-home')
windows = []
elapsed = 0.0
loads = []
aborted = false
begin
  FileUtils.mkdir_p(File.join(home, '.profanity'))
  FileUtils.cp(options[:settings], File.join(home, '.profanity', 'bench.xml'))
  env = { 'HOME' => home, 'TERM' => 'screen-256color', 'TERMCAP' => nil, 'LANG' => 'en_US.UTF-8',
          'GEM_PATH' => [ENV.fetch('GEM_PATH', nil), *Gem.path].compact.join(File::PATH_SEPARATOR) }
  targets.each do |target|
    reader, _writer, pid = PTY.spawn(env, options[:ruby], '-W0', File.join(options[:code], 'profanity.rb'),
                                     "--port=#{target[:port]}", "--char=#{target[:name].capitalize}", '--config=bench',
                                     *(client_args.empty? ? ['--game=DR'] : client_args))
    reader.winsize = [60, 230]
    window = target.merge(pid: pid, bytes: 0)
    window[:drain] = Thread.new do
      loop { window[:bytes] += reader.readpartial(65_536).bytesize }
    rescue EOFError, Errno::EIO
      nil
    end
    windows << window
  end

  sleep 5
  windows.each do |w|
    w[:failed] = !Process.waitpid(w[:pid], Process::WNOHANG).nil?
    w[:client_before] = cpu_ticks.call(w[:pid])
    w[:lich_before] = cpu_ticks.call(w[:lich])
  end
  started = monotonic.call
  while (elapsed = monotonic.call - started) < options[:seconds]
    sleep [10, options[:seconds] - elapsed].min
    loads << [(monotonic.call - started).round, load_average.call]
    next unless loads.last[1] > options[:max_load]

    aborted = true
    break
  end
  elapsed = monotonic.call - started
  windows.each do |w|
    w[:client_after] = cpu_ticks.call(w[:pid])
    w[:lich_after] = cpu_ticks.call(w[:lich])
  end
ensure
  windows.each { |w| Process.kill('TERM', w[:pid]) rescue nil }
  windows.each do |w|
    Process.wait(w[:pid]) rescue nil
    w[:drain].kill
  end
  FileUtils.rm_rf(home)
end

seconds = lambda do |w, which|
  before = w[:"#{which}_before"]
  after = w[:"#{which}_after"]
  before && after ? (after - before).fdiv(clock_ticks) : nil
end
live, failed = windows.partition { |w| !w[:failed] }
rows = live.map do |w|
  { name: w[:name], profanity_cpu_s: seconds.call(w, :client), lich_cpu_s: seconds.call(w, :lich), tty_bytes: w[:bytes] }
end
client = rows.filter_map { |r| r[:profanity_cpu_s] }.sort
lich = rows.filter_map { |r| r[:lich_cpu_s] }
puts JSON.generate(label: options[:label], windows: rows.size, failed: failed.map { |w| w[:name] },
                   seconds: elapsed.round(1), aborted: aborted, loads: loads,
                   profanity_total_cores: (client.sum / elapsed).round(3),
                   profanity_median_pct: client.empty? ? nil : (100 * client[client.size / 2] / elapsed).round(2),
                   profanity_max_pct: client.empty? ? nil : (100 * client.last / elapsed).round(2),
                   lich_total_cores: (lich.sum / elapsed).round(3), rows: rows)
exit 1 unless failed.empty?
