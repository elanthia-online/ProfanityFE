# frozen_string_literal: true

# Turn a captured game stream into a replay fixture for replay.rb.
#
# Input is one of:
# - a Lich XML log written by logxml with --timestamp (every line starts
#   "YYYY-MM-DD HH:MM:SS ZONE: "), or a recording made by record.rb, which
#   uses the same prefix. The zone may be a name (NZDT) or an offset (+13).
#   logxml's header and footer lines, its reget block (the untimestamped
#   lines before the first timestamped one) and its comments (the client's
#   own commands, the reget marker) are skipped; an untimestamped line after
#   a timestamped one belongs to it.
# - a plain stream with no timestamps (such as the files in spec/fixtures),
#   paced at --rate lines a second.
#
# Output is one JSON object per line, {"t": seconds_from_start, "data":
# "line\nline\n"}: a chunk of lines to send in one write. A chunk ends after
# a line holding a <prompt, or when the timestamp's second changes, which is
# close to how the game sends one packet per command's output. A pause
# longer than --max-gap seconds (an idle character, a clock change) is
# shortened to --max-gap; time never runs backwards.
#
# usage: ruby script/bench/stream_fixture.rb [options] IN OUT
#   --drop-inv            remove DragonRealms' worn-inventory dumps
#   --from=TIME --to=TIME keep only lines in this range: HH:MM:SS (on the
#                         first line's date; a --to before --from means the
#                         next day) or "YYYY-MM-DD HH:MM:SS"
#   --rate=N              lines a second for input without timestamps (20)
#   --max-gap=SECONDS     longest pause kept (60)

require 'json'
require 'optparse'
require 'fileutils'

# Converts captured stream lines into replay chunks (see the file comment).
class StreamFixture
  # A logxml or record.rb line prefix: date, time (optional fraction), zone
  # name or numeric offset, colon.
  TIMESTAMP = /\A(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)(?:\.\d+)? ([A-Za-z]+|[+-]\d\d(?::?\d\d)?): ?/

  # logxml's file header and footer lines: a date and time, alone.
  HEADER = /\A\d{4}-\d\d-\d\d \d{1,2}:\d\d\S*(?: \S+)?\z/

  # logxml's own comments: the client's commands and the reget marker.
  LOG_COMMENT = /\A<!-- (?:CLIENT -->|Above contents from reget)/

  # Where DragonRealms' worn-inventory dump starts on a line.
  INV_START = "<clearStream id='inv'"

  # Where any pushed stream ends.
  POP = '<popStream/>'

  # Counts from the last {#convert}: :lines (kept in range), :kept,
  # :dropped (inventory lines removed), :skipped (headers, reget, comments),
  # :shortened (pauses cut to max_gap), :inv_open (1 when the input ended
  # inside an inventory dump).
  #
  # @return [Hash{Symbol => Integer}]
  attr_reader :stats

  # @param drop_inv [Boolean] remove the worn-inventory stream: from
  #   +<clearStream id='inv'+ to the next +<popStream/>+ (or the next
  #   prompt, for logs written without stream lines), keeping whatever else
  #   shares those lines. Replay with and without it to measure what the
  #   inventory dumps cost.
  # @param from [String, nil] see the file comment
  # @param to [String, nil] see the file comment
  # @param rate [Numeric] lines a second for input without timestamps
  # @param max_gap [Numeric] longest pause kept, in seconds
  def initialize(drop_inv: false, from: nil, to: nil, rate: 20, max_gap: 60)
    @drop_inv = drop_inv
    @from = from
    @to = to
    @rate = rate.to_f
    @max_gap = max_gap.to_f
    @stats = Hash.new(0)
  end

  # Convert lines into chunks.
  #
  # @param lines [Enumerable<String>] captured lines, line endings optional
  # @return [Array<Hash{String => Object}>] chunks, each {"t" => Float, "data" => String}
  def convert(lines)
    lines = lines.map { |line| line.chomp.dup.force_encoding(Encoding::UTF_8).scrub }
    @stats = Hash.new(0)
    @in_inv = false
    timed = lines.any? { |line| TIMESTAMP.match?(line) }
    entries = timed ? timed_entries(lines) : lines.each_with_index.map { |line, i| [line, i / @rate] }
    chunks = build_chunks(entries)
    @stats[:inv_open] = 1 if @in_inv
    chunks
  end

  private

  # [line, seconds] for a timestamped input, in range, with log noise
  # skipped and pauses capped.
  #
  # @param lines [Array<String>]
  # @return [Array<Array(String, Float)>]
  def timed_entries(lines)
    entries = []
    window = nil
    previous = nil # [absolute seconds, relative seconds] of the last kept timestamped line
    started = false
    lines.each do |raw|
      # A footer such as "2026-11-08 00:30:00.123 +13:00" would otherwise
      # read as a timestamp and the text "00".
      next @stats[:skipped] += 1 if HEADER.match?(raw)

      match = TIMESTAMP.match(raw)
      unless match
        # The reget block and header come before the first timestamped line.
        if !started || HEADER.match?(raw) || LOG_COMMENT.match?(raw) then @stats[:skipped] += 1
        elsif previous then entries << [raw, previous[1]]
        end
        next
      end

      started = true
      line = raw[match.end(0)..]
      next @stats[:skipped] += 1 if LOG_COMMENT.match?(line)

      wall = Time.utc(*match.captures[0, 6].map(&:to_i))
      window ||= range_for(wall)
      next if window && wall < window.first
      break if window && wall > window.last

      absolute = wall.to_f - offset_seconds(match[7])
      relative = if previous
                   gap = absolute - previous[0]
                   @stats[:shortened] += 1 if gap > @max_gap
                   previous[1] + gap.clamp(0, @max_gap)
                 else
                   0.0
                 end
      previous = [absolute, relative]
      entries << [line, relative]
    end
    entries
  end

  # Group [line, seconds] entries into chunks, dropping inventory dumps.
  #
  # @param entries [Array<Array(String, Float)>]
  # @return [Array<Hash{String => Object}>]
  def build_chunks(entries)
    chunks = []
    current = +''
    current_t = nil
    flush = lambda do
      chunks << { 't' => current_t, 'data' => current } unless current.empty?
      current = +''
    end
    entries.each do |line, t|
      flush.call if current_t && t != current_t
      current_t = t
      @stats[:lines] += 1
      line = drop_inventory(line) if @drop_inv
      next if line.nil?

      current << line << "\n"
      @stats[:kept] += 1
      flush.call if line.include?('<prompt')
    end
    flush.call
    chunks
  end

  # The --from/--to range as times on the same footing as +first+ (wall
  # clock read as UTC), or nil without either option.
  #
  # @param first [Time] the first timestamped line's wall time
  # @return [Range<Time>, nil]
  def range_for(first)
    return nil unless @from || @to

    from = @from ? parse_bound(@from, first) : first
    to = @to ? parse_bound(@to, first) : Time.utc(9999)
    to += 86_400 if @to && to < from && !@to.include?('-')
    from..to
  end

  # @param text [String] "HH:MM:SS", "H:MM:SS" or "YYYY-MM-DD HH:MM:SS"
  # @param first [Time] supplies the date for a bare time
  # @return [Time]
  def parse_bound(text, first)
    date, time = text.include?(' ') ? text.split(' ', 2) : [first.strftime('%Y-%m-%d'), text]
    year, month, day = date.split('-').map(&:to_i)
    hour, minute, second = time.split(':').map(&:to_i)
    Time.utc(year, month, day, hour, minute, second || 0)
  end

  # @param zone [String] a zone name or a numeric offset such as +13 or -03:30
  # @return [Integer] seconds east of UTC for a numeric offset; 0 for a name
  #   (pauses across a clock change are then capped by max_gap instead)
  def offset_seconds(zone)
    match = /\A([+-])(\d\d):?(\d\d)?\z/.match(zone)
    return 0 unless match

    (match[2].to_i * 3600 + match[3].to_i * 60) * (match[1] == '-' ? -1 : 1)
  end

  # The line with the worn-inventory stream removed, or nil when nothing
  # else is on it.
  #
  # @param line [String]
  # @return [String, nil]
  def drop_inventory(line)
    if @in_inv
      pop = line.index(POP)
      if pop
        @stats[:dropped] += 1
        @in_inv = false
        return keep_rest(line[(pop + POP.length)..])
      end
      # A log written without stream lines has no <popStream/>; a dump never
      # holds a prompt, so one ends it.
      unless line.include?('<prompt')
        @stats[:dropped] += 1
        return nil
      end

      @in_inv = false
      return line
    end

    start = line.index(INV_START)
    return line unless start

    @stats[:dropped] += 1
    kept = line[0...start]
    tail = line[start..]
    pop = tail.index(POP)
    if pop
      rest = keep_rest(tail[(pop + POP.length)..])
      kept += rest if rest
    else
      @in_inv = true
    end
    kept.empty? ? nil : kept
  end

  # What follows a dump on its last line, which may start another dump.
  #
  # @param rest [String]
  # @return [String, nil]
  def keep_rest(rest)
    return nil if rest.empty?

    @stats[:dropped] -= 1 if rest.include?(INV_START) # counted again by the recursive call
    drop_inventory(rest)
  end
