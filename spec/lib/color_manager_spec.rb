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
end
