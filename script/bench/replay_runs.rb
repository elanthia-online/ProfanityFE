# frozen_string_literal: true

# Running replay.rb from compare.rb and fleet.rb: each replay is a child
# process this module keeps track of, so a TERM or Ctrl-C to the parent
# ends every replay (and, through replay.rb's own cleanup, every client).

require 'json'
require 'open3'
require 'rbconfig'

# Child replay.rb processes (see the file comment).
module ReplayRuns
  # The replay script.
  REPLAY = File.join(__dir__, 'replay.rb')

  @pids = []
  @lock = Mutex.new

  module_function

  # Abort unless +dir+ is a ProfanityFE checkout.
  #
  # @param dir [String]
  # @return [void]
  def check_checkout(dir)
    abort "no profanity.rb in #{dir}" unless File.file?(File.join(dir, 'profanity.rb'))
  end

  # End every running replay, then exit, on INT or TERM.
  #
  # @return [void]
  def stop_all_on_signal
    %w[INT TERM].each do |signal|
      trap(signal) do
        @pids.dup.each { |pid| Process.kill('TERM', pid) rescue nil }
        exit(128 + Signal.list.fetch(signal))
      end
    end
  end

  # Run replay.rb and wait for it.
  #
  # @param args [Array<String>] replay.rb arguments
  # @return [Array(Hash, nil), String] its JSON result (nil when it failed)
  #   and what it wrote to stderr
  def run(*args)
    Open3.popen3(RbConfig.ruby, REPLAY, *args) do |stdin, stdout, stderr, wait|
      stdin.close
      @lock.synchronize { @pids << wait.pid }
      out = Thread.new { stdout.read }
      err = Thread.new { stderr.read }
      status = wait.value
      @lock.synchronize { @pids.delete(wait.pid) }
      result = status.success? ? JSON.parse(out.value.lines.last) : nil
      [result, err.value]
    end
  end
end
