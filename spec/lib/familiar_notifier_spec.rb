# frozen_string_literal: true

# Tests FamiliarNotifier event extraction (auction, empath, almanac, scroll,
# focus, lockbox, tarantula, script STATUS) and check_familiar_notification
# event emission with monsterbold colors.

require_relative '../../lib/event_bus'
require_relative '../../lib/familiar_notifier'

# Minimal host class that includes FamiliarNotifier
class FamiliarNotifierHost
  include FamiliarNotifier

  attr_accessor :line_colors, :need_update
  attr_reader :event_bus

  def initialize(event_bus:)
    @event_bus = event_bus
    @line_colors = []
    @need_update = false
  end
end

RSpec.describe FamiliarNotifier do
  let(:event_bus) { EventBus.new }
  let(:host) { FamiliarNotifierHost.new(event_bus: event_bus) }

  # Helper to capture stream_text events
  def collect_stream_events
    events = []
    event_bus.on(:stream_text) { |data| events << data }
    events
  end

  describe '#extract_notification (private)' do
    subject(:extract) { host.send(:extract_notification, text) }

    # ---- Positive matches ----

    context 'with auction announcement' do
      let(:text) { 'Auctioneer Endlar bangs his gavel and yells, "Bidding is now open for lot 5!"' }
      it { is_expected.to eq text }
    end

    context 'with empath healthy assessment' do
      let(:text) { 'You sense nothing wrong with Mahtra' }
      it { is_expected.to eq 'Mahtra is all healthy.' }
    end

    context 'with almanac discovery' do
      let(:text) { "You believe you've learned something significant about Foraging!" }
      it { is_expected.to eq 'Almanac: Foraging' }
    end

    context 'with two-word almanac topic' do
      let(:text) { "You believe you've learned something significant about First Aid!" }
      it { is_expected.to eq 'Almanac: First Aid' }
    end

    context 'with scroll spell' do
      let(:text) { 'contains a complete description of the Fire Ball spell' }
      it { is_expected.to eq 'Scroll spell: Fire Ball' }
    end

    context 'with focus effect start' do
      let(:text) { 'You raise the bead up, and a black glow surrounds it' }
      it { is_expected.to eq 'Focus effect started.' }
    end

    context 'with focus effect end' do
      let(:text) { 'The glow slowly fades away from around you' }
      it { is_expected.to eq 'Focus effect ended.' }
    end

    context 'with lockbox loot summary' do
      let(:text) { 'Spent 5000 silvers looting 10 boxes.' }
      it { is_expected.to eq 'Spent 5000 silvers looting 10 boxes.' }
    end

    context 'with waiting list' do
      let(:text) { 'Mahtra just opened the waiting list.' }
      it { is_expected.to eq text }
    end

    context 'with hand-holding' do
      let(:text) { 'Cleric reaches over and holds your hand' }
      it { is_expected.to eq text }
    end

    context 'with pull-away' do
      let(:text) { 'Mahtra just tried to take your hand, but you politely pulled away' }
      it { is_expected.to eq text }
    end

    context 'with next on list' do
      let(:text) { 'Grocha is next on the healer list' }
      it { is_expected.to eq text }
    end

    context 'with tarantula sacrifice' do
      let(:text) { 'Tarantula successfully sacrificed 15/34 of Mahtra at the altar' }
      it { is_expected.to eq 'Tarantula: Mahtra 15/34' }
    end

    # ---- Negative matches (should NOT produce notifications) ----

    context 'with normal game text' do
      let(:text) { 'A goblin attacks you!' }
      it { is_expected.to be_nil }
    end

    context 'with empty text' do
      let(:text) { '' }
      it { is_expected.to be_nil }
    end

    context 'with whitespace-only text' do
      let(:text) { '   ' }
      it { is_expected.to be_nil }
    end

    context 'with partial auction text' do
      let(:text) { 'Auctioneer Endlar waves hello' }
      it { is_expected.to be_nil }
    end

    context 'with "sense" in non-empath context' do
      let(:text) { 'You sense a disturbance in the force' }
      it { is_expected.to be_nil }
    end

    # ---- Adversarial ----

    context 'with script STATUS that starts with digits (should be suppressed)' do
      let(:text) { '[script: ***STATUS*** 500 seconds remaining' }
      # The pattern has (?!\d+) negative lookahead after STATUS
      it { is_expected.to be_nil }
    end

    context 'with script STATUS that starts with non-digits' do
      let(:text) { '[custom/script: ***STATUS*** running smoothly' }
      it { is_expected.not_to be_nil }
    end

    context 'with hyphenated script name' do
      let(:text) { '[combat-trainer: ***STATUS*** Killing a rat]' }
      it { is_expected.to eq 'combat-trainer: Killing a rat' }
    end

    context 'with hyphenated custom/ script name' do
      let(:text) { '[custom/my-script: ***STATUS*** waiting]' }
      it { is_expected.to eq 'my-script: waiting' }
    end

    context 'with very long text' do
      let(:text) { 'You sense nothing wrong with ' + 'A' * 1000 }
      it { is_expected.to include('is all healthy.') }
    end
  end

  describe '#check_familiar_notification' do
    it 'emits stream_text event for familiar stream' do
      events = collect_stream_events
      host.check_familiar_notification('You sense nothing wrong with Mahtra')
      expect(events.last[:stream]).to eq 'familiar'
      expect(events.last[:text]).to eq 'Mahtra is all healthy.'
    end

    it 'routes notifications to the configured notification stream' do
      CONFIG.notification_stream = 'ooc'
      events = collect_stream_events
      host.check_familiar_notification('[combat-trainer: ***STATUS*** Killing a rat]')
      host.check_familiar_notification("You believe you've learned something significant about Foraging!")
      expect(events.map { |e| e[:stream] }).to eq %w[ooc ooc]
    end

    it 'routes notifications to familiar by default' do
      events = collect_stream_events
      host.check_familiar_notification('[hunter: ***STATUS*** waiting]')
      expect(events.last[:stream]).to eq 'familiar'
    end

    it 'sets need_update when notification sent' do
      host.check_familiar_notification('You sense nothing wrong with Mahtra')
      expect(host.need_update).to be true
    end

    it 'does not emit for non-matching text' do
      events = collect_stream_events
      host.check_familiar_notification('Hello world')
      expect(events).to be_empty
    end

    it 'does not set need_update for non-matching text' do
      host.check_familiar_notification('Hello world')
      expect(host.need_update).to be false
    end

    it 'applies monsterbold preset colors when available' do
      PRESET['monsterbold'] = ['ff0000', '000000']
      events = collect_stream_events
      host.check_familiar_notification('You sense nothing wrong with Mahtra')
      colors = events.last[:colors]
      expect(colors.first[:fg]).to eq 'ff0000'
      expect(colors.first[:bg]).to eq '000000'
      expect(colors.first[:start]).to eq 0
    end

    it 'emits without colors when monsterbold preset is not defined' do
      PRESET.delete('monsterbold')
      events = collect_stream_events
      host.check_familiar_notification('You sense nothing wrong with Mahtra')
      expect(events.last[:text]).to eq 'Mahtra is all healthy.'
      expect(events.last[:colors]).to be_empty
    end

    it 'does not crash when no subscribers are listening' do
      # No subscriber on the event bus — emit should be a no-op
      expect { host.check_familiar_notification('You sense nothing wrong with Mahtra') }.not_to raise_error
    end

    it 'resets line_colors for each notification' do
      host.line_colors = [{ start: 0, end: 5, fg: 'old' }]
      host.check_familiar_notification('You sense nothing wrong with Mahtra')
      # line_colors should have been cleared
      expect(host.line_colors).not_to include(a_hash_including(fg: 'old'))
    end
  end
end
