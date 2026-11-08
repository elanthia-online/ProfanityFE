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

    it 'leaves --rich-stream off by default' do
      expect(described_class.parse(['--char=Mahtra'])[:rich_stream]).to be(false)
    end

    it 'turns the capability declaration on for --rich-stream' do
      expect(described_class.parse(['--rich-stream'])[:rich_stream]).to be(true)
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

    # --char and --config name files in ~/.profanity (<name>.xml, <name>.log),
    # so a value that is a path (or that a path can't hold) is refused
    # before it can name a file anywhere else.
    %w[char config].each do |option|
      it "refuses a --#{option} that isn't one part of a file name" do
        ["--#{option}=../evil", "--#{option}=a/b", "--#{option}=a\\b", "--#{option}="].each do |arg|
          expect { described_class.parse([arg]) }.to raise_error(OptionParser::InvalidArgument), "#{arg.inspect} was accepted"
        end
      end

      it "keeps a --#{option} name as typed" do
        %w[Mahtra mahtra-alt Mahtra.2 ..].each do |name|
          expect(described_class.parse(["--#{option}=#{name}"])[option.to_sym]).to eq name
        end
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

    # Under a UTF-8 locale an argument with bytes that aren't UTF-8 made
    # OptionParser raise ArgumentError, and the client ended with a Ruby
    # backtrace. The bytes are shown as "?".
    describe 'with an argument that is not valid text' do
      let(:bad_byte) { [0xFF].pack('C') }

      def utf8(text) = text.dup.force_encoding(Encoding::UTF_8)

      it 'raises UsageError naming the argument, whether it is an option value, an option or anything else' do
        {
          "--char=caf#{bad_byte}" => '--char=caf?', "--bo#{bad_byte}gus" => '--bo?gus', "x#{bad_byte}y" => 'x?y'
        }.each do |arg, shown|
          expect { described_class.parse_command_line(['--port=9000', utf8(arg)], program: 'profanity.rb') }
            .to raise_error(described_class::UsageError,
                            "profanity.rb: invalid argument: #{shown} (not valid UTF-8 text)\n" \
                            "Try 'profanity.rb --help' for the list of options.")
        end
      end

      it 'names the first such argument, wherever it is, and its encoding' do
        expect { described_class.parse_command_line([utf8("a#{bad_byte}"), '--port=9000', utf8("b#{bad_byte}")], program: 'p') }
          .to raise_error(described_class::UsageError, /\Ap: invalid argument: a\? \(not valid UTF-8 text\)\n/)
        expect { described_class.parse_command_line(['--char', utf8("caf#{bad_byte}")], program: 'p') }
          .to raise_error(described_class::UsageError, /\Ap: invalid argument: caf\? /)

        sjis = "caf#{bad_byte}".dup.force_encoding(Encoding::Windows_31J)
        expect { described_class.parse_command_line(["--char=#{sjis}".dup.force_encoding(Encoding::Windows_31J)], program: 'p') }
          .to raise_error(described_class::UsageError, /\(not valid Windows-31J text\)/)
      end

      # The parser stops at "--", and --help exits before it reads further.
      it 'leaves alone an argument the parser never reaches, after "--" or after --help' do
        expect(described_class.parse_command_line(['--port=9000', '--', utf8("caf#{bad_byte}")])[:port]).to eq 9000
        expect { described_class.parse_command_line(['--help', utf8("caf#{bad_byte}")]) }
          .to raise_error(SystemExit) { |exit| expect(exit.status).to eq 0 }
          .and output(/--char=NAME/).to_stdout
      end

      it 'lets an ArgumentError through when every argument is valid text' do
        allow(described_class).to receive(:parse).and_raise(ArgumentError, 'something else')

        expect { described_class.parse_command_line(['--port=9000']) }.to raise_error(ArgumentError, 'something else')
      end

      it 'leaves valid UTF-8, and bytes from a locale without an encoding (LANG=C), to the parser' do
        cafe = [0x43, 0x61, 0x66, 0xE9].pack('U*')

        expect(described_class.parse_command_line(["--char=#{cafe}"])[:char]).to eq cafe
        expect(described_class.parse_command_line(["--char=caf#{bad_byte}".b])[:char]).to eq "caf#{bad_byte}".b
      end
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

  # Everything profanity.rb started with +args+ sends to a game server that
  # sends it nothing, read until it has been quiet for a second, and the
  # client's PID.
  #
  # @return [Array(String, Integer)]
  def bytes_sent_on_connect(*args)
    server = TCPServer.new('127.0.0.1', 0)
    dir = Dir.mktmpdir('profanity-cli-spec')
    args += ["--port=#{server.addr[1]}", "--log-file=#{File.join(dir, 'profanity.log')}",
             "--settings-file=#{File.join(repo, 'templates', 'default.xml')}"]
    bytes = +''
    client_pid = nil
    PTY.spawn(env, RbConfig.ruby, File.join(repo, 'profanity.rb'), *args, chdir: Dir.home) do |reader, _writer, pid|
      client_pid = pid
      drain = Thread.new do
        reader.each_char { nil }
      rescue Errno::EIO
        nil
      end
      client = Timeout.timeout(20) { server.accept }
      bytes << client.read_nonblock(4096) while client.wait_readable(bytes.empty? ? 20 : 1)
    rescue EOFError
      nil
    ensure
      client&.close
      begin
        Process.kill('KILL', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      drain&.kill
    end
    [bytes, client_pid]
  ensure
    server&.close
    FileUtils.remove_entry(dir) if dir
  end

  it 'sends only its PID on connect without --rich-stream' do
    bytes, pid = bytes_sent_on_connect

    expect(bytes).to eq "SET_FRONTEND_PID #{pid}\n"
  end

  it 'declares the rich-stream capabilities after its PID with --rich-stream' do
    bytes, pid = bytes_sent_on_connect('--rich-stream')

    expect(bytes).to eq "SET_FRONTEND_PID #{pid}\nSET_FRONTEND_CAPS room_element game_links double_bold\n"
  end

  # Run profanity.rb with +args+ on a wide terminal against a fake game
  # server that sends +lines+, until the terminal shows +pattern+.
  #
  # @return [String] everything written to the terminal
  # @raise [RuntimeError] naming what the terminal showed and the client's
  #   log, when the client exits or 20s pass before +pattern+ shows
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
    dir = Dir.mktmpdir('profanity-cli-spec')
    log = File.join(dir, 'profanity.log')
    wide = env.merge('COLUMNS' => '240', 'LINES' => '50')
    command = [RbConfig.ruby, File.join(repo, 'profanity.rb'), "--port=#{server.addr[1]}", "--log-file=#{log}",
               "--settings-file=#{File.join(repo, 'templates', 'default.xml')}", *args]
    PTY.spawn(wide, *command, chdir: Dir.home) do |reader, _writer, pid|
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 20
      ended = begin
        until output.match?(pattern)
          left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break 'timed out after 20s' unless left.positive? && reader.wait_readable(left)

          output << reader.readpartial(4096)
        end
      rescue EOFError, Errno::EIO
        'the client exited'
      end
      if ended
        raise "#{ended} before the terminal showed #{pattern.inspect}.\nTerminal:\n#{output.inspect}\n" \
              "Log:\n#{File.exist?(log) ? File.read(log) : '(none)'}"
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
    FileUtils.remove_entry(dir) if dir
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
