# frozen_string_literal: true

# lib/curses_setup.rb, run in a fresh Ruby with the real curses library
# (spec_helper replaces Curses with a stub, so it can't be tested in this
# process). Requiring the file must leave the terminal alone; only
# CursesSetup.start takes it over.

require 'open3'
require 'pty'
require 'timeout'

RSpec.describe 'lib/curses_setup.rb' do
  let(:setup_file) { File.expand_path('../../lib/curses_setup.rb', __dir__) }
  let(:env) { { 'TERM' => 'xterm-256color', 'GEM_PATH' => Gem.path.join(File::PATH_SEPARATOR) } }

  # Run +script+ in a fresh Ruby inside a pseudo-terminal until it exits.
  #
  # @return [Array(String, Integer)] everything written to the terminal, and
  #   the exit status
  def run_in_pty(script)
    output = +''
    status = nil
    PTY.spawn(env, RbConfig.ruby, '-e', script) do |reader, _writer, pid|
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
end
