# frozen_string_literal: true

# lib/color_manager.rb redefines the global get_color_pair_id (the one
# spec_helper stubs to return 0) so it delegates to ColorManager. Restore
# whatever was there before, so loading this file does not leak real color
# allocation into other specs.
original_get_color_pair_id = Object.private_method_defined?(:get_color_pair_id) &&
                             Object.instance_method(:get_color_pair_id)
Object.send(:remove_method, :get_color_pair_id) if original_get_color_pair_id # avoid redefinition warnings
require_relative '../../lib/color_manager'
if original_get_color_pair_id
  Object.send(:remove_method, :get_color_pair_id)
  Object.send(:define_method, :get_color_pair_id, original_get_color_pair_id)
  Object.send(:private, :get_color_pair_id)
end

RSpec.describe ColorManager do
  let(:color_pairs) { 32_767 } # what ncurses reports for TERM=xterm-256color
  let(:init_pair_calls) { [] }

  # Distinct fg codes from the fixed 256-color palette (247 unique entries).
  let(:palette) { ColorManager.instance_variable_get(:@color_code).uniq }

  before do
    allow(Curses).to receive_messages(colors: 256, color_pairs: color_pairs, color_content: [0, 0, 0])
    allow(Curses).to receive(:init_pair) { |*args| init_pair_calls << args }
    allow(Curses).to receive(:init_color)
    allow(ColorManager).to receive(:sleep)
    ColorManager.configure(default_color_id: 7, default_background_color_id: 0, custom_colors: false)
  end

  # Allocate +count+ distinct fg/bg combinations; returns the pair IDs.
  def allocate_distinct(count)
    palette.product(%w[000000 0000ff]).first(count).map { |fg, bg| ColorManager.get_color_pair_id(fg, bg) }
  end

  describe 'color pair pool' do
    it 'never hands out a pair number above 255 when Curses.color_pairs is large' do
      ids = allocate_distinct(400)

      expect(ids.max).to be <= 255
      expect(ids.min).to be >= 1
      expect(init_pair_calls.map(&:first).max).to be <= 255
    end

    it 'uses all 255 renderable pairs before recycling any' do
      ids = allocate_distinct(255)

      expect(ids.uniq.size).to eq(255)
      expect(ids.sort).to eq((1..255).to_a)
    end

    it 'honours a terminal that reports fewer than 256 pairs' do
      allow(Curses).to receive(:color_pairs).and_return(64)
      ColorManager.configure(default_color_id: 7, default_background_color_id: 0, custom_colors: false)

      ids = allocate_distinct(100)

      expect(ids.max).to eq(63)
    end

    it 'recycles the oldest pair FIFO once the pool is exhausted' do
      ids = allocate_distinct(257)

      expect(ids[255]).to eq(ids[0])
      expect(ids[256]).to eq(ids[1])
      expect(init_pair_calls.last.first).to eq(ids[1])
    end

    it 'evicts the recycled pair from its previous fg/bg combination' do
      first_fg, first_bg = palette.product(%w[000000 0000ff]).first
      first_id = ColorManager.get_color_pair_id(first_fg, first_bg)
      allocate_distinct(256) # re-requests the first combo (cached), then 255 more

      recycled_id = ColorManager.get_color_pair_id(first_fg, first_bg)

      expect(recycled_id).not_to eq(first_id) # pair 1 was handed to combo #256
      expect(init_pair_calls.last).to eq([recycled_id, ColorManager.get_color_id(first_fg),
                                          ColorManager.get_color_id(first_bg)])
    end

    it 'returns the cached pair for a repeated combination without re-initializing it' do
      id = ColorManager.get_color_pair_id('ff0000', '000000')
      calls = init_pair_calls.size

      expect(ColorManager.get_color_pair_id('ff0000', '000000')).to eq(id)
      expect(init_pair_calls.size).to eq(calls)
    end
  end

  describe 'recycle log' do
    let(:color_pairs) { 4 } # pool of pairs 1..3

    let(:logged) { [] }

    before { allow(ProfanityLog).to receive(:write) { |context, message| logged << [context, message] } }

    def pair_log_lines
      log_lines.select { |line| line.start_with?('color pairs') }
    end

    def slot_log_lines
      log_lines.select { |line| line.start_with?('custom color slots') }
    end

    def log_lines
      logged.select { |context, _| context == 'color' }.map { |_, message| message }
    end

    it 'logs nothing while the pair pool has free pairs' do
      allocate_distinct(3)

      expect(ProfanityLog).not_to have_received(:write)
    end

    it 'logs one line naming the pool size, the reused pair and the new colors at the first recycle' do
      ColorManager.get_color_pair_id('ff0000', '000000') # pair 1
      ColorManager.get_color_pair_id('00ff00', '000000') # pair 2
      ColorManager.get_color_pair_id('0000ff', '000000') # pair 3
      ColorManager.get_color_pair_id('ff0000', '000000') # cached, not a recycle
      ColorManager.get_color_pair_id('ffffff', nil)      # takes pair 1 from ff0000/000000

      expect(pair_log_lines).to eq(['color pairs exhausted (3 in use): reusing pair 1 for ffffff/default; ' \
                                    'colors already on screen may change'])
    end

    it 'logs only the first recycle' do
      allocate_distinct(10)

      expect(pair_log_lines.size).to eq(1)
      expect(slot_log_lines).to be_empty
    end

    it 'does not change the pair ids handed out or the pairs initialized' do
      ids = allocate_distinct(7)

      expect(ids).to eq([1, 2, 3, 1, 2, 3, 1])
      expect(init_pair_calls.map(&:first)).to eq([1, 2, 3, 1, 2, 3, 1])
    end

    it 'logs again after configure rebuilds the pool' do
      allocate_distinct(4)
      ColorManager.configure(default_color_id: 7, default_background_color_id: 0, custom_colors: false)
      allocate_distinct(4)

      expect(pair_log_lines.size).to eq(2)
    end

    it 'does not reset on reinitialize_colors (.fixcolor)' do
      allocate_distinct(4)
      ColorManager.reinitialize_colors
      allocate_distinct(10)

      expect(pair_log_lines.size).to eq(1)
    end

    context 'with custom colors' do
      let(:color_pairs) { 32_767 } # 255 pairs: only the color slots run out here
      let(:init_color_calls) { [] }

      before do
        allow(Curses).to receive(:colors).and_return(4)
        allow(Curses).to receive(:init_color) { |*args| init_color_calls << args }
        # Slots 3 (fg) and 0 (bg) are the defaults, so the pool is slots 1 and 2.
        ColorManager.configure(default_color_id: 3, default_background_color_id: 0, custom_colors: true)
      end

      it 'logs nothing while the slot pool has free slots' do
        ColorManager.get_color_id('ff0000')
        ColorManager.get_color_id('00ff00')
        ColorManager.get_color_id('ff0000')

        expect(ProfanityLog).not_to have_received(:write)
      end

      it 'logs one line at the first slot recycle, and no pair line' do
        ColorManager.get_color_id('ff0000') # slot 1
        ColorManager.get_color_id('00ff00') # slot 2
        ColorManager.get_color_id('0000ff') # takes slot 1 from ff0000
        ColorManager.get_color_id('ffffff') # takes slot 2 from 00ff00
        ColorManager.get_color_id('ff0000') # takes slot 1 from 0000ff

        expect(slot_log_lines).to eq(['custom color slots exhausted (2 in use): reusing color 1 for 0000ff; ' \
                                      'colors already on screen may change'])
        expect(pair_log_lines).to be_empty
      end

      it 'does not change the slots handed out or the colors initialized' do
        ids = %w[ff0000 00ff00 0000ff ffffff ff0000].map { |code| ColorManager.get_color_id(code) }

        expect(ids).to eq([1, 2, 1, 2, 1])
        expect(init_color_calls.map(&:first)).to eq([1, 2, 1, 2, 1])
      end
    end
  end

  describe 'default color codes' do
    before do
      allow(Curses).to receive(:color_content).with(1).and_return([1000, 0, 0])
      allow(Curses).to receive(:color_content).with(4).and_return([0, 0, 933])
    end

    def configure_custom
      ColorManager.configure(default_color_id: 1, default_background_color_id: 4, custom_colors: true)
    end

    it 'zero-pads each RGB channel when converting curses RGB to hex' do
      configure_custom

      expect(ColorManager.default_color_code).to eq('ff0000')
      expect(ColorManager.default_background_color_code).to eq('0000ee')
    end

    it 'keys the default colors under their true hex in custom mode' do
      configure_custom

      expect(ColorManager.get_color_id('ff0000')).to eq(1)
      expect(ColorManager.get_color_id('0000ee')).to eq(4)
      expect(Curses).not_to have_received(:init_color)
    end

    it 'does not claim an unrelated color is a default' do
      configure_custom

      expect(ColorManager.get_color_id('00ff00')).not_to eq(1)
      expect(Curses).to have_received(:init_color).with(anything, 0, 1000, 0)
    end
  end

  describe 'malformed color codes' do
    [false, true].each do |custom|
      context "with custom_colors: #{custom}" do
        before do
          ColorManager.configure(default_color_id: 7, default_background_color_id: 0, custom_colors: custom)
        end

        let(:default_pair) { ColorManager.get_color_pair_id(nil, nil) }

        ['', 'f00', 'ff00000', 'zzzzzz', '#f00', '##ff0000'].each do |bad|
          it "falls back to the default color for #{bad.inspect} instead of raising" do
            expect(ColorManager.get_color_pair_id(bad, bad)).to eq(default_pair)
          end
        end

        it 'treats "#ff0000" as "ff0000"' do
          expect(ColorManager.get_color_pair_id('#ff0000', '#0000ff'))
            .to eq(ColorManager.get_color_pair_id('ff0000', '0000ff'))
        end

        it 'treats upper-case "FF0000" as "ff0000"' do
          expect(ColorManager.get_color_pair_id('FF0000', '#0000FF'))
            .to eq(ColorManager.get_color_pair_id('ff0000', '0000ff'))
        end
      end
    end

    it 'resolves "#ff0000" to palette red in fixed mode' do
      ColorManager.get_color_pair_id('#ff0000', nil)

      expect(init_pair_calls.last).to eq([1, 9, 0])
    end
  end
end
