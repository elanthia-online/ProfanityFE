# frozen_string_literal: true

require 'open3'
require 'rbconfig'

RSpec.describe 'Runtime warning routing' do
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
end
