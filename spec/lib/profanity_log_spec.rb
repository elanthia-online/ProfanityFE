# frozen_string_literal: true

# Tests the real ProfanityLog: it appends to the path given to
# ProfanityLog.configure, and prints to $stderr before that or when the
# file can't be written.
#
# spec_helper replaces ProfanityLog with a no-op stub for the rest of the
# suite, so each example loads lib/profanity_log.rb into a fresh module
# that stub_const swaps in and removes afterwards.

RSpec.describe 'ProfanityLog' do
  subject(:log) do
    stub_const('ProfanityLog', Module.new)
    load File.expand_path('../../lib/profanity_log.rb', __dir__)
    ProfanityLog
  end

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  let(:path) { File.join(@dir, 'mahtra.log') }

  # Run a block with $stderr captured; returns what was written.
  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  it 'appends each message to the configured file' do
    log.configure(path: path)

    output = capture_stderr do
      log.write('settings', 'first')
      log.write('mouse', 'second')
    end

    expect(File.read(path)).to eq "[settings] first\n[mouse] second\n"
    expect(output).to eq ''
  end

  it 'keeps what the file already holds' do
    File.write(path, "earlier session\n")
    log.configure(path: path)

    log.write('main', 'started')

    expect(File.read(path)).to eq "earlier session\n[main] started\n"
  end

  it "writes at most BACKTRACE_LIMIT backtrace lines, to the file only" do
    log.configure(path: path)
    backtrace = Array.new(BACKTRACE_LIMIT + 2) { |i| "lib/x.rb:#{i}" }

    output = capture_stderr { log.write('main', 'boom', backtrace: backtrace) }

    expect(File.read(path).lines.map(&:chomp)).to eq ['[main] boom', *backtrace.first(BACKTRACE_LIMIT)]
    expect(output).to eq ''
  end

  it 'reports the configured path' do
    expect(log.path).to be_nil

    log.configure(path: path)

    expect(log.path).to eq path
  end

  it 'writes to the most recently configured file' do
    other = File.join(@dir, 'other.log')
    log.configure(path: path)
    log.configure(path: other)

    log.write('main', 'here')

    expect(File.exist?(path)).to be false
    expect(File.read(other)).to eq "[main] here\n"
  end

  # Before profanity.rb configured a path (formerly: before LOG_FILE was
  # defined), a message went to $stderr without its backtrace.
  it 'prints the message, without the backtrace, to $stderr before a path is configured' do
    output = capture_stderr { log.write('settings', 'too early', backtrace: ['lib/x.rb:1']) }

    expect(output).to eq "[settings] too early\n"
    expect(Dir.children(@dir)).to be_empty
  end

  it 'prints to $stderr when the configured file cannot be opened' do
    log.configure(path: File.join(@dir, 'missing-dir', 'mahtra.log'))

    output = capture_stderr { log.write('main', 'nowhere to go') }

    expect(output).to eq "[main] nowhere to go\n"
  end

  it 'prints to $stderr when the configured path is a directory' do
    log.configure(path: @dir)

    output = capture_stderr { log.write('main', 'not a file') }

    expect(output).to eq "[main] not a file\n"
  end
end
