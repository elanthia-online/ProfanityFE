# frozen_string_literal: true

# Tests the label RoomAssembler hands the room players indicator for an
# "Also here:" line: the players' bare names. Every example reads the
# events the assembler emits, which is all the indicator ever receives.
# What the room window shows for the inline room lines is in
# spec/lib/room_inline_lines_spec.rb.

require_relative '../../lib/event_bus'
require_relative '../../lib/pending_render'
require_relative '../../lib/room_assembler'

RSpec.describe RoomAssembler do
  subject(:host) { assembler(room_windows: { 'room' => Object.new }) }

  let(:event_bus) { EventBus.new }
  let(:shared_state) { Struct.new(:room_title).new(nil) }
  # Every indicator update the assembler emitted, oldest first.
  let(:indicator_updates) { [] }

  before { event_bus.on(:indicator_update) { |data| indicator_updates << data } }

  # An assembler with only the collaborators it needs here: the layout's
  # room windows (the assembler only asks whether there is one) and a
  # writable room_title on shared state.
  #
  # @param room_windows [Hash] the window manager's room windows by id
  def assembler(room_windows:)
    described_class.new(window_mgr: Struct.new(:room).new(room_windows), event_bus: event_bus,
                        pending_render: PendingRender.new, shared_state: shared_state)
  end

  describe 'the room players indicator' do
    # The label the room players indicator shows for an "Also here:" line.
    def indicator_label(text)
      host.update_room_players_indicator(text)
      indicator_updates.last[:label]
    end

    it 'keeps the last player when the line ends with a period' do
      expect(indicator_label('Also here: Bob and Alice.')).to eq 'Bob, Alice'
    end

    it 'keeps every player in a comma-separated list' do
      expect(indicator_label('Also here: Bob, Carol and Alice.')).to eq 'Bob, Carol, Alice'
    end

    it 'keeps a lone player followed by a period' do
      expect(indicator_label('Also here: Bob.')).to eq 'Bob'
    end

    it 'drops titles and status descriptions, keeping the bare name' do
      expect(indicator_label('Also here: Grand Lord Treeze who is sitting and Dark Summoner Vlachodimos.'))
        .to eq 'Treeze, Vlachodimos'
    end
  end
end