end

if $PROGRAM_NAME == __FILE__
  options = { drop_inv: false, rate: 20.0, max_gap: 60.0 }
  parser = OptionParser.new do |o|
    o.banner = 'usage: ruby script/bench/stream_fixture.rb [options] IN OUT'
    o.on('--drop-inv', 'remove the worn-inventory dumps') { options[:drop_inv] = true }
    o.on('--from=TIME', 'keep lines from HH:MM:SS or "YYYY-MM-DD HH:MM:SS"') { |v| options[:from] = v }
    o.on('--to=TIME', 'keep lines up to HH:MM:SS or "YYYY-MM-DD HH:MM:SS"') { |v| options[:to] = v }
    o.on('--rate=N', Float, 'lines a second for input without timestamps (20)') { |v| options[:rate] = v }
    o.on('--max-gap=SECONDS', Float, 'longest pause kept (60)') { |v| options[:max_gap] = v }
  end
  parser.parse!
  src, dst = ARGV
  abort parser.help unless src && dst && options[:rate].positive? && options[:max_gap].positive?

  fixture = StreamFixture.new(**options)
  chunks = fixture.convert(File.readlines(src, mode: 'rb'))
  FileUtils.mkdir_p(File.dirname(dst))
  File.open(dst, 'w') { |out| chunks.each { |chunk| out.puts(JSON.generate(chunk)) } }
  stats = fixture.stats
  warn "#{dst}: #{stats[:lines]} lines, #{stats[:kept]} kept, #{stats[:dropped]} inventory lines dropped, " \
       "#{stats[:skipped]} log lines skipped, #{chunks.size} chunks over #{(chunks.last&.fetch('t') || 0).round(1)} s"
  warn "  #{stats[:shortened]} pauses over #{options[:max_gap]} s shortened" if stats[:shortened].positive?
  warn '  the input ended inside an inventory dump' if stats[:inv_open].positive?
  warn '  nothing was kept: check --from/--to' if stats[:kept].zero?
end
