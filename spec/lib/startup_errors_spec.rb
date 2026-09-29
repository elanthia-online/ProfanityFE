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
  def run_client(*args, script: File.join(repo, 'profanity.rb'), ruby_opts: [])
    env = { 'HOME' => home, 'TERM' => 'xterm-256color', 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR) }
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

  # ~/.profanity is created at startup, before the command line is checked,
  # so even a refused command line leaves it behind (as it always has).
  [['--bogus'], ['--help'], ['--settings-file=/nonexistent/profanity.xml'], ['--template=NoSuch.xml']].each do |args|
    it "creates ~/.profanity (and nothing else in HOME) for #{args.first}" do
      run_client(*args)

      expect(Dir.children(home)).to eq(['.profanity'])
      expect(File.directory?(File.join(home, '.profanity'))).to be(true)
    end
  end
end
