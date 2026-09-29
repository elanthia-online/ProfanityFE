# frozen_string_literal: true

require 'open3'
require 'pty'
require 'socket'
require 'timeout'
require 'tmpdir'
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

    it 'leaves the game unknown without --game' do
      expect(described_class.parse([])[:game]).to be_nil
    end

    # Any case; Lich's longer codes (test, fallen, platinum) start the same way
    {
      'DR' => 'DR', 'dr' => 'DR', 'DRT' => 'DR', 'drf' => 'DR',
      'GS' => 'GS', 'gs4' => 'GS', 'GSX' => 'GS', 'GS4X' => 'GS', 'gst' => 'GS', 'GSF' => 'GS'
    }.each do |code, game|
      it "takes --game=#{code} as the code #{code.upcase}, #{game}'s rules" do
        options = described_class.parse(["--game=#{code}"])

        expect(options[:game]).to eq code.upcase
        expect(Games.rules_for(options[:game])).to be(game == 'DR' ? Games::DragonRealms : Games::GemStone)
      end
    end

    it 'refuses a --game no game code starts with, like any invalid value' do
      ['--game=XX', '--game=', '--game=D', '--game= DR', '--game=ADR'].each do |arg|
        expect { described_class.parse([arg]) }.to raise_error(OptionParser::InvalidArgument), "#{arg} was accepted"
      end
      expect { described_class.parse(['--game']) }.to raise_error(OptionParser::MissingArgument)
    end

    it 'does not change DEFAULTS' do
      described_class.parse(['--port=9000'])
      expect(described_class::DEFAULTS[:port]).to eq(8000)
    end
  end

  describe '.parse_command_line' do
    # profanity.rb prints the message and exits 1; the parser itself prints
    # nothing and doesn't exit.
    it 'raises UsageError with a one-line error and a usage hint on a bad option' do
      expect { described_class.parse_command_line(['--bogus'], program: 'profanity.rb') }
        .to raise_error(described_class::UsageError,
                        "profanity.rb: invalid option: --bogus\n" \
                        "Try 'profanity.rb --help' for the list of options.")
        .and output('').to_stderr
    end

    it 'raises UsageError for an invalid value, a missing argument and an ambiguous abbreviation' do
      {
        ['--port=abc'] => 'profanity.rb: invalid argument: --port=abc',
        ['--port']     => 'profanity.rb: missing argument: --port',
        ['--p']        => 'profanity.rb: ambiguous option: --p',
        ['--game=XX']  => 'profanity.rb: invalid argument: --game=XX',
      }.each do |argv, first_line|
        expect { described_class.parse_command_line(argv, program: 'profanity.rb') }
          .to raise_error(described_class::UsageError, /\A#{Regexp.escape(first_line)}\n/)
      end
    end

    it 'names the running program by default' do
      expect { described_class.parse_command_line(['--bogus']) }
        .to raise_error(described_class::UsageError, /\A#{Regexp.escape(File.basename($PROGRAM_NAME))}: invalid option/)
    end

    it 'returns the options when the command line is valid' do
      expect(described_class.parse_command_line(['--port=9000'])[:port]).to eq(9000)
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
    expect(output).to include('--settings-file=FILE', '--profile', '--game=CODE')
    expect(output).not_to include("\e")
  end

  it 'reports a missing settings file on the normal terminal and exits 1' do
    output, status = run_client('--settings-file=/nonexistent/profanity.xml')

    expect(status).to eq(1)
    expect(output).to include('Settings file not found: /nonexistent/profanity.xml')
    expect(output).not_to include("\e")
  end

  it 'reports a missing template on the normal terminal and exits 1' do
    output, status = run_client('--template=NoSuch.xml')

    expect(status).to eq(1)
    expect(output).to include("Template not found: #{File.join(repo, 'templates', 'NoSuch.xml')}")
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

  # Run profanity.rb with +args+ on a wide terminal against a fake game
  # server that sends +lines+, until the terminal shows +pattern+ (or 20s).
  #
  # @return [String] everything written to the terminal
  def terminal_after_server_lines(args, lines, pattern)
    server = TCPServer.new('127.0.0.1', 0)
    sender = Thread.new do
      client = server.accept
      client.write(lines.map { |line| "#{line}\r\n" }.join)
      sleep
    ensure
      client&.close
    end
    output = +''
    wide = env.merge('COLUMNS' => '240', 'LINES' => '50')
    command = [RbConfig.ruby, File.join(repo, 'profanity.rb'), "--port=#{server.addr[1]}",
               "--settings-file=#{File.join(repo, 'templates', 'default.xml')}", *args]
    PTY.spawn(wide, *command, chdir: Dir.home) do |reader, _writer, pid|
      Timeout.timeout(20) do
        output << reader.readpartial(4096) until output.match?(pattern)
      rescue EOFError, Errno::EIO, Timeout::Error
        nil
      end
    ensure
      begin
        Process.kill('KILL', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end
    output
  ensure
    sender&.kill
    server&.close
  end

  describe '--game' do
    # A Bloodriven bank death ending in "!": DragonRealms' "failed within
    # .*!" catch-all and GemStone's DR-B area both match it.
    let(:death_lines) do
      ['<pushStream id="death"/> * Mahtra failed within the Bank at Bloodriven!<popStream/>',
       '<prompt time="1790000000">&gt;</prompt>']
    end

    it 'applies only GemStone\'s rules with --game=GS' do
      output = terminal_after_server_lines(['--game=GS'], death_lines, /Mahtra[^\e]*\e/)

      expect(output[/Mahtra[^\e]*/]).to eq 'Mahtra DR-B'
    end

    it 'applies both games\' rules, DragonRealms first, without --game' do
      output = terminal_after_server_lines([], death_lines, /Mahtra[^\e]*\e/)

      expect(output[/Mahtra[^\e]*/]).to eq 'Mahtra'
    end
  end

  # The log path is resolved before the rest of lib is loaded. Without
  # --char or --log-file it falls back to DEFAULT_LOG_FILE, which crashed
  # the client with a NameError before it could connect.
  it 'starts and connects without --char or --log-file' do
    server = TCPServer.new('127.0.0.1', 0)
    accepted = Queue.new
    acceptor = Thread.new { accepted << server.accept }
    args = ["--port=#{server.addr[1]}", "--settings-file=#{File.join(repo, 'templates', 'default.xml')}"]

    output = +''
    connected = nil
    PTY.spawn(env, RbConfig.ruby, File.join(repo, 'profanity.rb'), *args, chdir: Dir.home) do |reader, _writer, pid|
      drain = Thread.new do
        reader.each_char { |c| output << c }
      rescue Errno::EIO
        nil
      end
      connected = Timeout.timeout(20) { accepted.pop }
    rescue Timeout::Error
      nil
    ensure
      begin
        Process.kill('KILL', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      drain&.kill
    end

    expect(connected).to be_a(TCPSocket), "client never connected; terminal showed:\n#{output}"
    expect(output).not_to include('NameError')
  ensure
    connected&.close
    acceptor&.kill
    server&.close
  end
end

# lib/profanity_settings.rb is loaded on its own, before the rest of lib,
# so it must not depend on constants that only other files define.
RSpec.describe 'ProfanitySettings loaded on its own' do
  it 'resolves the default log file in the current directory' do
    repo = File.expand_path('../..', __dir__)
    script = "require #{File.join(repo, 'lib', 'profanity_settings').inspect}; puts ProfanitySettings.resolve_log"
    Dir.mktmpdir('profanity-settings-alone') do |dir|
      output, status = Open3.capture2e(RbConfig.ruby, '-e', script, chdir: dir)

      expect(status).to be_success, output
      expect(output.lines.last.chomp).to eq(File.join(File.realpath(dir), 'profanity.log'))
    end
  end
end
