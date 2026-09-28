# frozen_string_literal: true

require 'stringio'
require_relative '../../lib/selection_manager'
require_relative '../../lib/profanity_settings'

# A missing platform clipboard tool (pbcopy / wl-copy / xclip not on PATH)
# must not abort the copy: OSC 52 and the file fallback still have to run.
# PATH points at an empty directory, so the real IO.popen fails to spawn.
RSpec.describe 'SelectionManager.copy_to_clipboard with no clipboard tool installed' do
  let(:tty) { StringIO.new }
  let(:empty_bin) { Dir.mktmpdir('no-clipboard-tools') }
  let(:selection_file) { ProfanitySettings.file('selection.txt') }

  around do |example|
    saved_env = ENV.to_h
    example.run
  ensure
    ENV.replace(saved_env)
    FileUtils.remove_entry(empty_bin)
    FileUtils.rm_f(selection_file)
  end

  before do
    ENV['PATH'] = empty_bin
    %w[STY TMUX WAYLAND_DISPLAY DISPLAY].each { |key| ENV.delete(key) }
    allow(File).to receive(:open).and_call_original
    allow(File).to receive(:open).with('/dev/tty', 'w').and_yield(tty)
  end

  {
    'pbcopy (macOS)'    => [{ 'host_os' => 'darwin24' }, {}],
    'wl-copy (Wayland)' => [{ 'host_os' => 'linux-gnu' }, { 'WAYLAND_DISPLAY' => 'wayland-0' }],
    'xclip (X11)'       => [{ 'host_os' => 'linux-gnu' }, { 'DISPLAY' => ':0' }]
  }.each do |tool, (rbconfig, env)|
    it "still sends OSC 52 and writes the fallback file when #{tool} is missing" do
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge(rbconfig))
      env.each { |key, value| ENV[key] = value }

      SelectionManager.copy_to_clipboard('hello')

      expect(tty.string).to eq("\e]52;c;#{['hello'].pack('m0')}\a")
      expect(File.read(selection_file)).to eq('hello')
    end
  end

  it 'still pipes the text to the tool when it is installed' do
    received = File.join(empty_bin, 'received')
    tool = File.join(empty_bin, 'wl-copy')
    File.open(tool, 'w', 0o755) { |f| f.write("#!/bin/sh\nexec cat > '#{received}'\n") }
    ENV['PATH'] = "#{empty_bin}:/bin:/usr/bin"
    stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'linux-gnu'))
    ENV['WAYLAND_DISPLAY'] = 'wayland-0'
    allow(ProfanityLog).to receive(:write)

    SelectionManager.copy_to_clipboard('hello')

    expect(File.read(received)).to eq('hello')
    expect(tty.string).to eq("\e]52;c;#{['hello'].pack('m0')}\a")
    expect(ProfanityLog).to have_received(:write).with('Clipboard', 'Copied 5 chars via wl-copy')
  end

  context 'when the tool runs but exits non-zero (e.g. xclip with no reachable X server)' do
    let(:clipboard_log) { [] }

    before do
      tool = File.join(empty_bin, 'wl-copy')
      File.open(tool, 'w', 0o755) { |f| f.write("#!/bin/sh\ncat > /dev/null\nexit 1\n") }
      ENV['PATH'] = "#{empty_bin}:/bin:/usr/bin"
      stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'linux-gnu'))
      ENV['WAYLAND_DISPLAY'] = 'wayland-0'
      allow(ProfanityLog).to receive(:write) { |context, message, **| clipboard_log << message if context == 'Clipboard' }
    end

    it 'does not report the copy as done by the tool' do
      SelectionManager.copy_to_clipboard('hello')

      expect(clipboard_log).not_to include(a_string_starting_with('Copied'))
      expect(clipboard_log).to include(a_string_matching(/\Awl-copy failed \(.*exit.*1\); using OSC 52 \+ file\z/))
    end

    it 'still sends OSC 52 and writes the fallback file' do
      SelectionManager.copy_to_clipboard('hello')

      expect(tty.string).to eq("\e]52;c;#{['hello'].pack('m0')}\a")
      expect(File.read(selection_file)).to eq('hello')
    end
  end
end
