# frozen_string_literal: true

# Loaded into profanity.rb by replay.rb (through RUBYOPT=-r) to measure the
# client from inside. Nothing here changes what the client does.
#
# At exit it writes JSON to $PFE_BENCH_OUT:
#   cpu        - CPU seconds of the whole process (user + system)
#   utime, stime
#   counters   - server_thread_cpu: exact CPU seconds of the thread that
#                reads and processes server lines (ServerReader#run), and
#                highlights (with PFE_BENCH_COUNT_HIGHLIGHTS=1)
#
# Optional profilers (each needs its gem installed outside the bundle; see
# README.md):
#   PFE_BENCH_VERNIER=FILE    per-thread report of running samples, self and
#                             inclusive (vernier, wall mode)
#   PFE_BENCH_STACKPROF=FILE  stackprof CPU dump. stackprof samples whichever
#                             thread holds the GVL, so with ProfanityFE's
#                             threads it misattributes time; prefer vernier.

require 'json'

# State shared by the measurement hooks below.
module PfeBench
  # Measurements written at exit; hooks add to it.
  COUNTERS = {}

  module_function

  # Module#name, which a module may override (REXML::Functions does).
  #
  # @param mod [Module]
  # @return [String, nil]
  def module_name(mod)
    Module.instance_method(:name).bind_call(mod)
  end

  # Run the block once, when the class or module named +name+ has been
  # defined (its body has been read).
  #
  # @param name [String]
  # @yieldparam mod [Module] the class or module
  # @return [void]
  def when_defined(name)
    trace = TracePoint.new(:end) do |tp|
      next unless tp.self.is_a?(Module) && module_name(tp.self) == name

      trace.disable
      yield tp.self
    end
    trace.enable
  end

  # @return [Float] CPU seconds of the calling thread
  def thread_cpu
    Process.clock_gettime(Process::CLOCK_THREAD_CPUTIME_ID)
  end

  # Times ServerReader#run: everything the server thread does.
  module ServerThreadTimer
    # @param server [IO]
    # @return [Symbol] whatever ServerReader#run returns
    def run(server)
      started = PfeBench.thread_cpu
      super
    ensure
      PfeBench::COUNTERS[:server_thread_cpu] = (PfeBench.thread_cpu - started).round(4)
    end
  end

  # Counts HighlightProcessor.apply_highlights calls, distinct texts and
  # the thread CPU spent in them.
  module HighlightCounter
    # @param text [String]
    # @param line_colors [Array<Hash>]
    # @return [Array<Hash>] whatever apply_highlights returns
    def apply_highlights(text, line_colors = [])
      started = PfeBench.thread_cpu
      super
    ensure
      stats = (PfeBench::COUNTERS[:highlights] ||= { calls: 0, repeats: 0, cpu: 0.0, seen: {} })
      stats[:calls] += 1
      stats[:seen].key?(text) ? stats[:repeats] += 1 : stats[:seen][text.dup] = true
      stats[:cpu] += PfeBench.thread_cpu - started
    end
  end
end

PfeBench.when_defined('ServerReader') { |klass| klass.prepend(PfeBench::ServerThreadTimer) }

if ENV['PFE_BENCH_COUNT_HIGHLIGHTS'] == '1'
  PfeBench.when_defined('HighlightProcessor') { |mod| mod.singleton_class.prepend(PfeBench::HighlightCounter) }
end

if (stackprof_out = ENV.fetch('PFE_BENCH_STACKPROF', nil)) && !stackprof_out.empty?
  require 'stackprof'
  StackProf.start(mode: :cpu, interval: 1000, raw: true)
  at_exit do
    StackProf.stop
    StackProf.results(stackprof_out)
  end
end

if (vernier_out = ENV.fetch('PFE_BENCH_VERNIER', nil)) && !vernier_out.empty?
  require 'vernier'
  Vernier.start_profile(mode: :wall, interval: 250)
  at_exit do
    result = Vernier.stop_profile
    stacks = result.stack_table
    report = []
    result.threads.each_value do |thread|
      categories = thread[:sample_categories] || []
      self_time = Hash.new(0)
      inclusive = Hash.new(0)
      total = 0
      thread[:samples].each_with_index do |stack_index, i|
        # Category 0 is a running sample; 1 idle and 2 stalled (waiting for the GVL).
        next unless (categories[i] || 0).zero?

        weight = thread[:weights][i]
        total += weight
        stack = stacks.stack(stack_index)
        leaf = stack.leaf_frame
        self_time["#{leaf.label} #{File.basename(leaf.filename.to_s)}"] += weight
        stack.each_frame.map { |frame| "#{frame.label} #{File.basename(frame.filename.to_s)}" }.uniq.each do |key|
          inclusive[key] += weight
        end
      end
      next if total.zero?

      report << "== thread #{thread[:name]}: #{total} running samples"
      report << '-- self'
      self_time.sort_by { |_, v| -v }.first(30).each { |k, v| report << format('%6d %5.1f%% %s', v, 100.0 * v / total, k) }
      report << '-- inclusive'
      inclusive.sort_by { |_, v| -v }.first(50).each { |k, v| report << format('%6d %5.1f%% %s', v, 100.0 * v / total, k) }
    end
    File.write(vernier_out, report.join("\n"))
  end
end

at_exit do
  if (out = ENV.fetch('PFE_BENCH_OUT', nil))
    times = Process.times
    if (highlights = PfeBench::COUNTERS[:highlights])
      highlights.delete(:seen)
      highlights[:cpu] = highlights[:cpu].round(4)
    end
    File.write(out, JSON.generate(cpu: Process.clock_gettime(Process::CLOCK_PROCESS_CPUTIME_ID),
                                  utime: times.utime, stime: times.stime, counters: PfeBench::COUNTERS))
  end
end
