# frozen_string_literal: true

# Tests TabbedTextWindow as a user sees it: windows are built from layout XML
# by WindowManager and draw onto the virtual screen (spec/support/virtual_screen.rb).

require 'rexml/document'
require_relative '../../../lib/window_manager'

RSpec.describe TabbedTextWindow do
  # A tabbed window 4 rows high and 12 columns wide: the tab bar on row 0
  # and 3 rows of text below it. The builder keeps one column for the
  # scrollbar, so text wraps at 10 characters.
  let(:window) do
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout><window class='tabbed' top='0' left='0' height='4' width='12' tabs='main'/></layout>
    XML
    window_manager = WindowManager.new
    window_manager.load_layout('test')
    window_manager.stream['main']
  end

  # @return [Array<String>] the visible text rows below the tab bar
  def text_rows
    window.rows.drop(TabbedTextWindow::TAB_BAR_HEIGHT)
  end

  it 'shows the newest lines below the tab bar once the tab is full' do
    %w[l1 l2 l3 l4 l5].each { |line| window.add_string(line) }

    expect(window.rows).to eq [' 1:main', 'l3', 'l4', 'l5']
  end

  it 'shows a full page of older lines after a page-up of the whole text area' do
    %w[l1 l2 l3 l4 l5 l6 l7 l8 l9].each { |line| window.add_string(line) }

    window.scroll(-window.content_height)

    expect(window.rows).to eq [' 1:main', 'l4', 'l5', 'l6']
  end
end
