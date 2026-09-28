# frozen_string_literal: true

# Tests WindowManager#add_prompt as the user sees it: a bare prompt that
# repeats the newest line a window shows is not shown again. Windows are
# built from layout XML through WindowManager#load_layout and draw onto the
# virtual screen (spec/support/virtual_screen.rb).

require 'rexml/document'
require_relative '../../lib/window_manager'
require_relative '../../lib/windows/sink_window' # real SinkWindow

RSpec.describe WindowManager, '#add_prompt' do
  subject(:wm) { described_class.new }

  def load(windows_xml)
    LAYOUT['prompts'] = REXML::Document.new("<layout>#{windows_xml}</layout>").root
    wm.load_layout('prompts')
  end

  context 'with a text window' do
    before { load("<window class='text' top='0' left='0' height='4' width='21' value='main'/>") }

    let(:window) { wm.stream['main'] }

    it 'does not show a bare prompt twice in a row' do
      wm.add_prompt(window, 'H>')
      wm.add_prompt(window, 'H>')

      expect(window.rows).to eq ['H>', '', '', '']
    end

    it 'looks past blank lines to the newest line with text' do
      wm.add_prompt(window, 'H>')
      window.add_string('')

      wm.add_prompt(window, 'H>')

      expect(window.rows).to eq ['H>', '', '', '']
    end

    it 'shows the prompt again once other text follows it' do
      wm.add_prompt(window, 'H>')
      window.add_string('You look around.')

      wm.add_prompt(window, 'H>')

      expect(window.rows).to eq ['H>', 'You look around.', 'H>', '']
    end

    it 'shows a changed prompt' do
      wm.add_prompt(window, 'H>')

      wm.add_prompt(window, 'R>')

      expect(window.rows).to eq ['H>', 'R>', '', '']
    end

    it 'always shows a prompt with the command typed after it' do
      wm.add_prompt(window, 'H>')

      wm.add_prompt(window, 'H>', 'look')
      wm.add_prompt(window, 'H>', 'look')

      expect(window.rows).to eq ['H>', 'H>look', 'H>look', '']
    end
  end

  context 'with a tabbed window' do
    let(:window) { wm.stream['main'] }

    it 'compares against the main tab even while another tab is shown' do
      load("<window class='tabbed' top='0' left='0' height='4' width='31' tabs='main,combat'/>")
      wm.add_prompt(window, 'H>')
      window.switch_tab('combat')

      wm.add_prompt(window, 'H>')
      # No activity mark on the main tab: nothing was added to it.
      expect(window.rows.first).to eq ' 1:main | 2:combat'
      window.switch_tab('main')

      expect(window.rows).to eq [' 1:main | 2:combat', 'H>', '', '']
    end

    it 'shows every prompt when the window has no main tab' do
      load("<window class='tabbed' top='0' left='0' height='4' width='31' tabs='combat'/>")
      combat = wm.stream['combat']

      wm.add_prompt(combat, 'H>')
      wm.add_prompt(combat, 'H>')

      expect(combat.rows).to eq [' 1:combat', 'H>', 'H>', '']
    end
  end

  it 'shows nothing for a stream sent to a sink' do
    load("<window class='sink' value='main'/>")

    expect { wm.add_prompt(wm.stream['main'], 'H>') }.not_to raise_error
  end

  it 'shows nothing in a window without a line buffer' do
    load("<window class='exp' top='0' left='0' height='4' width='21'/>")
    window = wm.stream['exp']

    wm.add_prompt(window, 'H>')

    expect(window.rows).to eq ['', '', '', '']
  end
end
