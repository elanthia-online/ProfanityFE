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
  let(:shared_state) { Struct.new(:room_title, :blue_links).new(nil, false) }
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

    # Post strings are free text: their own words, commas and " and " are
    # not names or list separators.
    it 'keeps the name before a "whose form ..." post string' do
      expect(indicator_label('Also here: Goblin Bait Aldric whose form wavers within a cloud of grey smoke.')).to eq 'Aldric'
    end

    it 'keeps a post string with its own " and " inside one entry' do
      expect(indicator_label('Also here: Daydreamer Brenna who is coated in grime and surrounded by filth, ' \
                             'Delphine (prone) and Druid Corwin who is sitting.')).to eq 'Brenna, Delphine, Corwin'
    end

    it 'keeps the name before a bare verb' do
      expect(indicator_label('Also here: Stray Eamon is surrounded by swirling flames and Fenna.')).to eq 'Eamon, Fenna'
    end

    it 'reads a title with lowercase words as a title' do
      expect(indicator_label('Also here: Keeper of Secrets Aldric.')).to eq 'Aldric'
    end

    it 'reads a list without a final period (GemStone)' do
      expect(indicator_label('Also here: Aldric, Brenna')).to eq 'Aldric, Brenna'
    end

    context 'with the players\' links' do
      def linked_label(text, links)
        host.update_room_players_indicator(text, links: links)
        indicator_updates.last[:label]
      end

      it 'names each player by its link, in list order' do
        text = 'Also here: Lord Aldric the Bold and Brenna who wears a Sun Crown, Glorious.'
        links = [{ start: 36, end: 42, exist: '-2', noun: 'Brenna' }, { start: 16, end: 31, exist: '-1', noun: 'Aldric' }]
        expect(linked_label(text, links)).to eq 'Aldric, Brenna'
      end

      it 'takes the link text when the link has no noun' do
        expect(linked_label('Also here: Aldric.', [{ start: 11, end: 17, exist: '-1' }])).to eq 'Aldric'
      end

      # Only players have negative ids; any other link leaves the text to
      # name the players.
      it 'reads the text when no link is a player\'s' do
        expect(linked_label('Also here: Aldric.', [{ start: 11, end: 17, exist: '42', noun: 'rat' }])).to eq 'Aldric'
      end

      # Positions in the text as given; the label is read from it stripped.
      it 'moves the links with text that has leading whitespace' do
        expect(linked_label('  Also here: Aldric.', [{ start: 13, end: 19, exist: '-1' }])).to eq 'Aldric'
      end
    end
  end
end
