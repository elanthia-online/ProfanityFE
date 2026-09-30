# frozen_string_literal: true

require 'open3'
require 'rbconfig'
require 'tmpdir'

# spec_helper turns an `exit` that escapes an example into a failure of
# that example (see "RSpec never rescues SystemExit" there). Without it,
# the run would stop at that example and rspec would exit 0.
RSpec.describe 'An exit that escapes an example' do
  def run_spec_file(body)
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'escaping_exit_spec.rb')
      File.write(path, body)
      helper = File.expand_path('../spec_helper', __dir__)
      Open3.capture2e(RbConfig.ruby, '-S', 'rspec', '--require', helper, '--order', 'defined', path)
    end
  end

  it 'fails that example, runs the rest, and fails the run' do
    output, status = run_spec_file(<<~RUBY)
      RSpec.describe 'escaping exit' do
        it('exits') { exit 0 }
        it('runs after it') { expect(1).to eq 1 }
      end
    RUBY

    expect(output).to include('2 examples, 1 failure')
    expect(output).to include('the example let exit(0) escape')
    expect(status).not_to be_success
  end

  it 'leaves an exit the example expects alone' do
    output, status = run_spec_file(<<~RUBY)
      RSpec.describe 'expected exit' do
        it('exits on purpose') { expect { exit 1 }.to raise_error(SystemExit) }
      end
    RUBY

    expect(output).to include('1 example, 0 failures')
    expect(status).to be_success
  end
end
