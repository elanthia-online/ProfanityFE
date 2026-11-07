# frozen_string_literal: true

require 'json'
require 'open3'
require 'socket'
require 'tmpdir'
require 'rbconfig'
require 'fileutils'
require_relative '../../../script/bench/stream_fixture'

# The benchmark tools run end to end, as a developer runs them: the real
# profanity.rb in a pseudo-terminal, fed by replay.rb's fake Lich server.
RSpec.describe 'script/bench tools' do
  let(:repo) { File.expand_path('../../..', __dir__) }
  let(:bench) { File.join(repo, 'script', 'bench') }
  let(:env) { { 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR) } }

  around do |example|
    Dir.mktmpdir('pfe-bench-spec') do |dir|
      @dir = dir
      example.run
    end
  end

  # Run a bench tool and return [stdout, stderr, status]. A tool still
  # running after +timeout+ seconds is ended and the example fails, so a
  # hang shows as a failure instead of stalling the suite.
  def tool(name, *args, timeout: 60)
    Open3.popen3(env, RbConfig.ruby, File.join(bench, name), *args, chdir: repo) do |stdin, stdout, stderr, wait|
      stdin.close
      out = Thread.new { stdout.read }
      err = Thread.new { stderr.read }
      unless wait.join(timeout)
        Process.kill('TERM', wait.pid) rescue nil
        wait.join(5) || (Process.kill('KILL', wait.pid) rescue nil)
        raise "#{name} #{args.join(' ')} still running after #{timeout} s"
      end
      [out.value, err.value, wait.value]
    end
  end

  # A fixture made from a stream in spec/fixtures, paced fast.
  def session_fixture
    path = File.join(@dir, 'session.jsonl')
    _, err, status = tool('stream_fixture.rb', File.join(repo, 'spec/fixtures/stream_routing_session.xml'), path, '--rate=400')
    raise err unless status.success?

    path
  end

  # A stand-in checkout whose profanity.rb connects to the replay server and
  # then does +behaviour+: 'exit3' reads to EOF and exits 3; 'stall' stops
  # reading and sleeps; 'two_keys' reads to EOF, then waits for two key
  # presses (as a client still catching up would miss the first) and exits 0.
  def stub_checkout(behaviour)
    dir = File.join(@dir, "stub-#{behaviour}")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'profanity.rb'), <<~RUBY)
      require 'socket'
      require 'io/console'
      port = ARGV.find { |a| a.start_with?('--port=') }.split('=').last
      socket = TCPSocket.new('127.0.0.1', port.to_i)
      case #{behaviour.inspect}
      when 'stall' then sleep 120
      when 'two_keys'
        socket.read
        $stdin.raw { 2.times { $stdin.getc } }
      else
        socket.read
        exit 3
      end
    RUBY
    dir
  end

  # PIDs of the benchmark clients (replay.rb's --char=Bench) running under
  # +root+, at any depth. Only this example's processes count, so bench
  # clients another checkout or suite run starts at the same time don't.
  def bench_clients_under(root)
    table = `ps -A -o pid=,ppid=,args=`.lines.map do |line|
      pid, ppid, args = line.strip.split(/\s+/, 3)
      [pid.to_i, ppid.to_i, args.to_s]
    end
    found = []
    parents = [root]
    until parents.empty?
      children = table.select { |_, ppid, _| parents.include?(ppid) }
      found.concat(children)
      parents = children.map(&:first)
    end
    found.select { |_, _, args| args.include?('--config=bench --char=Bench') }.map(&:first)
  end

  # @return [Boolean] whether this bench client is still running: ps lists
  # the PID, not as a zombie (an exited client its parent hasn't reaped),
  # and still with a bench client's command line (not a reused PID)
  def bench_client_running?(pid)
    stat, args = `ps -o stat=,args= -p #{pid}`.strip.split(/\s+/, 2)
    !stat.nil? && !stat.start_with?('Z') && args.to_s.include?('--config=bench --char=Bench')
  end

  describe 'replay.rb' do
    it 'replays a fixture into the real client and reports its CPU' do
      out, err, status = tool('replay.rb', '--speed=10', session_fixture)

      expect(status).to be_success, err
      result = JSON.parse(out.lines.last)
      expect(result).to include('label' => 'session', 'lines' => 75, 'chunks' => File.readlines(session_fixture).size)
      expect(result['cpu_s']).to be > 0
      expect(result.dig('counters', 'server_thread_cpu')).to be > 0
      expect(result['tty_bytes']).to be > 1000
    end

    it 'counts highlight calls when asked' do
      out, err, status = tool('replay.rb', '--speed=10', '--count-highlights', session_fixture)

      expect(status).to be_success, err
      expect(JSON.parse(out.lines.last).dig('counters', 'highlights', 'calls')).to be > 0
    end

    it 'measures a connected client that receives nothing' do
      out, err, status = tool('replay.rb', '--idle=0.5', '-')

      expect(status).to be_success, err
      result = JSON.parse(out.lines.last)
      expect(result).to include('lines' => 0, 'chunks' => 0)
      expect(result.dig('counters', 'server_thread_cpu')).to be < 0.05
    end

    it 'fails with the terminal output when the client cannot start' do
      out, err, status = tool('replay.rb', '--speed=10', session_fixture, '--', '--bogus')

      expect(status).not_to be_success
      expect(out).to be_empty
      expect(err).to include('did not connect (it exited)').and include('--bogus')
    end

    it 'reports a client that ends badly instead of printing a result' do
      out, err, status = tool('replay.rb', '--speed=10', "--code=#{stub_checkout('exit3')}", session_fixture)

      expect(status).not_to be_success
      expect(out).to be_empty
      expect(err).to include('ended badly').and include('exit 3')
    end

    it 'keeps pressing a key until the client exits, not once into the void' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out, err, status = tool('replay.rb', '--speed=10', "--code=#{stub_checkout('two_keys')}", session_fixture, timeout: 20)

      expect(status).to be_success, err
      expect(JSON.parse(out.lines.last)['lines']).to eq(75)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 15
    end

    it 'gives up on a client that stops reading' do
      big = File.join(@dir, 'big.jsonl')
      File.write(big, Array.new(200) { |i| JSON.generate('t' => 0, 'data' => "#{'x' * 60_000}#{i}\n") }.join("\n"))

      out, err, status = tool('replay.rb', '--gap=0', '--write-timeout=2', "--code=#{stub_checkout('stall')}", big)

      expect(status).not_to be_success
      expect(out).to be_empty
      expect(err).to include('stopped reading for 2.0 s')
    end

    it 'ignores blank lines in a fixture, and refuses a speed of 0' do
      padded = File.join(@dir, 'padded.jsonl')
      File.write(padded, "\n#{File.read(session_fixture)}\n\n")

      out, err, status = tool('replay.rb', '--speed=10', padded)
      expect(status).to be_success, err
      expect(JSON.parse(out.lines.last)['lines']).to eq(75)

      _, err, status = tool('replay.rb', '--speed=0', session_fixture)
      expect(status).not_to be_success
      expect(err).to include('--speed must be above 0')
    end

    it 'refuses a missing settings file before starting anything' do
      _, err, status = tool('replay.rb', '--settings=/nonexistent.xml', session_fixture)

      expect(status).not_to be_success
      expect(err).to include('no settings file /nonexistent.xml')
    end
  end

  describe 'compare.rb' do
    it 'replays two checkouts together and prints both, the second against the first' do
      out, err, status = tool('compare.rb', '--rounds=1', '--speed=10', session_fixture, "a=#{repo}", "b=#{repo}")

      expect(status).to be_success, err
      expect(out).to match(/^a\s+cpu \S+\s+server \S+/)
      expect(out).to match(/^b\s+cpu .* server vs a: [+-]\d+\.\d%/)
    end
  end

  describe 'compare.rb with a failing build' do
    it 'exits non-zero, after printing the builds that worked' do
      out, err, status = tool('compare.rb', '--rounds=1', '--speed=10', session_fixture, "good=#{repo}",
                              "bad=#{stub_checkout('exit3')}")

      expect(status).not_to be_success
      expect(out).to match(/^good\s+cpu \d/)
      expect(err).to include('bad: replay failed').and include('1 replay(s) failed')
    end

    it 'refuses a directory that is not a checkout before replaying anything' do
      _, err, status = tool('compare.rb', '--rounds=1', session_fixture, "a=#{repo}", "b=#{@dir}")

      expect(status).not_to be_success
      expect(err).to include("no profanity.rb in #{@dir}")
    end
  end

  describe 'fleet.rb' do
    it 'runs several windows at once and sums their CPU' do
      out, err, status = tool('fleet.rb', '--windows=2', '--speed=10', session_fixture)

      expect(status).to be_success, err
      result = JSON.parse(out.lines.last)
      expect(result['windows']).to eq(2)
      expect(result['total_cpu_s']).to be > 0
    end
  end

  describe 'fleet.rb stopped part way' do
    it 'ends every replay and client it started when sent TERM' do
      slow = File.join(@dir, 'slow.jsonl')
      File.write(slow, Array.new(40) { |i| JSON.generate('t' => i, 'data' => "Line #{i}.\n") }.join("\n"))
      pid = Process.spawn(env, RbConfig.ruby, File.join(bench, 'fleet.rb'), '--windows=2', slow, chdir: repo,
                                                                                                  out: File::NULL, err: File::NULL)
      clients = []
      300.times do
        clients = bench_clients_under(pid)
        break if clients.size == 2

        sleep 0.1
      end
      expect(clients.size).to eq(2)
      Process.kill('TERM', pid)
      Process.wait(pid)
      # The clients are checked by PID: one left behind would no longer be
      # under fleet.rb, so a search from it would miss it.
      50.times do
        break if clients.none? { |client| bench_client_running?(client) }

        sleep 0.1
      end

      expect(clients.select { |client| bench_client_running?(client) }).to be_empty
      expect(`ps -eo args`.lines.grep(/replay\.rb .*#{Regexp.escape(slow)}/)).to be_empty
    end
  end

  describe 'record.rb' do
    it 'records what a Lich port sends, in the log format stream_fixture.rb reads' do
      server = TCPServer.new('127.0.0.1', 0)
      lich = Thread.new do
        client = server.accept
        client.write("You hobble north.\r\n<prompt time=\"1\">&gt;</prompt>\r\n")
        sleep 2
        client.close
      end
      out_file = File.join(@dir, 'recorded.xml')

      _, err, status = tool('record.rb', server.addr[1].to_s, '1', out_file)
      lich.join

      expect(status).to be_success, err
      recorded = File.readlines(out_file, chomp: true)
      expect(recorded.size).to eq(2)
      expect(recorded).to all(match(StreamFixture::TIMESTAMP))
      chunks = StreamFixture.new.convert(recorded)
      expect(chunks.map { |c| c['data'] }.join).to eq("You hobble north.\n<prompt time=\"1\">&gt;</prompt>\n")
    ensure
      server&.close
    end
  end

  describe 'record.rb with a line left unfinished' do
    it 'stops on time and keeps the partial line' do
      server = TCPServer.new('127.0.0.1', 0)
      lich = Thread.new do
        client = server.accept
        client.write("full line\r\npartial, no newline")
        sleep 5
        client.close
      end
      out_file = File.join(@dir, 'partial.xml')

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      _, err, status = tool('record.rb', server.addr[1].to_s, '1', out_file)
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(status).to be_success, err
      expect(took).to be < 4
      expect(File.readlines(out_file, chomp: true).map { |l| l.sub(StreamFixture::TIMESTAMP, '') }).to eq(['full line', 'partial, no newline'])
    ensure
      lich&.kill
      server&.close
    end
  end

  describe 'attach.rb' do
    it 'refuses to run off Linux, where there is no /proc' do
      skip 'this is Linux' if File.directory?('/proc/self')

      _, err, status = tool('attach.rb', "one:1:#{Process.pid}")

      expect(status).not_to be_success
      expect(err).to include('Linux only')
    end

    context 'on Linux' do
      before { skip 'attach.rb reads /proc' unless File.directory?('/proc/self') }

      # Temporary homes attach.rb has left behind.
      def attach_homes
        Dir.glob(File.join(Dir.tmpdir, 'pfe-attach-home*'))
      end

      it 'refuses a bad target before starting or creating anything' do
        homes = attach_homes

        _, err, status = tool('attach.rb', "good:1:#{Process.pid}", 'bad:1')

        expect(status).not_to be_success
        expect(err).to include('bad target "bad:1"')
        expect(attach_homes).to eq(homes)
      end

      it 'measures a window attached to a session, and lists one that could not connect as failed' do
        server = TCPServer.new('127.0.0.1', 0)
        sessions = []
        lich = Thread.new do
          loop do
            client = server.accept
            sessions << Thread.new(client) do |c|
              40.times do |i|
                c.write("Line #{i}.\r\n<prompt time=\"#{i}\">&gt;</prompt>\r\n")
                sleep 0.1
              end
              sleep 30
            end
          end
        end
        closed = TCPServer.new('127.0.0.1', 0)
        closed_port = closed.addr[1]
        closed.close
        homes = attach_homes

        out, err, status = tool('attach.rb', '--seconds=2', "alive:#{server.addr[1]}:#{Process.pid}",
                                "dead:#{closed_port}:#{Process.pid}")

        expect(status.exitstatus).to eq(1), err
        result = JSON.parse(out.lines.last)
        expect(result).to include('windows' => 1, 'failed' => ['dead'], 'aborted' => false)
        expect(result['rows'].first).to include('name' => 'alive')
        expect(result['rows'].first['profanity_cpu_s']).to be >= 0
        expect(result['rows'].first['lich_cpu_s']).to be >= 0
        expect(attach_homes).to eq(homes)
        expect(`ps -eo args`.lines.grep(/--char=(Alive|Dead) /)).to be_empty
      ensure
        lich&.kill
        sessions&.each(&:kill)
        server&.close
      end
    end
  end

  describe 'filter_dump.rb' do
    it 'shows what the real gag filter keeps, the same twice over for the same checkout' do
      settings = File.join(@dir, 'gags.xml')
      File.write(settings, "<settings>\n<gag>drums his fingers</gag>\n</settings>\n")
      dumps = %w[first second].map do |name|
        path = File.join(@dir, "#{name}.txt")
        _, err, status = tool('filter_dump.rb', repo, settings, path, session_fixture)
        raise err unless status.success?

        File.read(path)
      end

      expect(dumps.first).to eq(dumps.last)
      with_phrase = File.readlines(File.join(repo, 'spec/fixtures/stream_routing_session.xml')).grep(/drums his fingers/).size
      gagged = dumps.first.lines.grep(/\A\d G /)
      expect(with_phrase).to be_positive
      expect(gagged.size).to eq(2 * with_phrase) # each line with the phrase, once per pass
      expect(dumps.first.lines.size).to eq(150)
    end

    it 'reads a log with invalid UTF-8 as the client would, replacing the bad bytes' do
      log = File.join(@dir, 'bad.xml')
      File.binwrite(log, "2026-11-07 19:15:00 NZDT\n2026-11-07 19:15:01 NZDT: caf#{233.chr} line\n")
      out_file = File.join(@dir, 'bad.txt')

      _, err, status = tool('filter_dump.rb', repo, File.join(repo, 'templates/default.xml'), out_file, log)

      expect(status).to be_success, err
      expect(File.read(out_file).lines.first).to eq("0 - \"caf#{[0xFFFD].pack('U')} line\"\n")
    end
  end
end
