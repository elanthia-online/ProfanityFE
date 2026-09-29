# frozen_string_literal: true

# Tests UrlLauncher, which opens a LaunchURL in the system browser: the
# command it picks per system, that the URL is spawned as one literal
# argument (never through a shell), and what happens when the command
# can't run. Which URLs are allowed is TagHandlers#handle_launch_url's job
# (only https://www.play.net; see tag_handlers_spec.rb).

require_relative '../../lib/url_launcher'

RSpec.describe UrlLauncher do
  let(:url) { 'https://www.play.net/x$(touch /tmp/pwned)`id`;rm -rf ~ "q" \'s\' | cat &' }

  describe '.command' do
    {
      macos: ['open'],
      unix: ['xdg-open'],
      windows: ['rundll32', 'url.dll,FileProtocolHandler']
    }.each do |os, program|
      it "is #{program.join(' ')} followed by the URL, untouched, on #{os}" do
        expect(described_class.command(url, os)).to eq [*program, url]
        expect(described_class.command(url, os).last).to be url
      end
    end

    it 'is nil on a system with no known browser command' do
      expect(described_class.command(url, nil)).to be_nil
      expect(described_class.command(url, :solaris)).to be_nil
    end

    it 'asks Platform.os when no system is given' do
      allow(Platform).to receive(:os).and_return(:unix)

      expect(described_class.command(url)).to eq ['xdg-open', url]
    end
  end

  describe '.open' do
    before do
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:detach)
    end

    {
      'darwin24'  => ['open'],
      'linux-gnu' => ['xdg-open'],
      'mingw32'   => ['rundll32', 'url.dll,FileProtocolHandler']
    }.each do |host_os, program|
      it "spawns #{program.first} on #{host_os} with the URL as one argument and detaches it" do
        stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => host_os))

        described_class.open(url)

        expect(Process).to have_received(:spawn).with(*program, url, out: File::NULL, err: File::NULL)
        expect(Process).to have_received(:detach).with(4242)
      end
    end

    it 'never hands the URL to a shell, even when the URL is the whole command' do
      # Process.spawn runs a lone string through /bin/sh when it has shell
      # metacharacters; an argument list of two or more never does.
      allow(Platform).to receive(:os).and_return(:macos)

      described_class.open(url)

      expect(Process).to have_received(:spawn) do |*argv, **|
        expect(argv.size).to be >= 2
        expect(argv).to all(be_a(String))
      end
    end

    it 'spawns nothing on a system with no known browser command' do
      allow(Platform).to receive(:os).and_return(nil)

      expect(described_class.open(url)).to be_nil
      expect(Process).not_to have_received(:spawn)
    end

    it 'logs a command that cannot be started instead of raising' do
      allow(Platform).to receive(:os).and_return(:unix)
      allow(Process).to receive(:spawn).and_raise(Errno::ENOENT, 'xdg-open')
      allow(ProfanityLog).to receive(:write)

      expect { described_class.open('https://www.play.net/a') }.not_to raise_error
      expect(ProfanityLog).to have_received(:write)
        .with('launch_url', 'could not open https://www.play.net/a: No such file or directory - xdg-open')
      expect(Process).not_to have_received(:detach)
    end

    it 'logs any system call failure, such as a refused fork' do
      allow(Platform).to receive(:os).and_return(:macos)
      allow(Process).to receive(:spawn).and_raise(Errno::EAGAIN)
      allow(ProfanityLog).to receive(:write)

      described_class.open('https://www.play.net/a')

      expect(ProfanityLog).to have_received(:write).with('launch_url', a_string_starting_with('could not open https://www.play.net/a: '))
    end

    it 'lets an error that is not a system call failure propagate' do
      allow(Platform).to receive(:os).and_return(:macos)
      allow(Process).to receive(:spawn).and_raise(ArgumentError, 'bad')

      expect { described_class.open('https://www.play.net/a') }.to raise_error(ArgumentError, 'bad')
    end
  end
end
