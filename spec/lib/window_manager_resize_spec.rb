# frozen_string_literal: true

# Tests WindowManager#resize: verifies that the screen is fully cleared
# before windows are repositioned, and that each window type is resized,
# moved, and redrawn correctly.
#
# The critical behavior under test is that Curses.clear + Curses.refresh
# are called before any window repositioning. Without this, windows that
# move to new positions (particularly RoomWindow) leave stale content at
# their old screen locations, causing visual offset artifacts.

require_relative '../../lib/event_bus'
require_relative '../../lib/window_manager'

# Spy that records resize/move/redraw calls for verification.
class SpyResizeWindow < BaseWindow
  attr_reader :calls
  attr_accessor :scrollbar

  def initialize(h = 10, w = 40, t = 0, l = 0)
    super(h, w, t, l)
    @calls = []
  end

  %i[resize move scroll noutrefresh redraw clear_scrollbar update_scrollbar].each do |meth|
    define_method(meth) do |*args|
      @calls << [meth, args]
      nil
    end
  end
end

# Tracks the order of Curses class-method calls across the resize flow.
# Injected via allow() so we can assert clear/refresh ordering relative
# to window operations.
module ResizeCallTracker
  @calls = []

  def self.calls = @calls
  def self.reset! = @calls.clear

  def self.record(method)
    @calls << method
  end
end

RSpec.describe WindowManager, '#resize' do
  let(:event_bus) { EventBus.new }
  let(:wm) { described_class.new }

  before do
    ResizeCallTracker.reset!

    allow(Curses).to receive(:clear) { ResizeCallTracker.record(:curses_clear) }
    allow(Curses).to receive(:refresh) { ResizeCallTracker.record(:curses_refresh) }
    allow(Curses).to receive(:doupdate) { ResizeCallTracker.record(:curses_doupdate) }
  end

  after do
    TextWindow.list.clear
    TabbedTextWindow.list.clear
    RoomWindow.list.clear
    ExpWindow.list.clear
    PercWindow.list.clear
    IndicatorWindow.list.clear
    ProgressWindow.list.clear
    CountdownWindow.list.clear
  end

  describe 'screen clearing' do
    it 'calls Curses.clear and Curses.refresh before repositioning windows' do
      room = SpyResizeWindow.new(10, 40, 5, 5)
      room.layout = ['10', '40', '5', '5']
      RoomWindow.list << room

      wm.resize(nil)

      clear_idx = ResizeCallTracker.calls.index(:curses_clear)
      refresh_idx = ResizeCallTracker.calls.index(:curses_refresh)
      doupdate_idx = ResizeCallTracker.calls.index(:curses_doupdate)

      expect(clear_idx).not_to be_nil
      expect(refresh_idx).not_to be_nil
      expect(clear_idx).to be < refresh_idx
      expect(refresh_idx).to be < doupdate_idx
    end

    it 'clears the screen even when no windows exist' do
      wm.resize(nil)

      expect(ResizeCallTracker.calls).to include(:curses_clear)
      expect(ResizeCallTracker.calls).to include(:curses_refresh)
    end
  end

  describe 'RoomWindow handling' do
    it 'calls redraw on each RoomWindow after repositioning' do
      room = SpyResizeWindow.new(10, 40, 5, 5)
      room.layout = ['10', '40', '5', '5']
      RoomWindow.list << room

      wm.resize(nil)

      expect(room.calls.map(&:first)).to include(:resize, :move, :redraw, :noutrefresh)
    end

    it 'repositions RoomWindow using evaluated layout expressions' do
      room = SpyResizeWindow.new(16, 26, 17, 53)
      room.layout = ['16', 'cols/3', '17', '((cols/3)*2)+1']
      RoomWindow.list << room

      wm.resize(nil)

      resize_call = room.calls.find { |m, _| m == :resize }
      move_call = room.calls.find { |m, _| m == :move }

      # cols=80: cols/3=26, ((cols/3)*2)+1=53
      expect(resize_call[1]).to eq [16, 26]
      expect(move_call[1]).to eq [17, 53]
    end
  end

  describe 'TextWindow handling' do
    it 'subtracts 1 from width for the scrollbar column' do
      scrollbar = SpyResizeWindow.new(10, 1, 0, 39)
      text = SpyResizeWindow.new(10, 39, 0, 0)
      text.scrollbar = scrollbar
      text.layout = ['10', '40', '0', '0']
      TextWindow.list << text

      wm.resize(nil)

      resize_call = text.calls.find { |m, _| m == :resize }
      # width should be 40 - 1 = 39
      expect(resize_call[1]).to eq [10, 39]
    end
  end

  describe 'small terminal guard' do
    it 'skips window repositioning when terminal is too small' do
      allow(Curses).to receive(:lines).and_return(2)

      room = SpyResizeWindow.new(10, 40, 5, 5)
      room.layout = ['10', '40', '5', '5']
      RoomWindow.list << room

      wm.resize(nil)

      expect(room.calls).to be_empty
    end

    it 'still clears the screen even when terminal is too small' do
      allow(Curses).to receive(:lines).and_return(2)

      wm.resize(nil)

      expect(ResizeCallTracker.calls).to include(:curses_clear)
      expect(ResizeCallTracker.calls).to include(:curses_refresh)
    end
  end

  describe 'command window handling' do
    it 'resizes and moves the command window' do
      cmd_win = Curses::Window.new(1, 80, 23, 0)
      wm.instance_variable_set(:@command_window, cmd_win)
      wm.instance_variable_set(:@command_window_layout, ['1', 'cols', 'lines-1', '0'])

      wm.resize(nil)

      resize_call = cmd_win.call_log.find { |m, _| m == :resize }
      move_call = cmd_win.call_log.find { |m, _| m == :move }

      # lines=24, cols=80: lines-1=23, cols=80
      expect(resize_call[1]).to eq [1, 80]
      expect(move_call[1]).to eq [23, 0]
    end
  end
end
