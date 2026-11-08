# frozen_string_literal: true

# The real client in a pseudo-terminal, with a settings file holding a gag
# that isn't a valid pattern. The warning used to be printed to stderr,
# which curses drew over its screen at startup; now it goes to the log and
# is drawn in the main window, as a line starting with "* ".

require 'pty'
require 'socket'
require 'timeout'
require 'tmpdir'

RSpec.describe 'Settings warnings on the client screen' do
  let(:repo) { File.expand_path('../..', __dir__) }
  let(:home) { File.realpath(Dir.mktmpdir('profanity-warning-screen')) }
  let(:warning) { 'Invalid gag pattern: (unclosed' }

  after { FileUtils.remove_entry(home) }

  it 'draws the warning in the main window and logs it, instead of printing it over the screen' do
    settings = File.join(home, 'bad-gag.xml')
    File.write(settings, File.read(File.join(repo, 'templates', 'default.xml'))
                             .sub('<settings>', "<settings>\n  <gag>(unclosed</gag>"))
    server = TCPServer.new('127.0.0.1', 0)
    accepted = Thread.new { server.accept }
    env = { 'TERM' => 'xterm-256color', 'HOME' => home, 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR) }
    args = [File.join(repo, 'profanity.rb'), "--port=#{server.addr[1]}", "--settings-file=#{settings}"]

    output = +''
    PTY.spawn(env, RbConfig.ruby, *args, chdir: home) do |reader, _writer, pid|
      Timeout.timeout(20) do
        output << reader.readpartial(4096) until output.include?("* #{warning}")
      rescue EOFError, Errno::EIO
        nil
      end
    ensure
      begin
        Process.kill('KILL', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
    end

    expect(output).to include("* #{warning}")
    expect(output.scan(warning).size).to eq(output.scan("* #{warning}").size), output
    expect(File.read(File.join(home, 'profanity.log'))).to include("[settings] #{warning}")
  ensure
    # Close the listener first: a client that exited before connecting
    # would otherwise leave the thread waiting in accept for ever.
    server&.close
    connection = begin
      accepted&.value
    rescue IOError
      nil
    end
    connection&.close
  end
end
