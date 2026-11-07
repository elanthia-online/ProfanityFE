# frozen_string_literal: true

# Replay a captured stream into the real profanity.rb and report the CPU
# the client used. See README.md.
#
# The client runs unmodified in a pseudo-terminal, with its own temporary
# HOME (so ~/.profanity is untouched), against a fake Lich server on a
# local port. The server sends each chunk of the fixture (made by
# stream_fixture.rb) at its recorded time divided by --speed, at least
# --gap seconds after the previous chunk, so the client sees the stream
# arrive in bursts as it does from Lich and flushes the screen between
# them. When the stream ends the server closes the connection and the
# client exits through its "Press any key" prompt.
#
# Prints one JSON line: label, lines, chunks, cpu_s (whole process,
# startup included), utime, stime, us_per_line (cpu_s / lines, so startup
# too), tty_bytes (what the client wrote to the terminal), stream_s (from
# connect to close), wall_s (the whole run), and counters
# (server_thread_cpu, and highlights with --count-highlights). Exits
# non-zero, with the end of what the terminal showed, when the client
# does not connect, stops reading, or ends without writing its report.
#
# usage: ruby script/bench/replay.rb [options] FIXTURE.jsonl [-- profanity.rb options]
#   ruby script/bench/replay.rb --help

require 'json'
require 'optparse'
require 'pty'
require 'io/console'
require 'io/wait'
require 'socket'
require 'tmpdir'
require 'fileutils'
require 'rbconfig'

repo = File.expand_path('../..', __dir__)
options = {
  code: repo, settings: File.join(repo, 'templates', 'default.xml'), speed: 1.0, gap: 0.003,
  rows: 60, cols: 230, idle: nil, resizes: 0, label: nil, ruby: RbConfig.ruby, connect_timeout: 30, write_timeout: 60
}
client_args = []
if (dashes = ARGV.index('--'))
  client_args = ARGV[(dashes + 1)..]
  ARGV.slice!(dashes..)
end
parser = OptionParser.new do |o|
  o.banner = 'usage: ruby script/bench/replay.rb [options] FIXTURE.jsonl [-- profanity.rb options]'
  o.on('--code=DIR', 'ProfanityFE checkout to run (default: this one)') { |v| options[:code] = File.expand_path(v) }
  o.on('--settings=FILE', 'settings XML the client loads (default: templates/default.xml)') { |v| options[:settings] = File.expand_path(v) }
  o.on('--speed=N', Float, 'replay N times faster than recorded (default 1)') { |v| options[:speed] = v }
  o.on('--gap=SECONDS', Float, 'least time between chunks (default 0.003)') { |v| options[:gap] = v }
  o.on('--rows=N', Integer, 'terminal rows (default 60)') { |v| options[:rows] = v }
  o.on('--cols=N', Integer, 'terminal columns (default 230)') { |v| options[:cols] = v }
  o.on('--idle=SECONDS', Float, 'send nothing; stay connected this long (FIXTURE may be -)') { |v| options[:idle] = v }
  o.on('--resizes=N', Integer, 'after the stream, resize the terminal N times, 1.5 s apart') { |v| options[:resizes] = v }
  o.on('--label=NAME', 'label for the JSON output') { |v| options[:label] = v }
  o.on('--ruby=PATH', 'Ruby to run the client with (default: this one)') { |v| options[:ruby] = v }
  o.on('--write-timeout=SECONDS', Float, 'give up when the client stops reading this long (default 60)') do |v|
    options[:write_timeout] = v
  end
  o.on('--vernier=FILE', 'write a per-thread vernier report here') { |v| options[:vernier] = File.expand_path(v) }
  o.on('--stackprof=FILE', 'write a stackprof dump here') { |v| options[:stackprof] = File.expand_path(v) }
  o.on('--count-highlights', 'count apply_highlights calls, repeats and CPU') { options[:count_highlights] = true }
end
parser.parse!
fixture = ARGV.first
abort parser.help unless fixture && (options[:idle] || File.file?(fixture))
abort '--speed must be above 0' unless options[:speed].positive?
abort "no profanity.rb in #{options[:code]}" unless File.file?(File.join(options[:code], 'profanity.rb'))
abort "no settings file #{options[:settings]}" unless File.file?(options[:settings])

