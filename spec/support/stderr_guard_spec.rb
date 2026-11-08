# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'tmpdir'

# spec_helper fails a run that writes anything to $stderr (see "Keep
# stderr clean" there). Without it, a warning or a leaked log line would
# only add to the noise of a passing run.
RSpec.describe 'Output on stderr' do
  # Run a spec file with +body+ in a child rspec that loads spec_helper.
  #
  # @return [Array(String, Process::Status)] its output and exit status
  def run_spec_file(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'stderr_spec.rb')
      File.write(path, body)
      helper = File.expand_path('../spec_helper', __dir__)
      Open3.capture2e(RbConfig.ruby, '-S', 'rspec', '--require', helper, '--order', 'defined', path)
    end
  end

  [['warn', "warn 'stray warning'"],
   ['$stderr.puts', "$stderr.puts 'stray warning'"],
   ['$stderr.print', "$stderr.print \"stray warning\\n\""],
   ['$stderr <<', "$stderr << \"stray warning\\n\""]].each do |name, code|
    it "fails a run whose example writes with #{name}, quoting what it wrote" do
      output, status = run_spec_file(<<~RUBY)
        RSpec.describe 'noisy' do
          it('writes') { #{code} }
        end
      RUBY

      expect(output).to include('1 example, 0 failures')
      expect(output).to include('the suite printed to stderr')
      expect(output.scan('stray warning').size).to be >= 2 # as written, and quoted in the failure
      expect(status).not_to be_success
    end
  end

  it 'fails a run that warns while the spec files load' do
    output, status = run_spec_file(<<~RUBY)
      warn 'warned while loading'
      RSpec.describe('quiet') { it('passes') { expect(1).to eq 1 } }
    RUBY

    expect(output).to include('the suite printed to stderr')
    expect(output).to include('warned while loading')
    expect(status).not_to be_success
  end

  it 'fails a run that writes in more than one encoding, without an encoding error' do
    output, status = run_spec_file(<<~RUBY)
      RSpec.describe 'noisy' do
        it('writes') do
          $stderr.write("\\xFF\\n".b)
          $stderr.write("caf\\u00e9\\n")
        end
      end
    RUBY

    expect(output).to include('the suite printed to stderr')
    expect(output).not_to include('Encoding::CompatibilityError')
    # The quote, after the failure's header (the raw byte makes the output invalid UTF-8)
    expect(output.b.split('the suite printed to stderr'.b).last).to include([0x63, 0x61, 0x66, 0xE9].pack('U*').b)
    expect(status).not_to be_success
  end

  it 'fails an example that leaves $stderr replaced, and only that one' do
    output, status = run_spec_file(<<~RUBY)
      RSpec.describe 'leaky' do
        it('swaps stderr') { $stderr = StringIO.new }
        it('runs after it, with stderr back') { expect($stderr).to equal(SUITE_STDERR) }
      end
    RUBY

    expect(output).to include('2 examples, 1 failure')
    expect(output).to include('the example left $stderr replaced')
    expect(status).not_to be_success
  end

  it 'keeps the own failure of an example that also left $stderr replaced' do
    output, status = run_spec_file(<<~RUBY)
      RSpec.describe 'leaky' do
        it('swaps stderr and fails') do
          $stderr = StringIO.new
          expect(1).to eq 2
        end
      end
    RUBY

    expect(output).to include('1 example, 1 failure')
    expect(output).to include('expected: 2')
    expect(output).not_to include('the example left $stderr replaced')
    expect(status).not_to be_success
  end

  it 'fails an example that triggers an RSpec deprecation, instead of printing a notice' do
    output, status = run_spec_file(<<~RUBY)
      RSpec.describe 'deprecated' do
        it('uses something deprecated') { RSpec.deprecate('an old thing', replacement: 'a new thing') }
      end
    RUBY

    expect(output).to include('1 example, 1 failure')
    expect(output).to include('an old thing')
    expect(output).not_to include('Deprecation Warnings')
    expect(status).not_to be_success
  end

  it 'passes a run that captures the output it expects, or prints nothing' do
    output, status = run_spec_file(<<~RUBY)
      RSpec.describe 'quiet' do
        it('captures') { expect { warn 'expected' }.to output(/expected/).to_stderr }
        it('swaps stderr and puts it back') do
          original = $stderr
          $stderr = StringIO.new
          warn 'kept in the StringIO'
        ensure
          $stderr = original
        end
        it('prints nothing') { expect(1).to eq 1 }
      end
    RUBY

    expect(output).to include('3 examples, 0 failures')
    expect(output).not_to include('the suite printed to stderr')
    expect(status).to be_success
  end
end
