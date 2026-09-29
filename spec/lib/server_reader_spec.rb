# frozen_string_literal: true

# Tests ServerReader's batched flush: the screen is drawn only once no more
# server data is waiting, a pending room render is drawn with that flush
# (before the screen update), and a line the handler drops is neither
# processed nor followed by a flush or a terminal title write.

require_relative '../spec_helper'
require_relative '../../lib/server_reader'
require_relative '../../lib/event_bus'

RSpec.describe ServerReader do
  let(:timeline) { [] }
  let(:pending_render) { PendingRender.new }
  let(:event_bus) { EventBus.new.tap { |bus| bus.on(:room_render) { timeline << :room_render } } }
  # Parses nothing: records each step and asks for what the line says.
  let(:handler) do
    timeline = self.timeline
    pending = pending_render
    Object.new.tap do |obj|
      obj.define_singleton_method(:prepare_line) { |line| line == 'drop' ? nil : line }
      obj.define_singleton_method(:process_line) do |line|
        timeline << [:process, line]
        pending.request_update unless line == 'quiet'
        pending.request_room_render if line == 'room'
      end
    end
  end
  let(:state) do
    timeline = self.timeline
    Object.new.tap { |obj| obj.define_singleton_method(:update_terminal_title) { timeline << :title } }
  end
  let(:reader) do
    described_class.new(line_handler: handler, pending_render: pending_render, event_bus: event_bus,
                        cmd_buffer: Struct.new(:window).new(nil), shared_state: state)
  end

  before { allow(Curses).to receive(:doupdate) { timeline << :doupdate } }

  # Feed lines through #run; +waiting+ says, per line, whether more server
  # data is waiting when that line's flush is considered.
  def read_lines(lines, waiting: [])
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    answers = waiting.dup
    allow(IO).to receive(:select) { answers.shift ? [[server], [], []] : nil }
    reader.run(server)
  end

  it 'draws the screen once, after the last line of a burst' do
    read_lines(%w[one two three], waiting: [true, true, false])

    expect(timeline).to eq [[:process, 'one'], :title, [:process, 'two'], :title,
                            [:process, 'three'], :doupdate, :title]
  end

  it 'draws nothing after a line that asked for no update' do
    read_lines(%w[quiet])

    expect(timeline).to eq [[:process, 'quiet'], :title]
  end

  it 'keeps a room render pending while data is waiting and draws it before the screen update' do
    read_lines(%w[room two], waiting: [true, false])

    expect(timeline).to eq [[:process, 'room'], :title, [:process, 'two'], :room_render, :doupdate, :title]
    expect(pending_render.room_render_requested?).to be false
  end

  it 'neither processes nor flushes a dropped line, nor writes the terminal title' do
    read_lines(%w[drop])

    expect(timeline).to be_empty
  end

  it 'reports a disconnect at the end of the stream' do
    expect(read_lines(%w[one])).to eq :disconnected
  end
end
