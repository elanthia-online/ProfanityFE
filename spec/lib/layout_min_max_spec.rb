# frozen_string_literal: true

# Tests min(a, b) and max(a, b) in layout expressions end to end: a layout
# that sizes its windows with them, loaded through WindowManager#load_layout
# on the virtual screen (spec/support/virtual_screen.rb), placed for the
# terminal size at load, after a resize, and built once the terminal grows
# enough when a call made it zero rows or columns at load. "lines" and
# "cols" are substituted inside the calls' arguments.
#
# Geometry values are written [begy, begx, maxy, maxx]: the window's top
# row and left column on the screen, then its height and width.

require 'rexml/document'
require_relative '../../lib/window_manager'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'

RSpec.describe 'min and max in layout expressions' do
  subject(:wm) { WindowManager.new }

  let(:command) { CommandBuffer.new }

  # A main window with a room window on its right, 16 rows tall from row
  # 17 but never into the bottom row; a command line 104 columns wide but
  # never past the right edge; a status indicator at least 1 column wide.
  let(:layout_xml) do
    <<~XML
      <window class='text' top='0' left='0' height='lines-1' width='cols/2' value='main'/>
      <window class='room' top='17' left='cols/2' height='min(16, lines-1-17)' width='cols-cols/2'/>
      <window class='indicator' top='lines-1' left='0' height='1' width='max(1, min(10, cols-104))' value='spell' label='S'/>
      <window class='command' top='lines-1' left='max(1, min(10, cols-104))' height='1' width='min(104, cols-max(1, min(10, cols-104)))'/>
    XML
  end

  def terminal(lines, cols)
    allow(Curses).to receive_messages(lines: lines, cols: cols)
  end

  def load_at(lines, cols)
    terminal(lines, cols)
    LAYOUT['minmax'] = REXML::Document.new("<layout>#{layout_xml}</layout>").root
    wm.load_layout('minmax')
  end

  def resize_to(lines, cols)
    terminal(lines, cols)
    wm.resize(command)
  end

  def geometry(window)
    [window.begy, window.begx, window.maxy, window.maxx]
  end

  def room = wm.room['room']
  def spell = wm.indicator['spell']

  it 'uses the fixed size where the terminal has room for it' do
    load_at(60, 200)
    expect(geometry(room)).to eq [17, 100, 16, 100]
    expect(geometry(spell)).to eq [59, 0, 1, 10]
    expect(geometry(wm.command_window)).to eq [59, 10, 1, 104]
  end

  it 'shrinks the room window to end just above the bottom row on a short terminal' do
    load_at(24, 80)
    expect(geometry(room)).to eq [17, 40, 6, 40]
    expect(room.begy + room.maxy).to eq 23
  end

  # Boundary: lines-1-17 is 16 at 34 lines, so 34 and above give 16 rows
  # and 33 gives 15.
  it 'switches from the call to the fixed value exactly where they meet' do
    load_at(34, 80)
    expect(room.maxy).to eq 16
    resize_to(33, 80)
    expect(room.maxy).to eq 15
    resize_to(35, 80)
    expect(room.maxy).to eq 16
  end

  it 'keeps the command line inside a narrow terminal and the indicator at least 1 column wide' do
    load_at(24, 80)
    expect(geometry(spell)).to eq [23, 0, 1, 1]
    expect(geometry(wm.command_window)).to eq [23, 1, 1, 79]
  end

  it 'follows the terminal on a resize, both ways' do
    load_at(24, 80)
    resize_to(60, 200)
    expect(geometry(room)).to eq [17, 100, 16, 100]
    expect(geometry(wm.command_window)).to eq [59, 10, 1, 104]
    resize_to(30, 110)
    expect(geometry(room)).to eq [17, 55, 12, 55]
    expect(geometry(spell)).to eq [29, 0, 1, 6]
    expect(geometry(wm.command_window)).to eq [29, 6, 1, 104]
  end

  # At 18 lines, min(16, 18-1-17) is 0: no rows, so the room window isn't
  # built; at 19 lines it gets 1 row and is built by the resize.
  it 'does not build a window a call gives no rows, and builds it once the terminal grows' do
    load_at(18, 80)
    expect(room).to be_nil
    resize_to(19, 80)
    expect(geometry(room)).to eq [17, 40, 1, 40]
  end

  # A negative result is no rows too (17 lines: 17-1-17 is -1).
  it 'does not build a window a call gives a negative size' do
    load_at(17, 80)
    expect(room).to be_nil
  end

  it 'evaluates min and max after substituting the terminal size' do
    terminal(24, 80)
    expect(WindowLayout.evaluate('min(16, lines-19)')).to eq 5
    expect(WindowLayout.evaluate('max(cols/3, lines)')).to eq 26
    expect(WindowLayout.evaluate('max(1, min(cols-104, 10))')).to eq 1
    terminal(63, 213)
    expect(WindowLayout.evaluate('min(16, lines-19)')).to eq 16
    expect(WindowLayout.evaluate('max(1, min(cols-104, 10))')).to eq 10
  end

  it 'gives 0 and warns for a malformed call in a layout' do
    terminal(24, 80)
    expect { expect(WindowLayout.evaluate('min(lines)')).to eq 0 }
      .to output(/min takes 2 arguments, not 1 in 'min\(24\)'/).to_stderr
  end
end
