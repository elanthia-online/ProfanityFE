# frozen_string_literal: true

require_relative '../../../script/bench/stream_fixture'

RSpec.describe StreamFixture do
  # U+FFFD, what scrub puts in place of an invalid byte.
  let(:replacement) { [0xFFFD].pack('U') }

  # Convert +lines+ and return the chunks.
  def convert(lines, **options)
    described_class.new(**options).convert(lines)
  end

  # A line as Lich logs it (or record.rb records it).
  def logged(time, text)
    "2026-11-07 #{time} NZDT: #{text}"
  end

  describe 'with timestamped lines' do
    it 'strips the timestamp and times each chunk from the first line' do
      chunks = convert([logged('19:15:20', 'You hobble north.'), logged('19:15:22', 'Obvious paths: north.')])

      expect(chunks).to eq([{ 't' => 0.0, 'data' => "You hobble north.\n" },
                            { 't' => 2.0, 'data' => "Obvious paths: north.\n" }])
    end

    it 'ends a chunk after a prompt, as the game ends a command reply' do
      chunks = convert([logged('19:15:20', 'You hobble north.'),
                        logged('19:15:20', '<prompt time="1">&gt;</prompt>'),
                        logged('19:15:20', 'Someone arrives.')])

      expect(chunks.map { |c| c['data'] }).to eq(["You hobble north.\n<prompt time=\"1\">&gt;</prompt>\n", "Someone arrives.\n"])
      expect(chunks.map { |c| c['t'] }).to eq([0.0, 0.0])
    end

    it 'keeps the lines of one second together until a prompt' do
      chunks = convert([logged('19:15:20', 'one'), logged('19:15:20', 'two'), logged('19:15:21', 'three')])

      expect(chunks.map { |c| c['data'] }).to eq(["one\ntwo\n", "three\n"])
    end

    it 'keeps only the lines from --from to --to, timed from the first kept line' do
      lines = %w[19:00:00 19:00:05 19:00:09 19:00:12].map { |t| logged(t, "at #{t}") }

      chunks = convert(lines, from: '19:00:05', to: '19:00:09')

      expect(chunks).to eq([{ 't' => 0.0, 'data' => "at 19:00:05\n" }, { 't' => 4.0, 'data' => "at 19:00:09\n" }])
    end

    it 'keeps blank lines, which the client treats specially' do
      chunks = convert([logged('19:15:20', 'text'), logged('19:15:20', '')])

      expect(chunks.first['data']).to eq("text\n\n")
    end
  end

  describe 'with a logxml log' do
    it "skips logxml's header, reget block, comments and footer, and keeps continuation lines" do
      lines = ['2026-11-07 19:15:00 NZDT', 'reget line', '<!-- Above contents from reget; full logging now active -->',
               logged('19:15:01', 'You hobble north.'), logged('19:15:01', '<!-- CLIENT -->look<!-- ENDCLIENT -->'),
               'a line logxml wrapped', '2026-11-07 19:30:00.123 +13:00']
      fixture = described_class.new

      chunks = fixture.convert(lines)

      expect(chunks).to eq([{ 't' => 0.0, 'data' => "You hobble north.\na line logxml wrapped\n" }])
      expect(fixture.stats[:skipped]).to eq(5)
    end

    it 'reads a numeric zone as part of the timestamp, not as game text' do
      chunks = convert(['2026-11-08 06:35:30 +13: You hobble north.', '2026-11-08 06:35:31 +13:00: Next.'])

      expect(chunks).to eq([{ 't' => 0.0, 'data' => "You hobble north.\n" }, { 't' => 1.0, 'data' => "Next.\n" }])
    end

    it 'times lines in different numeric zones by their real distance' do
      chunks = convert(['2026-11-08 06:35:30 +13: one', '2026-11-07 17:35:40 +00: two'])

      expect(chunks.map { |c| c['t'] }).to eq([0.0, 10.0])
    end
  end

  describe 'time ranges and gaps' do
    let(:midnight) { [logged('23:59:58', 'a'), logged('23:59:59', 'b'), "2026-11-08 00:00:01 NZDT: c", "2026-11-08 00:00:02 NZDT: d"] }

    it 'keeps a --from/--to range that crosses midnight' do
      chunks = convert(midnight, from: '23:59:59', to: '00:00:01')

      expect(chunks.map { |c| c['data'] }).to eq(%W[b\n c\n])
      expect(chunks.map { |c| c['t'] }).to eq([0.0, 2.0])
    end

    it 'keeps the lines after midnight when only --from is given' do
      chunks = convert(midnight, from: '23:59:59')

      expect(chunks.map { |c| c['data'] }.join).to eq("b\nc\nd\n")
    end

    it 'accepts a bound without a leading zero, or with a date' do
      lines = [logged('09:00:00', 'early'), logged('09:10:00', 'kept'), logged('10:00:00', 'late')]

      expect(convert(lines, from: '9:05:00', to: '9:30:00').map { |c| c['data'] }).to eq(["kept\n"])
      expect(convert(lines, from: '2026-11-07 09:05:00', to: '2026-11-07 09:30:00').size).to eq(1)
    end

    it 'never runs time backwards, as a clock change or zone change would' do
      chunks = convert(['2026-04-05 02:59:59 NZDT: before', '2026-04-05 02:00:00 NZST: after', '2026-04-05 02:00:01 NZST: next'])

      expect(chunks.map { |c| c['t'] }).to eq([0.0, 1.0])
      expect(chunks.first['data']).to eq("before\nafter\n")
    end

    it 'shortens a pause longer than max_gap, and counts it' do
      fixture = described_class.new(max_gap: 30)

      chunks = fixture.convert([logged('19:00:00', 'a'), logged('20:00:00', 'b'), logged('20:00:05', 'c')])

      expect(chunks.map { |c| c['t'] }).to eq([0.0, 30.0, 35.0])
      expect(fixture.stats[:shortened]).to eq(1)
    end
  end

  it 'replaces invalid UTF-8 bytes rather than failing' do
    chunks = convert(["caf#{233.chr} au lait"])

    expect(chunks.first['data']).to eq("caf#{replacement} au lait\n")
  end

  describe 'with lines that have no timestamp' do
    it 'paces them at the given rate, one chunk per line unless a prompt follows' do
      chunks = convert(['first', 'second', '<prompt time="1">&gt;</prompt>'], rate: 2)

      expect(chunks.map { |c| c['t'] }).to eq([0.0, 0.5, 1.0])
    end
  end

  describe 'drop_inv' do
    let(:dump_start) { "<right>Empty</right><clearStream id='inv' ifClosed=''/><pushStream id='inv'/>Your worn items are:" }

    it 'removes a worn-inventory dump spread over several lines and counts it' do
      fixture = described_class.new(drop_inv: true)
      chunks = fixture.convert([logged('19:15:20', dump_start), logged('19:15:20', '  a lumium scale helm'),
                                logged('19:15:20', '<popStream/>'), logged('19:15:20', 'You hobble north.')])

      expect(chunks.map { |c| c['data'] }.join).to eq("<right>Empty</right>\nYou hobble north.\n")
      expect(fixture.stats).to include(lines: 4, kept: 2, dropped: 3)
    end

    it 'keeps text that follows the end of the dump on the same line' do
      chunks = convert([logged('19:15:20', dump_start), logged('19:15:20', '<popStream/>You feel rested.')], drop_inv: true)

      expect(chunks.map { |c| c['data'] }.join).to eq("<right>Empty</right>\nYou feel rested.\n")
    end

    it 'removes a dump that opens and closes on one line, keeping both sides' do
      line = "<left>rope</left><clearStream id='inv'/><pushStream id='inv'/>  a helm<popStream/>You nod."

      chunks = convert([logged('19:15:20', line)], drop_inv: true)

      expect(chunks.first['data']).to eq("<left>rope</left>You nod.\n")
    end

    it 'leaves other pushed streams alone' do
      lines = ["<pushStream id='percWindow'/>Regenerate", '<popStream/>'].map { |l| logged('19:15:20', l) }

      chunks = convert(lines, drop_inv: true)

      expect(chunks.first['data']).to eq("<pushStream id='percWindow'/>Regenerate\n<popStream/>\n")
    end

    it 'ends a dump at the next prompt when the log has no stream tags' do
      fixture = described_class.new(drop_inv: true)

      chunks = fixture.convert([logged('19:15:20', dump_start), logged('19:15:20', '  a helm'),
                                logged('19:15:20', '<prompt time="1">&gt;</prompt>'), logged('19:15:21', 'You nod.')])

      expect(chunks.map { |c| c['data'] }.join).to eq("<right>Empty</right>\n<prompt time=\"1\">&gt;</prompt>\nYou nod.\n")
      expect(fixture.stats[:dropped]).to eq(2)
      expect(fixture.stats[:inv_open]).to eq(0)
    end

    it 'reports a dump the input never closed' do
      fixture = described_class.new(drop_inv: true)

      fixture.convert([logged('19:15:20', dump_start), logged('19:15:20', '  a helm')])

      expect(fixture.stats[:inv_open]).to eq(1)
    end

    it 'removes a second dump that starts on the line where the first ends' do
      second = "<clearStream id='inv'/><pushStream id='inv'/>  a cloak"
      lines = [logged('19:15:20', dump_start), logged('19:15:20', "<popStream/>between#{second}"),
               logged('19:15:20', '<popStream/>after')]

      chunks = convert(lines, drop_inv: true)

      expect(chunks.map { |c| c['data'] }.join).to eq("<right>Empty</right>\nbetween\nafter\n")
    end

    it 'keeps the dump when drop_inv is off' do
      chunks = convert([logged('19:15:20', dump_start), logged('19:15:20', '<popStream/>')])

      expect(chunks.first['data']).to eq("#{dump_start}\n<popStream/>\n")
    end
  end
end
