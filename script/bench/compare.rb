# frozen_string_literal: true

# Compare ProfanityFE builds on the same replay. See README.md.
#
# Each round starts one replay.rb per build at the same moment and waits
# for all of them; after --rounds rounds it prints, per build, the median
# whole-process CPU and server-thread CPU with every run, and for each
# build after the first, its median paired difference from the first build
# within the same round.
#
# Run the builds together, never one after the other: on CPUs with
# performance and efficiency cores (Apple silicon, recent Intel), the CPU
# time of the same work can differ by up to about 2x depending on which
# kind of core it lands on, and runs started together share the same conditions.
#
# usage: ruby script/bench/compare.rb [--rounds=N] [replay.rb options] FIXTURE.jsonl LABEL=DIR [LABEL=DIR ...]
#   e.g. ruby script/bench/compare.rb --rounds=3 --speed=4 crafting.jsonl main=../pfe-main branch=.

require_relative 'replay_runs'

# Medians and paired differences of replay results.
module CompareSummary
  module_function

  # @param values [Array<Numeric>]
  # @return [Numeric, nil] the middle value (the upper middle for an even count)
  def median(values)
    sorted = values.compact.sort
    sorted.empty? ? nil : sorted[sorted.size / 2]
  end

  # Summarise rounds of replay results.
  #
  # @param rounds [Array<Hash{String => Hash}>] per round, label => replay.rb JSON
  # @param labels [Array<String>] the builds, the first being the baseline
  # @return [Array<Hash>] per label: label, cpu (median), cpu_runs,
  #   server (median server_thread_cpu), server_runs, and for labels after
  #   the first, server_delta_pct (median of the per-round percentage
  #   difference from the baseline's server-thread CPU)
  def summarise(rounds, labels)
    labels.map do |label|
      runs = rounds.map { |round| round[label] }.compact
      cpu = runs.map { |run| run['cpu_s'] }
      server = runs.map { |run| run.dig('counters', 'server_thread_cpu') }
      row = { label: label, cpu: median(cpu), cpu_runs: cpu, server: median(server), server_runs: server }
      unless label == labels.first
        deltas = rounds.filter_map do |round|
          base = round[labels.first]&.dig('counters', 'server_thread_cpu')
          mine = round[label]&.dig('counters', 'server_thread_cpu')
          (mine - base) * 100.0 / base if base&.positive? && mine
        end
        row[:server_delta_pct] = median(deltas)
      end
      row
    end
  end
end

if $PROGRAM_NAME == __FILE__
  rounds_count = 3
  replay_options = []
  positional = []
  ARGV.each do |arg|
    if arg.start_with?('--rounds=') then rounds_count = arg.split('=', 2).last.to_i
    elsif arg.start_with?('--') then replay_options << arg
    else positional << arg
    end
  end
  fixture, *builds = positional
  usage = File.read(__FILE__)[/^# usage:.*?\n(?:#.*\n)*/]
  abort usage unless fixture && !builds.empty? && builds.all? { |b| b.include?('=') }
  builds = builds.map { |b| b.split('=', 2) }
  labels = builds.map(&:first)
  abort 'labels must differ' unless labels.uniq.size == labels.size
  builds.each { |_, dir| ReplayRuns.check_checkout(dir) }
  ReplayRuns.stop_all_on_signal
  failures = 0

  rounds = Array.new(rounds_count) do |i|
    threads = builds.map do |label, dir|
      Thread.new do
        result, err = ReplayRuns.run("--code=#{dir}", "--label=#{label}", *replay_options, fixture)
        warn "#{label}: replay failed: #{err.lines.last(5).join}" unless result
        [label, result]
      end
    end
    round = threads.map(&:value).to_h
    failures += round.count { |_, r| r.nil? }
    round.compact!
    warn "round #{i + 1}/#{rounds_count}: " + round.map { |l, r| "#{l} #{r['cpu_s']}" }.join(', ')
    round
  end

  CompareSummary.summarise(rounds, labels).each do |row|
    line = format('%-16s cpu %-8s server %-8s', row[:label], row[:cpu], row[:server])
    line += format(' server vs %s: %+.1f%%', labels.first, row[:server_delta_pct]) if row[:server_delta_pct]
    puts line
    puts "  cpu runs #{row[:cpu_runs].inspect}  server runs #{row[:server_runs].inspect}"
  end
  abort "#{failures} replay(s) failed" if failures.positive?
end
