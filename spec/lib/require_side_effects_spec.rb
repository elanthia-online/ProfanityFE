# frozen_string_literal: true

# Requiring a lib file must not change anything outside the Ruby process.
# Each file is required in a fresh Ruby with HOME pointing at an empty
# directory, and with the real curses library (spec_helper's Curses stub
# isn't loaded there). lib/curses_setup_spec.rb checks the terminal.

require 'open3'
require 'tmpdir'

RSpec.describe 'requiring a lib file' do
  let(:lib) { File.expand_path('../../lib', __dir__) }

  # Run +script+ in a fresh Ruby with HOME set to an empty directory.
  #
  # @return [Array(String, Process::Status, Array<String>)] the output, the
  #   exit status, and what the script left in HOME
  def run_in_empty_home(script)
    Dir.mktmpdir('profanity-require-home') do |home|
      env = { 'HOME' => home, 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR) }
      output, status = Open3.capture2e(env, RbConfig.ruby, '-e', script, chdir: home)
      [output, status, Dir.children(home)]
    end
  end

  %w[profanity_settings cli_options curses_setup].each do |name|
    it "leaves HOME untouched for lib/#{name}.rb" do
      output, status, left = run_in_empty_home("require #{File.join(lib, name).inspect}")

      expect(status).to be_success, output
      expect(left).to be_empty
    end
  end

  it 'creates ~/.profanity only when ProfanitySettings.ensure_app_dir is called' do
    script = <<~RUBY
      require #{File.join(lib, 'profanity_settings').inspect}
      puts "before=\#{File.directory?(ProfanitySettings::APP_DIR)}"
      ProfanitySettings.ensure_app_dir
      puts "after=\#{File.directory?(ProfanitySettings::APP_DIR)}"
      ProfanitySettings.ensure_app_dir
      puts 'again=ok'
    RUBY
    output, status, left = run_in_empty_home(script)

    expect(status).to be_success, output
    expect(output).to include("before=false\n", "after=true\n", "again=ok\n")
    expect(left).to eq(['.profanity'])
  end
end
