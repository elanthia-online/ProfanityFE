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

  describe 'the base color with label colors' do
    # A three-state indicator whose label colors highlight only its last
    # letter, so the first letter shows the base color.
    let(:window_manager) do
      LAYOUT['test'] = REXML::Document.new(<<~XML).root
        <layout><window class='indicator' top='0' left='0' height='1' width='12' value='room players' label='Mahtra'
                        fg='444444,ffff00,ff0000' bg='000000,111111,222222'/></layout>
      XML
      WindowManager.new.tap { |wm| wm.load_layout('test') }
    end
    let(:window) { window_manager.indicator['room players'] }
    let(:highlight) { [{ start: 5, end: 6, fg: 'abcdef' }] }

    # [fg, bg] of every color pair handed out; pair id n is colors[n - 1].
    let(:colors) { [] }

    # The label colors path draws through HighlightProcessor, the plain one
    # through the window.
    before do
      [HighlightProcessor, window].each do |drawer|
        allow(drawer).to receive(:get_color_pair_id) do |fg, bg|
          colors << [fg, bg] unless colors.include?([fg, bg])
          colors.index([fg, bg]) + 1
        end
      end
    end

    # The [fg, bg] letter +x+ is drawn in.
    def colors_at(x)
      colors[(window.attrs_at(0, x) >> 8) - 1]
    end

    {
      0 => %w[444444 000000], 1 => %w[ffff00 111111], 2 => %w[ff0000 222222],
      true => %w[ffff00 111111], false => %w[444444 000000], nil => %w[444444 000000]
    }.each do |value, expected|
      it "is the color the label has without them for value #{value.inspect}" do
        event_bus.emit(:indicator_update, id: 'room players', value: value, label_colors: nil)
        plain = colors_at(0)

        event_bus.emit(:indicator_update, id: 'room players', label_colors: highlight)

        expect([plain, colors_at(0)]).to eq [expected, expected]
        expect(colors_at(5)).to eq ['abcdef', expected[1]]
      end
    end
  end

  describe '#apply_changes' do
    it 'says whether it redrew' do
      expect(window.apply_changes(label: 'None')).to be false
      expect(window.apply_changes(label: 'Shadows', value: 1)).to be true
      expect(window.apply_changes({})).to be false
      expect(draws).to eq 1
    end
  end
end
