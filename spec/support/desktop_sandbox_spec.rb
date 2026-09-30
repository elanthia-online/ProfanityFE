# frozen_string_literal: true

require_relative '../../lib/profanity_settings'
require_relative '../../lib/selection_manager'
require_relative '../../lib/url_launcher'

# Guards spec_helper's "Keep the suite off the desktop" stand-ins: a spec
# that copies a selection or opens a link must reach the stand-ins, never
# the developer's clipboard, browser or terminal.
RSpec.describe 'spec_helper desktop sandbox' do
  # Every desktop command lib/ runs: SelectionManager#copy_to_clipboard's
  # clipboard tools and UrlLauncher.command's browser openers.
  let(:desktop_commands) { %w[pbcopy wl-copy xclip open xdg-open] }
  let(:selection) { 'guard text' }

  def command_on_path(name)
    ENV.fetch('PATH').split(File::PATH_SEPARATOR).map { |dir| File.join(dir, name) }.find { |path| File.executable?(path) }
  end

  def stand_in_record(file)
    File.read(File.join(SPEC_BIN, file))
  end

  def terminal_opened_for_writing
    File.open('/dev/tty', 'w') { |tty| return tty }
  end

  # Run before an example acts: a failed expectation raises and ends the
  # example there. So when a stand-in is gone this guard fails without
  # copying its text to the real clipboard, opening the real browser or
  # sending an OSC 52 escape to the real terminal.
  def abort_unless_sandboxed(*commands)
    commands.each { |command| expect(command_on_path(command)).to eq(File.join(SPEC_BIN, command)) }
    expect(terminal_opened_for_writing).to be(spec_terminal)
  end

  around do |example|
    saved_env = ENV.to_h
    example.run
  ensure
    ENV.replace(saved_env)
  end

  before do
    # Another example may have run a stand-in already.
    FileUtils.rm_f(Dir.glob(File.join(SPEC_BIN, '*.{args,input}')))
    %w[STY TMUX WAYLAND_DISPLAY DISPLAY].each { |key| ENV.delete(key) }
  end

  it 'finds a stand-in first on PATH for every clipboard and browser command lib runs' do
    found = desktop_commands.to_h { |command| [command, command_on_path(command)] }

    expect(found).to eq(desktop_commands.to_h { |command| [command, File.join(SPEC_BIN, command)] })
  end

  it 'gives code that opens /dev/tty for writing the spec terminal instead' do
    expect(terminal_opened_for_writing).to be(spec_terminal)
  end

  context 'when a selection is copied' do
    before { ProfanitySettings.ensure_app_dir }

    it 'pipes it to the stand-in pbcopy on macOS' do
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'darwin24'))
      abort_unless_sandboxed('pbcopy')

      SelectionManager.copy_to_clipboard(selection)

      expect(stand_in_record('pbcopy.input')).to eq(selection)
    end

    it 'pipes it to the stand-in xclip, for the clipboard selection, under X11' do
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'linux-gnu'))
      ENV['DISPLAY'] = ':0'
      abort_unless_sandboxed('xclip')

      SelectionManager.copy_to_clipboard(selection)

      expect(stand_in_record('xclip.input')).to eq(selection)
      expect(stand_in_record('xclip.args')).to eq('-selection clipboard')
    end

    it 'pipes it to the stand-in wl-copy under Wayland' do
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'linux-gnu'))
      ENV['WAYLAND_DISPLAY'] = 'wayland-0'
      abort_unless_sandboxed('wl-copy')

      SelectionManager.copy_to_clipboard(selection)

      expect(stand_in_record('wl-copy.input')).to eq(selection)
    end

    it 'sends its OSC 52 escape to the spec terminal' do
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'linux-gnu'))
      abort_unless_sandboxed

      SelectionManager.copy_to_clipboard(selection)

      expect(spec_terminal.string).to eq("\e]52;c;#{[selection].pack('m0')}\a")
    end
  end

  it 'hands a LaunchURL to the stand-in open on macOS' do
    url = 'https://www.play.net/dr/'
    record = File.join(SPEC_BIN, 'open.args')
    allow(Platform).to receive(:os).and_return(:macos)
    abort_unless_sandboxed('open')

    UrlLauncher.open(url)

    # The browser command runs detached; give it a moment to start.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    sleep 0.01 until File.size?(record) || Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
    expect(stand_in_record('open.args')).to eq(url)
  end
end