chunks = options[:idle] ? [] : File.readlines(fixture).reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
label = options[:label] || (options[:idle] ? 'idle' : File.basename(fixture, '.jsonl'))
# What the terminal showed, without escape sequences, for error messages.
terminal_text = lambda do |raw|
  text = raw.gsub(/\e\[[\d;?]*[a-zA-Z]/, '').gsub(/\e[()][AB0-2]|\e[=>]/, '')
  text.size > 2000 ? text[-2000..] : text
end
home = Dir.mktmpdir('pfe-bench-home')
FileUtils.mkdir_p(File.join(home, '.profanity'))
FileUtils.cp(options[:settings], File.join(home, '.profanity', 'bench.xml'))
report = File.join(home, 'report.json')
server = TCPServer.new('127.0.0.1', 0)

env = {
  'HOME' => home, 'TERM' => 'screen-256color', 'TERMCAP' => nil, 'LANG' => 'en_US.UTF-8',
  'RUBYOPT' => "-r#{File.join(__dir__, 'profile_preload.rb')}",
  # The temporary HOME hides gems installed under the real one (curses); keep the real path.
  'GEM_PATH' => [ENV.fetch('GEM_PATH', nil), *Gem.path].compact.join(File::PATH_SEPARATOR),
  'PFE_BENCH_OUT' => report, 'PFE_BENCH_VERNIER' => options[:vernier], 'PFE_BENCH_STACKPROF' => options[:stackprof],
  'PFE_BENCH_COUNT_HIGHLIGHTS' => options[:count_highlights] ? '1' : nil
}
command = [options[:ruby], '-W0', File.join(options[:code], 'profanity.rb'), "--port=#{server.addr[1]}",
           '--config=bench', '--char=Bench', *(client_args.empty? ? ['--game=DR'] : client_args)]

tty_bytes = 0
tty_tail = +''
sent_lines = 0
status = nil
stream_s = nil
wall_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
begin
  PTY.spawn(env, *command) do |reader, writer, pid|
    reader.winsize = [options[:rows], options[:cols]]
    drain = Thread.new do
      loop do
        data = reader.readpartial(65_536)
        tty_bytes += data.bytesize
        tty_tail << data
        tty_tail = tty_tail[-8000..] if tty_tail.size > 16_000
      end
    rescue EOFError, Errno::EIO
      nil
    end
    # Wait for the client to connect; give up when it exits first (a bad
    # option, a missing gem) or takes too long, and show what it printed.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + options[:connect_timeout]
    until server.wait_readable(0.2)
      exited = Process.waitpid(pid, Process::WNOHANG)
      next unless exited || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      Process.kill('TERM', pid) unless exited
      drain.join(1)
      abort "profanity.rb did not connect (#{exited ? 'it exited' : "#{options[:connect_timeout]} s passed"}); " \
            "the terminal showed:\n#{terminal_text.call(tty_tail)}"
    end
    socket = server.accept
    # A client that stops reading would block a write forever.
    socket.timeout = options[:write_timeout]
    Thread.new { loop { socket.readpartial(4096) } rescue nil } # discard what the client sends

    start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    last = 0.0
    chunks.each do |chunk|
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      wait = [start + (chunk['t'] / options[:speed]) - now, last + options[:gap] - now].max
      sleep(wait) if wait.positive?
      socket.write(chunk['data'])
      sent_lines += chunk['data'].count("\n")
      last = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    rescue IO::TimeoutError
      Process.kill('TERM', pid)
      abort "profanity.rb stopped reading for #{options[:write_timeout]} s after #{sent_lines} lines; the terminal showed:\n" \
            "#{terminal_text.call(tty_tail)}"
    end
    sleep(options[:idle]) if options[:idle]
    options[:resizes].times do |i|
      reader.winsize = i.even? ? [options[:rows] - 7, options[:cols] - 31] : [options[:rows], options[:cols]]
      Process.kill('WINCH', pid)
      sleep 1.5
    end
    sleep 1.0 # let the last burst draw
    socket.close
    stream_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
    # The client shows "Press any key to exit" once it has caught up with
    # the stream, which may be well after the close; keep pressing a key
    # until it exits, rather than once into the void.
    until (status = Process.wait2(pid, Process::WNOHANG)&.last)
      writer.write('q') rescue nil
      sleep 0.25
    end
    drain.join(2)
  end
  wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - wall_start
  unless status.success? && File.exist?(report)
    abort "profanity.rb ended badly (#{status.inspect}#{', no report written' unless File.exist?(report)}); " \
          "the terminal showed:\n#{terminal_text.call(tty_tail)}"
  end
  measured = JSON.parse(File.read(report))
  cpu = measured['cpu']
  puts JSON.generate(label: label, lines: sent_lines, chunks: chunks.size, cpu_s: cpu.round(4),
                     utime: measured['utime']&.round(4), stime: measured['stime']&.round(4),
                     us_per_line: sent_lines.positive? ? (cpu * 1e6 / sent_lines).round(1) : nil,
                     tty_bytes: tty_bytes, stream_s: stream_s.round(2), wall_s: wall.round(1),
                     counters: measured['counters'] || {})
ensure
  server.close
  FileUtils.rm_rf(home)
end
