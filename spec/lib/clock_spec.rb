# frozen_string_literal: true

# Tests Clock: the time it reads, the server time offset it holds and the
# two timestamp formats it writes.

require_relative '../../lib/clock'

RSpec.describe Clock do
  # A clock stopped at +time+.
  def clock_at(time) = described_class.new(now: -> { time })

  describe '#now' do
    it 'reads the time it was given' do
      time = Time.new(2026, 9, 29, 9, 5, 7)

      expect(clock_at(time).now).to equal time
    end

    it 'reads the given source again at every call' do
      readings = [Time.new(2026, 9, 29, 9, 5, 7), Time.new(2026, 9, 29, 9, 5, 8)]
      clock = described_class.new(now: -> { readings.shift })

      expect([clock.now.sec, clock.now.sec]).to eq [7, 8]
    end

    it 'reads the system time by default' do
      before = Time.now
      now = described_class.new.now

      expect(now).to be_between(before, Time.now)
    end
  end

  describe '#server_time_offset' do
    it 'is zero until the game clock is known' do
      expect(described_class.new.server_time_offset).to eq 0.0
    end

    it 'keeps the offset it was given' do
      clock = described_class.new
      clock.server_time_offset = -3.25

      expect(clock.server_time_offset).to eq(-3.25)
    end

    it 'belongs to one clock only' do
      clock = described_class.new
      clock.server_time_offset = 7.0

      expect(described_class.new.server_time_offset).to eq 0.0
    end
  end

  describe '#hh_mm' do
    {
      Time.new(2026, 9, 29, 9, 5, 7)    => '09:05',
      Time.new(2026, 9, 29, 0, 0, 0)    => '00:00',
      Time.new(2026, 9, 29, 23, 59, 59) => '23:59',
      Time.new(2026, 9, 29, 14, 30, 0)  => '14:30'
    }.each do |time, shown|
      it "writes #{time.strftime('%T')} as #{shown}" do
        expect(clock_at(time).hh_mm).to eq shown
      end
    end
  end

  describe '#h_mm_ss' do
    {
      Time.new(2026, 9, 29, 9, 5, 7)    => '9:05:07',
      Time.new(2026, 9, 29, 0, 0, 0)    => '0:00:00',
      Time.new(2026, 9, 29, 10, 0, 9)   => '10:00:09',
      Time.new(2026, 9, 29, 23, 59, 59) => '23:59:59'
    }.each do |time, shown|
      it "writes #{time.strftime('%T')} as #{shown}" do
        expect(clock_at(time).h_mm_ss).to eq shown
      end
    end
  end
end
