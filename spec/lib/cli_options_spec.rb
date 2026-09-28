# frozen_string_literal: true

require 'pty'
require 'socket'
require 'timeout'
require_relative '../../lib/cli_options'

RSpec.describe CliOptions do
  describe '.parse' do
    it 'returns the defaults for an empty command line' do
      expect(described_class.parse([])).to eq(described_class::DEFAULTS)
    end

    it 'turns profiling on for --profile and for any abbreviation the parser accepts' do
      %w[--profile --profil --prof].each do |flag|
        expect(described_class.parse([flag])[:profile]).to be(true), "#{flag} did not enable profiling"
      end
    end

    it 'leaves profiling off by default' do
      expect(described_class.parse(['--char=Mahtra'])[:profile]).to be(false)
    end

    it 'raises on an ambiguous abbreviation' do
      expect { described_class.parse(['--p']) }.to raise_error(OptionParser::AmbiguousOption)
    end

    it 'does not change DEFAULTS' do
      described_class.parse(['--port=9000'])
      expect(described_class::DEFAULTS[:port]).to eq(8000)
    end
  end

  describe '.parse_or_exit' do
    it 'prints a one-line error and a usage hint to stderr and exits 1 on a bad option' do
      status = nil
      expect do
        described_class.parse_or_exit(['--bogus'], program: 'profanity.rb')
      rescue SystemExit => e
        status = e.status
      end.to output("profanity.rb: invalid option: --bogus\n" \
                    "Try 'profanity.rb --help' for the list of options.\n").to_stderr
      expect(status).to eq(1)
    end

    it 'returns the options when the command line is valid' do
      expect(described_class.parse_or_exit(['--port=9000'])[:port]).to eq(9000)
    end
  end
end

# The real client, run in a pseudo-terminal the way a player starts it.
RSpec.describe 'profanity.rb command line' do
  let(:repo) { File.expand_path('../..', __dir__) }
  let(:env) { { 'TERM' => 'xterm-256color', 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR) } }

  # Run profanity.rb with +args+ until it exits.
  #
  # @return [Array(String, Integer)] everything written to the terminal, and
  #   the exit status
  def run_client(*args)
    output = +''
    status = nil
    PTY.spawn(env, RbConfig.ruby, File.join(repo, 'profanity.rb'), *args, chdir: Dir.home) do |reader, _writer, pid|
      Timeout.timeout(20) do
        loop { output << reader.readpartial(4096) }
      rescue EOFError, Errno::EIO
        nil
      end
      _, status = Process.wait2(pid)
    end
    [output, status.exitstatus]
  end

  # An escape character on the terminal means curses started (or at least
  # sent its terminal setup), which a command-line error must not do.
  it 'reports an unknown option on the normal terminal and exits 1' do
    output, status = run_client('--bogus')

    expect(status).to eq(1)
    expect(output).to include("profanity.rb: invalid option: --bogus\r\n" \
                              "Try 'profanity.rb --help' for the list of options.")
    expect(output).not_to include('OptionParser::InvalidOption')
    expect(output).not_to include("\e")
  end

  it 'reports an invalid option value on the normal terminal and exits 1' do
    output, status = run_client('--port=abc')

    expect(status).to eq(1)
    expect(output).to include('profanity.rb: invalid argument: --port=abc')
    expect(output).not_to include("\e")
  end

  it 'prints --help on the normal terminal, where it stays visible' do
    output, status = run_client('--help')

    expect(status).to eq(0)
    expect(output).to include('--settings-file=FILE', '--profile')
    expect(output).not_to include("\e")
  end

  it 'reports a missing settings file on the normal terminal and exits 1' do
    output, status = run_client('--settings-file=/nonexistent/profanity.xml')

    expect(status).to eq(1)
    expect(output).to include('Settings file not found: /nonexistent/profanity.xml')
    expect(output).not_to include("\e")
  end

  it 'logs boot timings when started with --prof, an abbreviation of --profile' do
    server = TCPServer.new('127.0.0.1', 0)
    accepted = Thread.new { server.accept }
    dir = Dir.mktmpdir('profanity-cli-spec')
    log = File.join(dir, 'profanity.log')
    args = ['--prof', "--port=#{server.addr[1]}", "--log-file=#{log}",
            "--settings-file=#{File.join(repo, 'templates', 'default.xml')}"]

    logged = false
    PTY.spawn(env, RbConfig.ruby, File.join(repo, 'profanity.rb'), *args, chdir: Dir.home) do |reader, _writer, pid|
      drain = Thread.new do
        reader.each_char { nil }
      rescue Errno::EIO
        nil
      end
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      until (logged = File.exist?(log) && File.read(log).include?('Startup timing')) ||
            Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end
    ensure
      begin
        Process.kill('KILL', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      drain&.kill
    end

    expect(logged).to be(true)
  ensure
    accepted&.kill
    server&.close
    FileUtils.remove_entry(dir) if dir
  end
end
