# frozen_string_literal: true

# Tests the mutable Config container: default values, reset! behavior,
# instance independence, and thread safety of concurrent mutations.

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

    it 'starts with empty room_objects array' do
      expect(config.room_objects).to eq([])
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
      config.room_objects << 'goblin'
      config.perc_transforms << [/test/, '']
    end

    it 'clears all mutable state' do
      config.reset!
      expect(config.highlight).to be_empty
      expect(config.preset).to be_empty
      expect(config.layout).to be_empty
      expect(config.scroll_window).to be_empty
      expect(config.room_objects).to be_empty
      expect(config.perc_transforms).to be_empty
    end

    it 'preserves object identity (same Hash/Array objects)' do
      highlight_id = config.highlight.object_id
      preset_id = config.preset.object_id
      config.reset!
      expect(config.highlight.object_id).to eq highlight_id
      expect(config.preset.object_id).to eq preset_id
    end

    it 'is idempotent' do
      config.reset!
      config.reset!
      expect(config.highlight).to be_empty
    end

    it 'is thread-safe (sequential verification)' do
      config.preset['test'] = ['aabbcc', nil]
      config.reset!
      expect(config.preset).to be_empty
    end
  end

  describe '#notification_stream' do
    it 'defaults to familiar' do
      expect(config.notification_stream).to eq 'familiar'
    end

    it 'is restored by reset! and reset_dynamic!' do
      config.notification_stream = 'ooc'
      config.reset_dynamic!
      expect(config.notification_stream).to eq 'familiar'
      config.notification_stream = 'ooc'
      config.reset!
      expect(config.notification_stream).to eq 'familiar'
    end
  end

  describe '#reset_dynamic!' do
    before do
      config.highlight[/test/] = ['ff0000', nil, nil]
      config.preset['speech'] = ['00ff00', nil]
      config.layout['default'] = 'xml'
      config.perc_transforms << [/test/, '']
      config.scroll_window << 'window1'
      config.room_objects << 'goblin'
    end

    it 'clears highlight and perc_transforms' do
      config.reset_dynamic!
      expect(config.highlight).to be_empty
      expect(config.perc_transforms).to be_empty
    end

    it 'preserves preset, layout, scroll_window, room_objects' do
      config.reset_dynamic!
      expect(config.preset).not_to be_empty
      expect(config.layout).not_to be_empty
      expect(config.scroll_window).not_to be_empty
      expect(config.room_objects).not_to be_empty
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

    it 'lock alias works for synchronization' do
      lock_alias = config.lock
      result = lock_alias.synchronize { 42 }
      expect(result).to eq 42
    end
  end

  # ---- Adversarial ----

  describe 'adversarial edge cases' do
    it 'reset! works while lock is used for reads' do
      config.lock.synchronize do
        config.highlight[/test/] = ['ff0000']
      end
      config.reset!
      expect(config.highlight).to be_empty
    end

    it 'scroll_window maintains Array behavior after reset' do
      config.scroll_window << 'a'
      config.scroll_window.push(config.scroll_window.shift)
      config.reset!
      config.scroll_window << 'b'
      expect(config.scroll_window).to eq ['b']
    end

    it 'room_objects.replace works after reset' do
      config.reset!
      config.room_objects.replace(['goblin', 'troll'])
      expect(config.room_objects).to eq ['goblin', 'troll']
    end

    it 'perc_transforms accepts [Regexp, String] pairs' do
      config.perc_transforms << [/ \(roisaen\)/, '']
      config.perc_transforms << [/ \(roisan\)/, '']
      expect(config.perc_transforms.length).to eq 2
    end
  end
end
