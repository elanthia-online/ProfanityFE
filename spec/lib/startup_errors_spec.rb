# frozen_string_literal: true

# The real profanity.rb, started with a command line it must refuse before
# curses starts. The library raises (CliOptions::UsageError,
# ProfanitySettings::NotFoundError); profanity.rb prints the message and
# exits. Each run gets its own empty HOME, and stdout and stderr are
# captured separately so each message is checked on its own stream.
# cli_options_spec runs the same paths in a pseudo-terminal to check that
# curses never touched the terminal.

require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../../lib/version'

RSpec.describe 'profanity.rb startup errors' do
  let(:repo) { File.expand_path('../..', __dir__) }
  let(:home) { Dir.mktmpdir('profanity-startup-home') }

  after { FileUtils.remove_entry(home) }

  # Run +script+ (profanity.rb by default) with +args+ in the sandboxed HOME,
  # passing +ruby_opts+ to the ruby interpreter.
  #
  # @return [Array(String, String, Integer)] stdout, stderr and exit status
  def run_client(*args, script: File.join(repo, 'profanity.rb'), ruby_opts: [], extra_env: {})
    env = { 'HOME' => home, 'TERM' => 'xterm-256color', 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR) }.merge(extra_env)
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, *ruby_opts, script, *args, chdir: home, stdin_data: '')
    # RubyGems' own notice about a locally installed gem whose extension
    # isn't built, not the client's output.
    [stdout, stderr.gsub(/^Ignoring \S+ because its extensions are not built\..*\n/, ''), status.exitstatus]
  end

  it 'prints an unknown option and a usage hint to stderr and exits 1' do
    stdout, stderr, status = run_client('--bogus')

    expect([stdout, stderr, status]).to eq(['', "profanity.rb: invalid option: --bogus\n" \
                                                "Try 'profanity.rb --help' for the list of options.\n", 1])
  end

  it 'prints an invalid option value and a usage hint to stderr and exits 1' do
    stdout, stderr, status = run_client('--port=abc')

    expect([stdout, stderr, status]).to eq(['', "profanity.rb: invalid argument: --port=abc\n" \
                                                "Try 'profanity.rb --help' for the list of options.\n", 1])
  end

  it 'prints an unknown --game and a usage hint to stderr and exits 1' do
    stdout, stderr, status = run_client('--game=XX')

    expect([stdout, stderr, status]).to eq(['', "profanity.rb: invalid argument: --game=XX\n" \
                                                "Try 'profanity.rb --help' for the list of options.\n", 1])
  end

  # BUG FOUND (fixed here): the option error was printed with Kernel#warn,
  # which prints nothing when warnings are off (ruby -W0), so the client
  # exited 1 without saying why.
  it 'still prints an unknown option with warnings turned off (ruby -W0)' do
    stdout, stderr, status = run_client('--bogus', ruby_opts: ['-W0'])

    expect([stdout, stderr, status]).to eq(['', "profanity.rb: invalid option: --bogus\n" \
                                                "Try 'profanity.rb --help' for the list of options.\n", 1])
  end

  it 'still prints a missing --settings-file with warnings turned off (ruby -W0)' do
    stdout, stderr, status = run_client('--settings-file=/nonexistent/profanity.xml', ruby_opts: ['-W0'])

    expect([stdout, stderr, status]).to eq(['', "Settings file not found: /nonexistent/profanity.xml\n", 1])
  end

  it 'prints --help to stdout and exits 0' do
    stdout, stderr, status = run_client('--help')

    expect(status).to eq(0)
    expect(stderr).to eq('')
    expect(stdout).to start_with("\nProfanity FrontEnd v#{VERSION}\n\n")
    expect(stdout).to include('--settings-file=FILE', '--profile')
    expect(stdout).to match(/^\s+--game=CODE\s+Game's rules only: DR or GS/)
  end

  it 'prints a missing --settings-file to stderr and exits 1' do
    stdout, stderr, status = run_client('--settings-file=/nonexistent/profanity.xml')

    expect([stdout, stderr, status]).to eq(['', "Settings file not found: /nonexistent/profanity.xml\n", 1])
  end

  it 'prints a missing --template to stderr and exits 1' do
    stdout, stderr, status = run_client('--template=NoSuch.xml')

    expect([stdout, stderr, status]).to eq(['', "Template not found: #{File.join(repo, 'templates', 'NoSuch.xml')}\n", 1])
  end

  it 'checks the options before the settings file' do
    stdout, stderr, status = run_client('--settings-file=/nonexistent/profanity.xml', '--bogus')

    expect([stdout, stderr, status]).to eq(['', "profanity.rb: invalid option: --bogus\n" \
                                                "Try 'profanity.rb --help' for the list of options.\n", 1])
  end

  # No templates/default.xml next to profanity.rb: run a copy of the real
  # client from a directory that has lib/ but no templates/.
  it 'prints both lines of the no-settings-file message to stderr and exits 1' do
    app = File.join(home, 'app')
    FileUtils.mkdir_p(app)
    FileUtils.cp(File.join(repo, 'profanity.rb'), app)
    FileUtils.cp_r(File.join(repo, 'lib'), app)

    stdout, stderr, status = run_client(script: File.join(app, 'profanity.rb'))

    expect([stdout, stderr, status]).to eq(['', "No settings file found. Use --char=<name>, --template=<file>, or --settings-file=<path>\n" \
                                                "Or create #{File.join(app, 'templates', 'default.xml')}\n", 1])
  end

  # A log file that can't be written is refused before curses starts, so
  # the reason is readable instead of every log line being drawn over the
  # client's screen.
  it 'prints a --log-dir that does not exist to stderr and exits 1' do
    missing = File.join(home, 'no-such-dir')

    stdout, stderr, status = run_client("--log-dir=#{missing}")

    expect([stdout, stderr, status]).to eq(['', "Can't write the log file #{File.join(missing, 'profanity.log')}: " \
                                                "the directory #{missing} doesn't exist. Check --log-dir.\n", 1])
  end

  # Under a UTF-8 locale, an argument whose bytes aren't UTF-8 made
  # OptionParser raise ArgumentError, which ended in a Ruby backtrace.
  it 'prints an argument that is not valid UTF-8 and a usage hint to stderr, and exits 1' do
    locale = %w[C.UTF-8 en_US.UTF-8].find do |name|
      IO.popen({ 'LC_ALL' => name }, [RbConfig.ruby, '-e', 'print Encoding.find("locale")'], &:read) == 'UTF-8'
    end
    skip 'no UTF-8 locale on this machine' unless locale

    stdout, stderr, status = run_client("--char=caf#{[0xFF].pack('C')}", extra_env: { 'LC_ALL' => locale })

    expect([stdout, stderr, status]).to eq(['', "profanity.rb: invalid argument: --char=caf? (not valid UTF-8 text)\n" \
                                                "Try 'profanity.rb --help' for the list of options.\n", 1])
  end

  # These ended in a Ruby backtrace (File.expand_path raises for ~nosuchuser).
  it 'prints a --log-file in the home directory of a user that does not exist, and exits 1' do
    stdout, stderr, status = run_client('--log-file=~nosuchuser-pfe/x.log')

    expect([stdout, stderr, status]).to eq(['', "Can't write the log file ~nosuchuser-pfe/x.log: " \
                                                "user nosuchuser-pfe doesn't exist. Check --log-file.\n", 1])
  end

  it 'prints a --settings-file in the home directory of a user that does not exist, and exits 1' do
    stdout, stderr, status = run_client('--settings-file=~nosuchuser-pfe/x.xml')

    expect([stdout, stderr, status]).to eq(['', "Settings file not found: ~nosuchuser-pfe/x.xml: " \
                                                "user nosuchuser-pfe doesn't exist\n", 1])
  end

  # --char names files in ~/.profanity; a path there could name a file
  # anywhere.
  it 'prints a --char that is a path and a usage hint to stderr, and exits 1' do
    stdout, stderr, status = run_client('--char=../evil')

    expect([stdout, stderr, status]).to eq(['', "profanity.rb: invalid argument: --char=../evil\n" \
                                                "Try 'profanity.rb --help' for the list of options.\n", 1])
  end

  # A named pipe would block the first log write until something read it.
  it 'prints a --log-file that is a named pipe to stderr and exits 1' do
    fifo = File.join(home, 'pipe')
    File.mkfifo(fifo)

    stdout, stderr, status = run_client("--log-file=#{fifo}")

    expect([stdout, stderr, status]).to eq(['', "Can't write the log file #{fifo}: it is not a regular file. Check --log-file.\n", 1])
  end

  it 'prints a --log-file in a directory that does not exist to stderr and exits 1' do
    log = File.join(home, 'no-such-dir', 'mahtra.log')

    stdout, stderr, status = run_client("--log-file=#{log}")

    expect([stdout, stderr, status]).to eq(['', "Can't write the log file #{log}: the directory " \
                                                "#{File.dirname(log)} doesn't exist. Check --log-file.\n", 1])
  end

  # ~/.profanity is created at startup, before the command line is checked,
  # so even a refused command line leaves it behind (as it always has).
  [['--bogus'], ['--help'], ['--settings-file=/nonexistent/profanity.xml'], ['--template=NoSuch.xml'],
   ['--log-dir=/nonexistent/logs']].each do |args|
    it "creates ~/.profanity (and nothing else in HOME) for #{args.first}" do
      run_client(*args)

      expect(Dir.children(home)).to eq(['.profanity'])
      expect(File.directory?(File.join(home, '.profanity'))).to be(true)
    end
  end
end
