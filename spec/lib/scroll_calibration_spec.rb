# frozen_string_literal: true

# Tests .scrollcfg in the real client (Application#run) on the virtual
# screen: it learns each wheel direction from the first mouse event seen
# 20 times. Pointer motion and clicks arrive in the same stream while the
# user reaches for the wheel, and they are never the wheel, so once
# calibrated a click does not scroll.

require 'rexml/document'
require_relative '../../lib/shared_state'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../../lib/window_manager'
require_relative '../../lib/mouse_scroll'
require_relative '../../lib/autocomplete'
require_relative '../../lib/selection_manager'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/application'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../support/client_run'

RSpec.describe 'Calibrating the scroll wheel with .scrollcfg' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  # The window under the pointer; the calibration messages go to main
  let(:thoughts) { app.window_mgr.stream['thoughts'] }
  let(:saved_wheel_buttons) { [] }
  let(:mouse_events) { [] }
  let(:wheel_up) { 0x10000 }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    allow(ProfanityLog).to receive(:write)
    # No wheel buttons saved yet
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    allow(ProfanitySettings).to receive(:save_mouse_settings) { |up, down| saved_wheel_buttons << [up, down] }
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    allow(Curses).to receive(:getmouse) { mouse_events.shift }
    SelectionManager.clear_selection
    File.write(settings_path, <<~XML)
      <settings>
        <key id='enter' action='send_command'/>
        <layout id='default'>
          <window class='text' top='0' left='0' height='3' width='12' value='thoughts'/>
          <window class='text' top='3' left='0' height='3' width='60' value='main'/>
          <window class='command' top='7' left='0' height='1' width='60'/>
        </layout>
      </settings>
    XML
  end

  after { SelectionManager.clear_selection }

  # Keyboard steps: the thoughts window shows l2 to l4 of l1 to l5,
  # scrolled back one line, then the user types .scrollcfg.
  def start_calibration
    show_thoughts = lambda do
      %w[l1 l2 l3 l4 l5].each { |line| thoughts.add_string(line) }
      thoughts.scroll_lines(-1)
    end
    [show_thoughts, ".scrollcfg\n"]
  end

  # Keyboard steps: +times+ mouse events with this button state, over the
  # thoughts window.
  def mouse(bstate, times: 1)
    Array.new(times) do
      press_after(Curses::KEY_MOUSE) { mouse_events << Struct.new(:bstate, :y, :x).new(bstate, 1, 2) }
    end
  end

  def left_clicks(times)
    Array.new(times) { mouse(Curses::BUTTON1_PRESSED) + mouse(Curses::BUTTON1_RELEASED) }.flatten
  end

  # Every event of the middle (2) and right (3) buttons, +times+ over
  def middle_and_right_clicks(times)
    events = %w[2 3].flat_map do |button|
      %w[PRESSED RELEASED CLICKED DOUBLE_CLICKED TRIPLE_CLICKED].map { |event| Curses.const_get("BUTTON#{button}_#{event}") }
    end
    Array.new(times) { events.flat_map { |bstate| mouse(bstate) } }.flatten
  end

  it 'learns the wheel past pointer motion and left clicks, so a left click does not scroll' do
    stub_const('MouseScroll::WHEEL_DOWN_IS_MOTION', false)
    wheel_down = 0x200000
    thoughts_after_click = nil
    note_thoughts = -> { thoughts_after_click = thoughts.rows; nil }

    run_client(keyboard(*start_calibration,
                        *mouse(Curses::REPORT_MOUSE_POSITION, times: 20), *left_clicks(20), *mouse(wheel_up, times: 20),
                        *mouse(Curses::REPORT_MOUSE_POSITION, times: 20), *left_clicks(20), *mouse(wheel_down, times: 20),
                        *left_clicks(1), note_thoughts, *mouse(wheel_up)))

    expect(saved_wheel_buttons).to eq [[wheel_up, wheel_down]]
    expect(thoughts_after_click).to eq %w[l2 l3 l4]
    expect(thoughts.rows).to eq %w[l1 l2 l3]
  end

  it 'learns a wheel-down that ncurses reports as pointer motion' do
    stub_const('MouseScroll::WHEEL_DOWN_IS_MOTION', true)
    wheel_up = 0x80000

    run_client(keyboard(*start_calibration, *mouse(Curses::REPORT_MOUSE_POSITION, times: 20),
                        *mouse(wheel_up, times: 20), *mouse(Curses::REPORT_MOUSE_POSITION, times: 20)))

    expect(saved_wheel_buttons).to eq [[wheel_up, Curses::REPORT_MOUSE_POSITION]]
  end

  it 'learns the wheel past middle and right clicks, so they do not scroll' do
    stub_const('MouseScroll::WHEEL_DOWN_IS_MOTION', false)
    wheel_down = 0x200000

    run_client(keyboard(*start_calibration, *middle_and_right_clicks(20), *mouse(wheel_up, times: 20),
                        *middle_and_right_clicks(20), *mouse(wheel_down, times: 20), *middle_and_right_clicks(1)))

    expect(saved_wheel_buttons).to eq [[wheel_up, wheel_down]]
    expect(thoughts.rows).to eq %w[l2 l3 l4]
  end

  it 'learns the wheel past middle and right clicks when ncurses reports wheel-down as pointer motion' do
    stub_const('MouseScroll::WHEEL_DOWN_IS_MOTION', true)

    run_client(keyboard(*start_calibration, *middle_and_right_clicks(20), *mouse(wheel_up, times: 20),
                        *middle_and_right_clicks(20), *mouse(Curses::REPORT_MOUSE_POSITION, times: 20),
                        *middle_and_right_clicks(1)))

    expect(saved_wheel_buttons).to eq [[wheel_up, Curses::REPORT_MOUSE_POSITION]]
    expect(thoughts.rows).to eq %w[l2 l3 l4]
  end
end
