# frozen_string_literal: true

# Tests Platform.os, the one place that reads host_os, and the commands its
# two users pick from it: the browser command for LaunchURL
# (UrlLauncher.open, spawned as an argument list) and the
# clipboard command (SelectionManager.copy_to_clipboard).

require 'stringio'
require_relative '../spec_helper'
require_relative '../../lib/platform'
require_relative '../../lib/event_bus'
require_relative '../../lib/window_manager'
require_relative '../../lib/selection_manager'
require_relative '../../lib/profanity_settings'

RSpec.describe Platform do
  def on_host(host_os)
    stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => host_os))
  end

  describe '.os' do
    {
      'darwin' => :macos, 'darwin24' => :macos, 'x86_64-darwin23' => :macos,
      'linux' => :unix, 'linux-gnu' => :unix, 'linux-musl' => :unix,
      'freebsd14.1' => :unix, 'openbsd7.5' => :unix, 'netbsd' => :unix,
      'mingw32' => :windows, 'mswin64_140' => :windows, 'cygwin' => :windows,
      'solaris2.11' => nil, 'aix7.2' => nil, '' => nil
    }.each do |host_os, os|
      it "is #{os.inspect} for host_os #{host_os.inspect}" do
        expect(described_class.os(host_os)).to eq os
      end
    end

    it 'is nil for a nil host_os' do
      expect(described_class.os(nil)).to be_nil
    end

    it 'reads RbConfig::CONFIG on every call' do
      on_host('darwin24')
      expect(described_class.os).to eq :macos

      on_host('linux-gnu')
      expect(described_class.os).to eq :unix
    end
  end

  describe 'the LaunchURL browser command' do
    let(:event_bus) { EventBus.new }
    let(:url) { 'https://www.play.net/x$(touch /tmp/pwned)`id`' }

    before do
      wm = WindowManager.new
      wm.instance_variable_set(:@stream, { MAIN_STREAM => Object.new })
      wm.subscribe_to_events(event_bus)
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:detach)
    end

    {
      'darwin24'    => ['open'],
      'linux-gnu'   => ['xdg-open'],
      'freebsd14.1' => ['xdg-open'],
      'mingw32'     => ['rundll32', 'url.dll,FileProtocolHandler']
    }.each do |host_os, command|
      it "spawns #{command.first} with the URL as one literal argument on #{host_os}" do
        on_host(host_os)

        event_bus.emit(:launch_url, url: url, remote: false)

        expect(Process).to have_received(:spawn).with(*command, url, out: File::NULL, err: File::NULL)
        expect(Process).to have_received(:detach).with(4242)
      end
    end

    it 'takes the system from Platform.os' do
      on_host('linux-gnu')
      allow(described_class).to receive(:os).and_return(:macos)

      event_bus.emit(:launch_url, url: url, remote: false)

      expect(Process).to have_received(:spawn).with('open', url, out: File::NULL, err: File::NULL)
    end

    it 'spawns nothing on a system it does not know' do
      on_host('solaris2.11')

      event_bus.emit(:launch_url, url: url, remote: false)

      expect(Process).not_to have_received(:spawn)
    end
  end

  describe 'the clipboard command' do
    let(:tty) { StringIO.new }
    let(:commands) { [] }

    around do |example|
      saved_env = ENV.to_h
      example.run
    ensure
      ENV.replace(saved_env)
      FileUtils.rm_f(ProfanitySettings.file('selection.txt'))
    end

    before do
      ProfanitySettings.ensure_app_dir
      %w[STY TMUX WAYLAND_DISPLAY DISPLAY].each { |key| ENV.delete(key) }
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with('/dev/tty', 'w').and_yield(tty)
      # Record the command, then fail as a missing tool does, so the copy
      # goes on to OSC 52 and the file.
      allow(IO).to receive(:popen) do |command, *|
        commands << command
        raise Errno::ENOENT, command
      end
    end

    {
      ['darwin24', {}]                                                       => ['pbcopy'],
      ['darwin24', { 'WAYLAND_DISPLAY' => 'wayland-0', 'DISPLAY' => ':0' }]  => ['pbcopy'],
      ['linux-gnu', { 'WAYLAND_DISPLAY' => 'wayland-0', 'DISPLAY' => ':0' }] => ['wl-copy'],
      ['linux-gnu', { 'DISPLAY' => ':0' }]                                   => ['xclip -selection clipboard'],
      ['linux-gnu', {}]                                                      => [],
      ['freebsd14.1', { 'DISPLAY' => ':0' }]                                 => ['xclip -selection clipboard'],
      ['mingw32', {}]                                                        => []
    }.each do |(host_os, env), expected|
      it "uses #{expected.first || 'no command'} on #{host_os} with #{env.empty? ? 'no display' : env.keys.join(' and ')}" do
        on_host(host_os)
        env.each { |key, value| ENV[key] = value }

        SelectionManager.copy_to_clipboard('hello')

        expect(commands).to eq expected
        expect(tty.string).to eq("\e]52;c;#{['hello'].pack('m0')}\a")
      end
    end

    it 'takes the system from Platform.os' do
      on_host('linux-gnu')
      ENV['DISPLAY'] = ':0'
      allow(described_class).to receive(:os).and_return(:macos)

      SelectionManager.copy_to_clipboard('hello')

      expect(commands).to eq ['pbcopy']
    end
  end
end
