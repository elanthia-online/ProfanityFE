# frozen_string_literal: true

# lib/curses_setup.rb, run in a fresh Ruby with the real curses library
# (spec_helper replaces Curses with a stub, so it can't be tested in this
# process). Requiring the file must leave the terminal alone; only
# CursesSetup.start takes it over.

require 'open3'
require 'socket'
require 'pty'
require 'timeout'
require 'tmpdir'

RSpec.describe 'lib/curses_setup.rb' do
  let(:setup_file) { File.expand_path('../../lib/curses_setup.rb', __dir__) }
  let(:env) { { 'TERM' => 'xterm-256color', 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR) } }

  # Run +script+ in a fresh Ruby inside a pseudo-terminal until it exits.
  #
  # @param script [String, nil] Ruby code to run with -e
  # @param args [Array<String>] the Ruby arguments instead (default: -e
  #   +script+)
  # @param extra_env [Hash{String => String}] added to {#env}
  # @return [Array(String, Integer)] everything written to the terminal, and
  #   the exit status
  def run_in_pty(script = nil, args: ['-e', script], extra_env: {})
    output = +''
    status = nil
    PTY.spawn(env.merge(extra_env), RbConfig.ruby, *args) do |reader, _writer, pid|
      Timeout.timeout(20) do
        loop { output << reader.readpartial(4096) }
      rescue EOFError, Errno::EIO
        nil
      end
      _, status = Process.wait2(pid)
    end
    [output, status.exitstatus]
  end

  # Prepended to the real Curses module before lib/curses_setup.rb loads:
  # records each terminal-changing call (and still makes it), then prints
  # the list at exit, after the script restores the terminal.
  let(:recorder) do
    <<~RUBY
      require 'curses'
      CALLS = []
      Curses.singleton_class.prepend(Module.new do
        %i[init_screen start_color cbreak noecho stdscr].each do |name|
          define_method(name) { |*args| CALLS << name; super(*args) }
        end
      end)
    RUBY
  end

  it 'does not start curses or touch the terminal when required' do
    script = "#{recorder}require #{setup_file.inspect}\n" \
             "puts \"calls=\#{CALLS.inspect}\""
    output, status = run_in_pty(script)

    expect(status).to eq(0), output
    expect(output).to include('calls=[]')
    expect(output).not_to include("\e")
  end

  it 'starts curses, colors, cbreak, noecho and keypad mode on CursesSetup.start' do
    script = "#{recorder}require #{setup_file.inspect}\n" \
             "CursesSetup.start\n" \
             "Curses.close_screen\n" \
             "puts \"calls=\#{CALLS.inspect}\""
    output, status = run_in_pty(script)

    expect(status).to eq(0), output
    expect(output).to include('calls=[:init_screen, :start_color, :cbreak, :noecho, :stdscr]')
    # Curses sent its terminal setup (alternate screen and the like).
    expect(output).to include("\e")
  end

  # The curses gem's Curses::MouseEvent warning (see
  # lib/mouse_event_warning.rb). Curses.getmouse builds a MouseEvent even
  # when no mouse event is waiting (it then returns nil), so these send no
  # mouse report and don't depend on the terminfo's mouse format.
  describe 'the Curses::MouseEvent warning' do
    let(:warning_text) { 'undefining the allocator of T_DATA class Curses::MouseEvent' }

    # The bug, and the two facts the fix relies on: the warning reaches the
    # terminal, and only the first getmouse of a process prints it. If this
    # fails because there is no warning, the curses gem (or Ruby) no longer
    # warns. MouseEventWarning is then not needed, though keeping it does
    # no harm: it is one getmouse call that returns nil.
    it 'reaches the terminal on the first getmouse only, without CursesSetup.start' do
      script = "require 'curses'\n" \
               "Curses.init_screen\n" \
               "events = [Curses.getmouse, Curses.getmouse]\n" \
               "Curses.close_screen\n" \
               "puts \"events=\#{events.inspect}\""
      output, status = run_in_pty(script)

      expect(status).to eq(0), output
      expect(output).to include('events=[nil, nil]')
      expect(output.scan(warning_text).size).to eq(1), output
    end

    [false, true].each do |verbose|
      it "never reaches the terminal after CursesSetup.start, with $VERBOSE #{verbose}" do
        script = "$VERBOSE = #{verbose}\n" \
                 "require #{setup_file.inspect}\n" \
                 "CursesSetup.start\n" \
                 "after_start = $VERBOSE\n" \
                 "events = [Curses.getmouse, Curses.getmouse]\n" \
                 "Curses.close_screen\n" \
                 "puts \"verbose=\#{after_start.inspect} events=\#{events.inspect}\""
        output, status = run_in_pty(script)

        expect(status).to eq(0), output
        expect(output).to include("verbose=#{verbose} events=[nil, nil]")
        expect(output).not_to include(warning_text)
      end
    end

    # $VERBOSE is shared by every thread, so the silent getmouse must run
    # before the client starts one. Starts the real client against a port
    # nothing listens on (it exits 1 when the connection is refused) and
    # records the first getmouse of the run.
    it 'is used up by the real client at startup, before it starts any thread' do
      repo = File.expand_path('../..', __dir__)
      Dir.mktmpdir('profanity-mouse-warning') do |dir|
        record = File.join(dir, 'first_getmouse')
        preload = File.join(dir, 'record_first_getmouse.rb')
        File.write(preload, <<~RUBY)
          require 'curses'
          Curses.singleton_class.prepend(Module.new do
            def getmouse
              unless File.exist?(#{record.inspect})
                File.write(#{record.inspect}, "threads=\#{Thread.list.size} verbose=\#{$VERBOSE.inspect}")
              end
              super
            end
          end)
        RUBY
        port = TCPServer.open('127.0.0.1', 0) { |server| server.addr[1] }
        client = ['-r', preload, File.join(repo, 'profanity.rb'), "--port=#{port}",
                  "--settings-file=#{File.join(repo, 'templates', 'default.xml')}"]

        output, status = run_in_pty(args: client, extra_env: { 'HOME' => dir })

        expect(output).to include('Is the game server running?')
        expect(status).to eq 1
        expect(File).to exist(record), 'the client never called Curses.getmouse at startup'
        expect(File.read(record)).to eq 'threads=1 verbose=nil'
      end
    end
  end
end
