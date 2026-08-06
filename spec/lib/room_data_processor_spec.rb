# frozen_string_literal: true

# Tests RoomDataProcessor#process_room_data's room-title capture (the :title mode).
#
# The RoomWindow re-brackets whatever bare title it is handed (see
# RoomWindow#render: "[#{@title}]"), so process_room_data must hand it a title
# with ITS OWN brackets already stripped. The tricky part is that the game's
# closing bracket appears in two shapes: "[Room] (230008)" (a RealID follows the
# bracket) and "[Room - 2071]" / "[Room]" (the bracket is trailing). Missing the
# trailing case leaves a stray "]" that render then doubles into "]]".

require_relative '../../lib/event_bus'
require_relative '../../lib/room_data_processor'

# Minimal host that includes RoomDataProcessor and supplies only the collaborators
# #process_room_data touches in :title mode: a room-window presence check, a
# writable room_title on shared state, and the parse_room_subtitle helper that
# lives on GameTextProcessor in production.
class RoomTitleHost
  include RoomDataProcessor

  attr_accessor :room_capture_mode, :room_pending_title, :room_pending_title_colors,
                :current_stream, :current_raw_line, :line_colors
  attr_reader :wm, :state

  # @param has_room_window [Boolean] whether the layout has a RoomWindow (only
  #   then is the pending title captured)
  def initialize(has_room_window: true)
    @event_bus = EventBus.new
    @wm = Struct.new(:room).new(has_room_window ? { 'room' => Object.new } : {})
    @state = Struct.new(:room_title).new(nil)
    @room_capture_mode = :title
    @room_pending_title = nil
    @room_pending_title_colors = nil
    @current_stream = nil
    @current_raw_line = nil
    @line_colors = []
  end

  # Mirror of GameTextProcessor#parse_room_subtitle (strips the " - " prefix and
  # the outer brackets), used here for the terminal-title assignment side of the
  # method. Kept identical so the spec exercises the real capture logic.
  def parse_room_subtitle(subtitle)
    text = subtitle.sub(/^\s*-\s*/, '')
    text.sub(/^\[(.+?)\]/, '\1').strip
  end
end

RSpec.describe RoomDataProcessor do
  describe '#process_room_data room title capture (:title mode)' do
    subject(:host) { RoomTitleHost.new }

    # Captures the bare (bracket-stripped) title RoomWindow#render will re-bracket.
    # @param text [String] the roomName styled text as sent by the game/Lich
    # @return [String, nil] the captured @room_pending_title
    def capture(text)
      host.room_capture_mode = :title
      host.process_room_data(text, [])
      host.room_pending_title
    end

    it 'strips the brackets and keeps the RealID when the game appends one' do
      expect(capture('[Bosque Deriel, Hermit\'s Shacks] (230008)'))
        .to eq('Bosque Deriel, Hermit\'s Shacks (230008)')
    end

    it 'strips a trailing bracket when the title carries a lich id but no RealID' do
      # BUG (fixed): the old ".sub(/\\]\\s*\\(/, ' (')" only removed the bracket
      # before a "(", so "[Room - 2071]" kept its "]" and render produced "]]".
      expect(capture('[Bosque Deriel, Hermit\'s Shacks - 2071]'))
        .to eq('Bosque Deriel, Hermit\'s Shacks - 2071')
    end

    it 'strips a trailing bracket for a plain title with no id at all' do
      expect(capture('[Town Square]')).to eq('Town Square')
    end

    it 'keeps both the lich id and the RealID (GS-parity title from Lich)' do
      expect(capture('[Bosque Deriel, Hermit\'s Shacks - 2071] (230008)'))
        .to eq('Bosque Deriel, Hermit\'s Shacks - 2071 (230008)')
    end

    it 'leaves no bracket that RoomWindow#render would double into "]]"' do
      %w([Room] [Room-2071] [Room](5)).each do |sample|
        expect(capture(sample)).not_to include(']')
      end
    end

    it 'preserves interior punctuation while stripping only the outer brackets' do
      expect(capture('[Warrens, Alcove - 1234]')).to eq('Warrens, Alcove - 1234')
    end

    it 'does not capture a pending title when the layout has no RoomWindow' do
      windowless = RoomTitleHost.new(has_room_window: false)
      windowless.room_capture_mode = :title
      windowless.process_room_data('[Town Square]', [])
      expect(windowless.room_pending_title).to be_nil
    end
  end
end
