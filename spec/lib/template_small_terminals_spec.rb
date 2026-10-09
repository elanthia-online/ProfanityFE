# frozen_string_literal: true

# Tests the shipped templates' layouts on terminals smaller than they were
# designed for, and pins them at their design sizes, where min(a, b) must
# leave every window where the fixed numbers put it.
#
# Each template is read by the real SettingsLoader and its layout built by
# WindowManager#load_layout on the virtual screen
# (spec/support/virtual_screen.rb). On a small terminal no window may run
# past the bottom or right edge, cover the command line, or share a cell
# with another window. The one exception is the right column of
# default.xml and mahtra.xml: its windows are placed and sized in thirds
# and sixths of the width, which round so that they end up to 4 columns
# past the right edge on most widths, the design size (200 columns)
# included; that is left as it is.
#
# Geometry values are written [begy, begx, maxy, maxx]: the window's top
# row and left column on the screen, then its height and width. A text
# window's width here includes its scrollbar column.

require 'rexml/document'
require_relative '../../lib/window_manager'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'

RSpec.describe 'Shipped templates on small terminals' do
  subject(:wm) { WindowManager.new }

  # Columns past the right edge the default.xml/mahtra.xml right column's
  # thirds and sixths reach (cols/6*6 + 4 - cols, at most 4).
  let(:max_proportional_overshoot) { 4 }

  def template(name) = File.expand_path("../../templates/#{name}.xml", __dir__)

  def terminal(lines, cols)
    allow(Curses).to receive_messages(lines: lines, cols: cols)
  end

  def load_template(name, lines, cols)
    terminal(lines, cols)
    expect(SettingsLoader.load(template(name), {}, {}, proc {})).to be_nil
    wm.load_layout('default')
    expect(BaseWindow.all_windows).not_to be_empty
  end

  # Every window on the screen: what it is, where (a text window with its
  # scrollbar column), and the layout expressions that put it there.
  def windows
    list = BaseWindow.all_windows.map do |window|
      { name: describe_window(window), rect: rect_of(window), layout: window.layout }
    end
    command = wm.command_window
    list << { name: 'command line', rect: rect_of(command), command: true } if command
    list
  end

  def describe_window(window)
    label = window.respond_to?(:label) ? window.label.to_s.strip[0, 12] : ''
    "#{window.class.name}(#{label}) left=#{window.layout.left} top=#{window.layout.top}"
  end

  def overlap?(one, other)
    t1, l1, h1, w1 = one
    t2, l2, h2, w2 = other
    t1 < t2 + h2 && t2 < t1 + h1 && l1 < l2 + w2 && l2 < l1 + w1
  end

  # Placed and sized in fractions of the width (the right column).
  def proportional?(window)
    window[:layout] && window[:layout].left.include?('cols') && window[:layout].width.include?('cols')
  end

  # Everything wrong with the layout on the current terminal.
  def problems
    lines = Curses.lines
    cols = Curses.cols
    found = []
    command = windows.find { |window| window[:command] }
    windows.each do |window|
      top, left, height, width = window[:rect]
      found << "#{window[:name]} runs past the bottom" if top + height > lines
      over = left + width - cols
      next unless over.positive?
      next if proportional?(window) && over <= max_proportional_overshoot

      found << "#{window[:name]} runs #{over} past the right edge"
    end
    others = windows.reject { |window| window[:command] }
    others.each { |window| found << "#{window[:name]} covers the command line" if command && overlap?(window[:rect], command[:rect]) }
    others.combination(2) do |one, other|
      found << "#{one[:name]} overlaps #{other[:name]}" if overlap?(one[:rect], other[:rect])
    end
    found
  end

  # Where +window+ is on the screen (a text window with its scrollbar).
  def rect_of(window)
    width = window.maxx + (window.respond_to?(:scrollbar) && window.scrollbar ? window.scrollbar.maxx : 0)
    [window.begy, window.begx, window.maxy, width]
  end

  # Sizes smaller than every template's design size: the classic 24x80,
  # GNU screen and tmux panes, and each template's last size short of the
  # one it fits unchanged (default/mahtra 58x158, tysong 53x234, original
  # 29 rows, eleazzar 190 columns).
  small_sizes = {
    'default' => [[24, 80], [25, 80], [30, 100], [40, 120], [50, 160], [57, 157], [57, 200], [63, 130]],
    'mahtra'  => [[24, 80], [30, 100], [40, 120], [57, 213]],
    'tysong'  => [[24, 80], [25, 80], [30, 100], [36, 120], [40, 120], [45, 160], [52, 233], [55, 200], [63, 213]]
  }

  small_sizes.each do |name, sizes|
    sizes.each do |lines, cols|
      it "#{name}.xml keeps every window on the screen, off the command line and apart at #{lines}x#{cols}" do
        load_template(name, lines, cols)
        expect(problems).to eq []
      end
    end
  end

  # The known cases: tysong's main window (37 rows from row 14) covered the
  # command line at 24x80, and the room window of default/mahtra (16 rows
  # from row 17) ran past row 23 over the bottom row's indicators.
  describe 'the known 80x24 cases' do
    it "ends tysong's main window just above the command line" do
      load_template('tysong', 24, 80)
      main = wm.stream['main']
      expect(rect_of(main)).to eq [14, 20, 9, 60]
      expect(main.begy + main.maxy).to eq wm.command_window.begy
    end

    %w[default mahtra].each do |name|
      it "ends #{name}.xml's room window above the status bar, clear of the spell indicator" do
        load_template(name, 24, 80)
        expect(rect_of(wm.room['room'])).to eq [17, 53, 5, 26]
        expect(rect_of(wm.indicator['spell'])).to eq [23, 70, 1, 10]
      end
    end
  end

  # Design sizes: min(a, b) must pick the fixed number everywhere. These
  # are the places the fixed numbers gave before min/max.
  describe 'at the design sizes' do
    it 'tysong.xml at 55x234 (its design size)' do
      load_template('tysong', 55, 234)
      expect(problems).to eq []
      expect(rect_of(wm.stream['main'])).to eq [14, 20, 37, 140]
      expect(rect_of(wm.stream['speech'])).to eq [21, 161, 30, 73]
      expect(rect_of(wm.stream['familiar'])).to eq [1, 0, 12, 80]
      expect(rect_of(wm.stream['lnet'])).to eq [1, 81, 12, 80]
      expect(rect_of(wm.stream['death'])).to eq [14, 0, 7, 19]
      expect(rect_of(wm.stream['logons'])).to eq [22, 0, 8, 19]
      expect(rect_of(wm.room['room'])).to eq [0, 161, 20, 72]
      expect(rect_of(wm.indicator['right'])).to eq [0, 62, 1, 50]
      expect(rect_of(wm.indicator['leftEye'])).to eq [32, 1, 1, 1]
      expect(rect_of(wm.indicator['leftLeg'])).to eq [36, 1, 2, 2]
      expect(rect_of(wm.countdown['roundtime'])).to eq [54, 0, 1, 11]
      expect(BaseWindow.all_windows.size).to eq 47 # every window but the command line
    end

    %w[default mahtra].each do |name|
      it "#{name}.xml at 60x200 and at 63x213 (the user's screen pane)" do
        load_template(name, 60, 200)
        expect(rect_of(wm.stream['death'])).to eq [0, 133, 17, 33]
        # The spell window leaves the last column of its layout width unused
        expect(rect_of(wm.stream['percWindow'])).to eq [0, 169, 17, 33 - PercWindow.right_margin]
        expect(rect_of(wm.room['room'])).to eq [17, 133, 16, 66]
        expect(rect_of(wm.stream['conversation'])).to eq [33, 133, 6, 66]
        expect(rect_of(wm.stream['familiar'])).to eq [39, 133, 17, 66]
        expect(rect_of(wm.command_window)).to eq [58, 1, 1, 104]
        expect(rect_of(wm.indicator['spell'])).to eq [59, 70, 1, 25]
        expect(rect_of(wm.stream['moonWindow'])).to eq [59, 125, 1, 33]

        terminal(63, 213)
        wm.resize(CommandBuffer.new)
        expect(rect_of(wm.room['room'])).to eq [17, 143, 16, 71]
        expect(rect_of(wm.stream['familiar'])).to eq [39, 143, 17, 71]
        expect(rect_of(wm.command_window)).to eq [61, 1, 1, 104]
      end
    end
  end

  # Boundaries: one row or column less than the fixed number needs.
  describe 'where the fixed numbers stop fitting' do
    it "shrinks default.xml's familiar window by one row at 57 rows and keeps it at 58" do
      load_template('default', 58, 200)
      expect(rect_of(wm.stream['familiar'])).to eq [39, 133, 17, 66]
      terminal(57, 200)
      wm.resize(CommandBuffer.new)
      expect(rect_of(wm.stream['familiar'])).to eq [39, 133, 16, 66]
    end

    it "keeps tysong.xml's logon window whole at 53 rows and shortens it at 52" do
      load_template('tysong', 53, 234)
      expect(rect_of(wm.stream['logons'])).to eq [22, 0, 8, 19]
      wm2 = WindowManager.new
      terminal(52, 234)
      wm2.load_layout('default')
      logons = wm2.stream['logons']
      expect([logons.begy, logons.maxy]).to eq [22, 7]
    end
  end

  # A window the small terminal had no room for appears where the layout
  # puts it once the terminal grows (WindowManager#resize builds it).
  it 'builds the windows a small terminal left out once the terminal grows to the design size' do
    load_template('tysong', 24, 80)
    expect(wm.indicator['leftEye']).to be_nil
    expect(wm.stream['speech']).to be_nil

    terminal(55, 234)
    wm.resize(CommandBuffer.new)

    expect(problems).to eq []
    expect(rect_of(wm.indicator['leftEye'])).to eq [32, 1, 1, 1]
    expect(rect_of(wm.stream['speech'])).to eq [21, 161, 30, 73]
    expect(rect_of(wm.stream['main'])).to eq [14, 20, 37, 140]
    expect(rect_of(wm.stream['logons'])).to eq [22, 0, 8, 19]
  end
end
