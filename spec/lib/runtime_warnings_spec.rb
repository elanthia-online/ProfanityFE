# frozen_string_literal: true

require 'open3'
require 'rbconfig'

RSpec.describe 'Runtime warning routing' do
  def probe(source, path)
    boot = "require #{File.expand_path('../../lib/runtime_warnings', __dir__).inspect}\n"
    Open3.capture3(RbConfig.ruby, '-e', boot + source, path)
  end

  it 'logs Ruby and native-style warnings while active, then restores stderr' do
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'warnings.log')
      source = <<~RUBY
        require #{File.expand_path('../../lib/runtime_warnings', __dir__).inspect}
        RuntimeWarnings.start(path: ARGV.fetch(0))
        warn 'ordinary runtime warning'
        Warning.warn("native curses warning\n", category: :deprecated)
        RuntimeWarnings.stop
        warn 'visible after shutdown'
      RUBY
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-e', source, path)
      expect(status).to be_success
      expect(stdout).to eq ''
      expect(stderr).to eq "visible after shutdown\n"
      expect(File.read(path)).to eq "ordinary runtime warning\nnative curses warning\n"
    end
  end

  it 'survives an unavailable log and waits until shutdown to print warnings' do
    Dir.mktmpdir do |dir|
      stdout, stderr, status = probe(<<~RUBY, File.join(dir, 'missing', 'warnings.log'))
        require 'stringio'
        captured = StringIO.new
        real_stderr = $stderr
        $stderr = captured
        RuntimeWarnings.start(path: ARGV.fetch(0))
        warn 'buffered warning'
        abort 'warning leaked into active UI' unless captured.string.empty?
        puts 'startup continued'
        RuntimeWarnings.stop
        real_stderr.write(captured.string)
        $stderr = real_stderr
        warn 'normal after shutdown'
      RUBY
      expect(status).to be_success
      expect(stdout).to eq "startup continued\n"
      expect(stderr).to eq "buffered warning\nnormal after shutdown\n"
    end
  end

  %w[IOError Errno::ENOSPC].each do |error|
    it "buffers warnings if the log write and close fail with #{error}" do
      Dir.mktmpdir do |dir|
        stdout, stderr, status = probe(<<~RUBY, File.join(dir, 'warnings.log'))
          require 'stringio'
          captured = StringIO.new
          real_stderr = $stderr
          $stderr = captured
          RuntimeWarnings.start(path: ARGV.fetch(0))
          RuntimeWarnings.output.define_singleton_method(:write) { |*| raise #{error} }
          RuntimeWarnings.output.define_singleton_method(:close) { raise #{error} }
          warn 'first warning'
          Warning.warn("second warning\n", category: :deprecated)
          abort 'warning leaked into active UI' unless captured.string.empty?
          puts 'continued after warnings'
          RuntimeWarnings.stop
          real_stderr.write(captured.string)
          RuntimeWarnings.stop
        RUBY
        expect(status).to be_success
        expect(stdout).to eq "continued after warnings\n"
        expect(stderr).to eq "first warning\nsecond warning\n"
      end
    end
  end

  it 'bounds buffered warnings during a prolonged log failure' do
    Dir.mktmpdir do |dir|
      stdout, stderr, status = probe(<<~RUBY, File.join(dir, 'missing', 'warnings.log'))
        RuntimeWarnings.start(path: ARGV.fetch(0))
        100.times { Warning.warn('x' * 1024) }
        RuntimeWarnings.stop
      RUBY
      expect(status).to be_success
      expect(stdout).to be_empty
      expect(stderr.bytesize).to be < 66_000
      expect(stderr).to end_with("[profanity] 36 additional warning(s) omitted.\n")
    end
  end
end
