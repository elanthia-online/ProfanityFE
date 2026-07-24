# frozen_string_literal: true

# Tests MouseScroll click-resolution handling around .select / .draghl
# toggles. Focused on the mouseinterval save/restore path: the curses gem's
# Curses.mouseinterval returns a boolean (whether the interval was set), NOT
# the previous interval, and it raises TypeError if handed a non-Integer.
# The stub below models that faithfully so the toggle-off path is exercised
# against real gem semantics rather than a lenient Integer-returning stub.

require_relative '../../spec/spec_helper'
require_relative '../../lib/mouse_scroll'

RSpec.describe MouseScroll do
  let(:key_action) { {} }
  let(:display_fn) { ->(_msg) {} }

  # Records every argument passed to Curses.mouseinterval and mimics the real
  # curses 1.6.0 binding: NUM2INT(arg) raises on a non-Integer, and the return
  # is a boolean, never the previous interval.
  let(:mouseinterval_args) { [] }

  before do
    allow(ProfanitySettings).to receive(:load_setting).and_return(true)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    allow(ProfanitySettings).to receive(:save_setting)

    allow(Curses).to receive(:mousemask)
    allow(Curses).to receive(:mouseinterval) do |arg|
      unless arg.is_a?(Integer)
        raise TypeError, "no implicit conversion of #{arg.class} into Integer"
      end

      mouseinterval_args << arg
      true
    end
  end

  subject(:mouse) { described_class.new(key_action, display_fn) }

  describe 'click-resolution save/restore' do
    it 'suppresses with interval 0 when enabling click events with drag highlight' do
      mouse.enable_click_events
      expect(mouseinterval_args).to eq([0])
    end

    it 'restores an Integer interval (not the boolean return) when disabling' do
      mouse.enable_click_events
      expect { mouse.disable_click_events }.not_to raise_error
      expect(mouseinterval_args).to eq([0, MouseScroll::DEFAULT_MOUSEINTERVAL])
    end

    it 'restores click resolution when drag highlight is toggled off while active' do
      mouse.enable_click_events
      mouseinterval_args.clear
      expect { mouse.drag_highlight = false }.not_to raise_error
      expect(mouseinterval_args).to eq([MouseScroll::DEFAULT_MOUSEINTERVAL])
    end

    it 'suppresses again when drag highlight is toggled back on while active' do
      mouse.enable_click_events
      mouse.drag_highlight = false
      mouseinterval_args.clear
      expect { mouse.drag_highlight = true }.not_to raise_error
      expect(mouseinterval_args).to eq([0])
    end

    it 'does not restore when nothing was suppressed (drag highlight off from the start)' do
      allow(ProfanitySettings).to receive(:load_setting).and_return(false)
      mouse.enable_click_events # drag highlight off -> no suppression
      expect(mouseinterval_args).to be_empty
      expect { mouse.disable_click_events }.not_to raise_error
      expect(mouseinterval_args).to be_empty
    end
  end
end
