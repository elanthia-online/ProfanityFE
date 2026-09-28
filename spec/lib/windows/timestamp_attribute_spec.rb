# frozen_string_literal: true

# Tests the layout `timestamp` attribute of text and tabbed windows as a user
# sees it: windows are built from layout XML by WindowManager and draw onto
# the virtual screen (spec/support/virtual_screen.rb).

require 'rexml/document'
require_relative '../../../lib/window_manager'

RSpec.describe 'layout timestamp attribute' do
  before { allow(Time).to receive(:now).and_return(Time.new(2026, 9, 28, 9, 5, 0)) }

  # Build a one-window layout and return the window serving 'main'.
  #
  # @param klass [String] the window class ('text' or 'tabbed')
  # @param timestamp [String, nil] the attribute's value, nil to leave it out
  # @return [TextWindow, TabbedTextWindow]
  def build_window(klass, timestamp)
    attribute = timestamp.nil? ? '' : " timestamp='#{timestamp}'"
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='#{klass}' top='0' left='0' height='3' width='30' value='main'#{attribute}/></layout>
    XML
    window_manager = WindowManager.new
    window_manager.load_layout('test')
    window_manager.stream['main']
  end

  %w[text tabbed].each do |klass|
    context "on a #{klass} window" do
      ['true', 'TRUE', 'yes', 'Yes', '1', 'on', ' true '].each do |value|
        it "appends a timestamp with timestamp='#{value}'" do
          window = build_window(klass, value)
          window.add_string('hello')

          expect(window.rows).to include 'hello [09:05]'
        end
      end

      ['false', 'FALSE', 'False', 'no', 'NO', '0', 'off', ' false '].each do |value|
        it "shows no timestamp with timestamp='#{value}'" do
          window = build_window(klass, value)
          window.add_string('hello')

          expect(window.rows).to include 'hello'
          expect(window.rows.join).not_to include '[09:05]'
        end
      end

      it 'shows no timestamp when the attribute is absent' do
        window = build_window(klass, nil)
        window.add_string('hello')

        expect(window.rows).to include 'hello'
        expect(window.rows.join).not_to include '[09:05]'
      end

      # Before the attribute was parsed any value turned timestamps on;
      # values that aren't a recognized "off" keep doing so.
      ['', 'always'].each do |value|
        it "keeps appending a timestamp with an unrecognized value '#{value}'" do
          window = build_window(klass, value)
          window.add_string('hello')

          expect(window.rows).to include 'hello [09:05]'
        end
      end
    end
  end
end
