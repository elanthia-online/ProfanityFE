# frozen_string_literal: true

# Tests TextWindow as a user sees it: windows are built from layout XML by
# WindowManager and draw onto the virtual screen (spec/support/virtual_screen.rb).

require 'rexml/document'
require_relative '../../../lib/window_manager'

RSpec.describe TextWindow do
  # A text window 3 rows high and 12 columns wide. The builder keeps one
  # column for the scrollbar, so text wraps at 10 characters.
  let(:window) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='text' top='0' left='0' height='3' width='12' value='main'/></layout>
    XML
    window_manager = WindowManager.new
    window_manager.load_layout('test')
    window_manager.stream['main']
  end

  it 'shows the newest lines at the bottom once the window is full' do
    %w[l1 l2 l3 l4 l5].each { |line| window.add_string(line) }

    expect(window.rows).to eq %w[l3 l4 l5]
  end

  it 'wraps a long line to the window width and indents the continuation' do
    window.add_string('one two three four')

    expect(window.rows).to eq ['one two', '  three', '  four']
  end

  it 'shows older lines when scrolled back and returns to the newest lines' do
    %w[l1 l2 l3 l4 l5].each { |line| window.add_string(line) }
    window.add_string('one two three four')

    window.scroll(-2)
    expect(window.rows).to eq ['l4', 'l5', 'one two']

    window.scroll(2)
    expect(window.rows).to eq ['one two', '  three', '  four']
  end

  it 'shows a full page of older lines after scrolling back by the whole window height' do
    %w[l1 l2 l3 l4 l5 l6 l7 l8 l9].each { |line| window.add_string(line) }

    window.scroll(-window.maxy)

    expect(window.rows).to eq %w[l4 l5 l6]
  end
end
