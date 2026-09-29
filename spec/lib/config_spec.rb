# frozen_string_literal: true

# Tests the mutable Config container: default values, reset! behavior,
# instance independence, and reset! waiting for the settings lock.

require 'timeout'
require_relative '../../lib/config'

RSpec.describe Config do
  subject(:config) { described_class.new }

  describe '#initialize' do
    it 'starts with empty highlight hash' do
      expect(config.highlight).to eq({})
    end

    it 'starts with empty preset hash' do
      expect(config.preset).to eq({})
    end

    it 'starts with empty layout hash' do
      expect(config.layout).to eq({})
    end

    it 'starts with empty scroll_window array' do
      expect(config.scroll_window).to eq([])
    end

    it 'starts with empty perc_transforms array' do
      expect(config.perc_transforms).to eq([])
    end

    it 'creates a Mutex lock' do
      expect(config.lock).to be_a(Mutex)
    end

    it 'each instance gets its own independent state' do
      config2 = described_class.new
      config.preset['test'] = ['ff0000', nil]
      expect(config2.preset).to eq({})
    end
  end

  describe '#reset!' do
    before do
      config.highlight[/test/] = ['ff0000', nil, nil]
      config.preset['monsterbold'] = ['ff0000', nil]
      config.layout['default'] = 'xml'
      config.scroll_window << 'window1'
      config.perc_transforms << [/test/, '']
    end

    it 'clears all mutable state' do
      config.reset!
      expect(config.highlight).to be_empty
      expect(config.preset).to be_empty
      expect(config.layout).to be_empty
      expect(config.scroll_window).to be_empty
      expect(config.perc_transforms).to be_empty
    end

    # constants.rb aliases HIGHLIGHT, PRESET, LAYOUT, SCROLL_WINDOW and
    # PERC_TRANSFORMS to these objects, so reset! must empty them in place.
    it 'empties the same Hash and Array objects instead of replacing them' do
      before_reset = [config.highlight, config.preset, config.layout, config.scroll_window, config.perc_transforms]
      config.reset!
      after_reset = [config.highlight, config.preset, config.layout, config.scroll_window, config.perc_transforms]
      expect(after_reset.map(&:object_id)).to eq before_reset.map(&:object_id)
    end

    it 'is idempotent' do
      config.reset!
      config.reset!
      expect(config.highlight).to be_empty
    end
  end

  describe '#notification_stream' do
    it 'defaults to familiar' do
      expect(config.notification_stream).to eq 'familiar'
    end

    it 'is restored by reset!' do
      config.notification_stream = 'ooc'
      config.reset!
      expect(config.notification_stream).to eq 'familiar'
    end
  end

  describe '#history_size' do
    it 'defaults to 1000' do
      expect(config.history_size).to eq 1000
    end

    it 'is restored by reset!' do
      config.history_size = 5
      config.reset!
      expect(config.history_size).to eq 1000
    end
  end

  describe 'constant aliasing compatibility' do
    it 'mutating the hash via one reference is visible via the other' do
      # Simulate the aliasing pattern from constants.rb
      highlight_alias = config.highlight
      config.highlight[/goblin/] = ['ff0000', nil, nil]
      expect(highlight_alias[/goblin/]).to eq ['ff0000', nil, nil]
    end

    it 'reset! clears aliased references too' do
      preset_alias = config.preset
      config.preset['test'] = ['aabbcc', nil]
      config.reset!
      expect(preset_alias).to be_empty
    end

    # SETTINGS_LOCK (constants.rb) is config.lock; HighlightProcessor holds
    # it while it walks HIGHLIGHT, so reset! must not clear the patterns
    # under it.
    it 'makes reset! wait while another thread holds the lock' do
      config.highlight[/goblin/] = ['ff0000', nil, nil]
      lock_held = Queue.new
      release_lock = Queue.new
      reader = Thread.new { config.lock.synchronize { lock_held << true; release_lock.pop } }
      lock_held.pop

      resetter = Thread.new { config.reset! }
      Timeout.timeout(5) { Thread.pass while resetter.status == 'run' }
      patterns_while_locked = config.highlight.keys
      release_lock << true
      [reader, resetter].each(&:join)

      expect(patterns_while_locked).to eq [/goblin/]
      expect(config.highlight).to be_empty
    end
  end
end
