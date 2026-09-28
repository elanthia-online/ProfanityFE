# frozen_string_literal: true

# Tests IndicatorWindow as a user sees it: the window is built from layout
# XML by WindowManager, draws onto the virtual screen
# (spec/support/virtual_screen.rb), and is updated by the parser's
# :indicator_update events.

require 'rexml/document'
require_relative '../../../lib/event_bus'
require_relative '../../../lib/window_manager'

RSpec.describe IndicatorWindow do
  let(:window_manager) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='indicator' top='0' left='0' height='1' width='12' value='spell' label='None'/></layout>
    XML
    WindowManager.new.tap { |wm| wm.load_layout('test') }
  end
  let(:window) { window_manager.indicator['spell'] }
  let(:event_bus) { EventBus.new.tap { |bus| window_manager.subscribe_to_events(bus) } }

  # Number of times the label has been drawn since the call log was cleared.
  def draws
    window.call_log.count { |(meth, args)| meth == :setpos && args == [0, 0] }
  end

  before { window.call_log.clear }

  describe 'an :indicator_update event' do
    it 'shows the new label and value in one redraw' do
      event_bus.emit(:indicator_update, id: 'spell', label: 'Fire Ball', value: 1)

      expect(window.rows).to eq ['Fire Ball']
      expect([window.label, window.value]).to eq ['Fire Ball', 1]
      expect(draws).to eq 1
    end

    it 'redraws for a new label alone' do
      event_bus.emit(:indicator_update, id: 'spell', label: 'Shadows')

      expect(window.rows).to eq ['Shadows']
      expect(draws).to eq 1
    end

    it 'redraws for a new value alone, keeping the label' do
      event_bus.emit(:indicator_update, id: 'spell', value: true)

      expect(window.rows).to eq ['None']
      expect(window.value).to be true
      expect(draws).to eq 1
    end

    it 'does not redraw when the label and value are unchanged' do
      event_bus.emit(:indicator_update, id: 'spell', label: 'None', value: nil)

      expect(draws).to eq 0
    end

    it 'redraws whenever label colors are sent, even the same ones' do
      colors = [{ start: 0, end: 4, fg: 'ff0000' }]
      event_bus.emit(:indicator_update, id: 'spell', label_colors: colors)
      event_bus.emit(:indicator_update, id: 'spell', label_colors: colors)

      expect(window.label_colors).to eq colors
      expect(window.rows).to eq ['None']
      expect(draws).to eq 2
    end

    it 'shows a shorter label without leftovers of the longer one' do
      event_bus.emit(:indicator_update, id: 'spell', label: 'Fire Ball')

      event_bus.emit(:indicator_update, id: 'spell', label: 'Aus')

      expect(window.rows).to eq ['Aus']
    end
  end
end
