# frozen_string_literal: true

# Record exactly what Lich sends a front end, for replay.rb. See README.md.
#
# Connects to a running Lich's detachable-client port as one more client,
# sends nothing, and writes every line it receives for SECONDS seconds,
# each prefixed with the time it arrived in the Lich log format
# ("YYYY-MM-DD HH:MM:SS TZ: "), so stream_fixture.rb can turn the file
# into a fixture.
#
# Why not use Lich's own XML log? Lich logs the stream as the game sent
# it. What a front end receives differs: Lich rewrites it per client (for
# a client that has not declared the capability, DragonRealms' <a exist>
# links are removed, so lines are shorter), and script output (respond,
# echo) reaches the client but not the log.
#
# If a window is already attached, Lich's detachable-client listener must
# accept several clients at once. Lich 5.23 does; an older Lich may drop
# the attached window. The recording contains everything the character sees,
# including other players' names and speech: keep it out of git
# (script/bench/fixtures/ is ignored).
#
# usage: ruby script/bench/record.rb PORT SECONDS OUT [HOST]

require 'socket'
require 'io/wait'

port, seconds, out, host = ARGV
abort File.read(__FILE__)[/^# usage:.*?\n/] unless port && seconds && out

socket = TCPSocket.new(host || '127.0.0.1', Integer(port))
deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + Float(seconds)
count = 0
pending = String.new(encoding: Encoding::BINARY)
File.open(out, 'wb') do |file|
  write_line = lambda do |line|
    file.write(Time.now.strftime('%Y-%m-%d %H:%M:%S %Z: '), line.delete("\r"), "\n")
    count += 1
  end
  # Read what has arrived and split it into lines here, rather than with
  # gets, which would wait past the deadline for the end of a partial line.
  while (left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).positive?
    next unless socket.wait_readable([left, 1].min)

    begin
      pending << socket.readpartial(65_536)
    rescue EOFError
      break
    end
    write_line.call(pending.slice!(0, pending.index("\n") + 1).chomp) while pending.include?("\n")
  end
  write_line.call(pending) unless pending.empty?
end
socket.close
warn "#{out}: #{count} lines"
