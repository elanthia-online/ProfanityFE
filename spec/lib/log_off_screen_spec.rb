# frozen_string_literal: true

# The real client in a pseudo-terminal: a log message must never be drawn
# over its screen. ProfanityLog used to print a message it couldn't write
# to the log file to stderr, which curses shows. Each run gets its own
# HOME, with a settings.json that isn't valid JSON: loading it logs
# "[settings] Failed to parse settings.json" once curses has started. The
# client is pointed at a port nothing listens on, so it exits 1 after
# startup.

require 'pty'
require 'socket'
require 'timeout'
require 'tmpdir'

RSpec.describe 'Log messages and the client screen' do
  let(:repo) { File.expand_path('../..', __dir__) }
  let(:home) { File.realpath(Dir.mktmpdir('profanity-log-screen')) }
  let(:logged) { 'Failed to parse settings.json' }

  before do
    FileUtils.mkdir_p(File.join(home, '.profanity'))
    File.write(File.join(home, '.profanity', 'settings.json'), '{not json')
  end

  after do
    FileUtils.chmod_R('u+w', home)
    FileUtils.remove_entry(home)
  end

  # Run profanity.rb in a pseudo-terminal until it exits.
  #
  # @param ruby_opts [Array<String>] options for the Ruby interpreter
  # @param chdir [String] the client's working directory
  # @return [Array(String, Integer)] everything written to the terminal, and
  #   the exit status
  def run_client(ruby_opts: [], chdir: home)
    port = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
    env = { 'TERM' => 'xterm-256color', 'HOME' => home, 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR) }
    args = [*ruby_opts, File.join(repo, 'profanity.rb'), "--port=#{port}",
            "--settings-file=#{File.join(repo, 'templates', 'default.xml')}"]
    output = +''
    status = nil
    PTY.spawn(env, RbConfig.ruby, *args, chdir: chdir) do |reader, _writer, pid|
      Timeout.timeout(20) do
        loop { output << reader.readpartial(4096) }
      rescue EOFError, Errno::EIO
        nil
      end
      _, status = Process.wait2(pid)
    end
    [output, status.exitstatus]
  end

  # What curses showed: the output between entering and leaving the
  # alternate screen.
  def curses_screen(output)
    output[/\e\[\?1049h(.*)\e\[\?1049l/m, 1].to_s
  end

  it 'writes the message to the log file and nothing on the screen' do
    output, status = run_client

    expect(status).to eq(1), output
    expect(output).to include('Is the game server running?')
    expect(File.read(File.join(home, 'profanity.log'))).to include("[settings] #{logged}")
    expect(output).not_to include(logged)
  end

  # The log file passed the startup check, then stops taking writes (a
  # full disk, say): the preload makes appending to it fail with ENOSPC.
  it 'drops a message the log file no longer takes instead of drawing it' do
    preload = File.join(home, 'disk_full.rb')
    File.write(preload, <<~RUBY)
      File.singleton_class.prepend(Module.new do
        def open(path, mode = 'r', *rest, **opts, &block)
          raise Errno::ENOSPC, path.to_s if path.to_s.end_with?('profanity.log') && mode == 'a'

          super
        end
      end)
    RUBY

    output, status = run_client(ruby_opts: ['-r', preload])

    expect(status).to eq(1), output
    expect(curses_screen(output)).not_to be_empty
    expect(output).not_to include(logged)
  end

  context 'started from a directory it cannot write' do
    before { skip 'root can write to read-only directories' if Process.uid.zero? }

    it 'logs to ~/.profanity/profanity.log and says so on the normal terminal' do
      cwd = File.join(home, 'read-only')
      FileUtils.mkdir(cwd)
      FileUtils.chmod('a-w', cwd)

      output, status = run_client(chdir: cwd)

      expect(status).to eq(1), output
      fallback = File.join(home, '.profanity', 'profanity.log')
      notice = "Can't write the log file #{File.join(cwd, 'profanity.log')}: the directory #{cwd} " \
               "can't be written. Logging to #{fallback} instead."
      expect(output).to include(notice)
      expect(output.index(notice)).to be < output.index("\e[?1049h")
      expect(File.read(fallback)).to include("[settings] #{logged}")
      expect(curses_screen(output)).not_to include(logged)
    end
  end
end
