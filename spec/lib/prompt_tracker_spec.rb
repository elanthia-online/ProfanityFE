# frozen_string_literal: true

# Tests PromptTracker#blank_line, the blank line where a pending prompt is
# shown: after a movement line the prompt is skipped, whether the movement
# is known from the flag or from the main window's newest line (in any tab
# of a tabbed main window). Also the stream-text copy check.

require 'rexml/document'
require_relative '../../lib/window_manager'
require_relative '../../lib/prompt_tracker'
require_relative '../../lib/pending_render'
require_relative '../../lib/shared_state'
require_relative '../../lib/event_bus'

RSpec.describe PromptTracker do
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.prompt_text = 'H>' } }
  let(:window_mgr) do
    LAYOUT['test'] = REXML::Document.new(layout).root
    WindowManager.new.tap { |manager| manager.load_layout('test') }
  end
  let(:layout) { "<layout><window class='text' top='0' left='0' height='4' width='40' value='main'/></layout>" }
  let(:tracker) do
    described_class.new(shared_state: state, event_bus: event_bus, pending_render: PendingRender.new,
                        window_mgr: window_mgr)
  end
  let(:prompts) { [] }

  before { event_bus.on(:add_prompt) { |data| prompts << data[:text] } }

  # A blank line with a prompt pending
  def blank_line_with_prompt_pending
    state.need_prompt = true
    tracker.blank_line
  end

  it 'shows the pending prompt at a blank line and consumes it' do
    blank_line_with_prompt_pending

    expect(prompts).to eq ['H>']
    expect(state.need_prompt).to be false
  end

  it 'skips the prompt after a movement line shown in main, and only that once' do
    tracker.movement_seen
    blank_line_with_prompt_pending
    blank_line_with_prompt_pending

    expect(prompts).to eq ['H>']
  end

  it "skips the prompt while the main window's newest line is movement" do
    window_mgr.stream['main'].add_string('You walk north.')
    blank_line_with_prompt_pending

    expect(prompts).to be_empty
    expect(state.need_prompt).to be false
  end

  context 'with a tabbed main window' do
    let(:layout) do
      "<layout><window class='tabbed' top='0' left='0' height='5' width='40' tabs='main,combat'/></layout>"
    end

    it "skips the prompt when any tab's newest line is movement" do
      main = window_mgr.stream['main']
      main.add_string_to_tab('main', 'A goblin arrives.')
      main.add_string_to_tab('combat', 'You sneak east.')
      blank_line_with_prompt_pending

      expect(prompts).to be_empty
    end

    it 'shows the prompt when no tab ends with movement' do
      window_mgr.stream['main'].add_string_to_tab('combat', 'You sneak east.')
      window_mgr.stream['main'].add_string_to_tab('combat', 'A goblin arrives.')
      blank_line_with_prompt_pending

      expect(prompts).to eq ['H>']
    end
  end

  context 'with a tabbed main window the terminal width sizes' do
    # 50 wide at 100 columns (wrapping at 48), 24 wide at 48 (wrapping at
    # 22): the movement line fits on one row only at the wider width
    let(:layout) do
      "<layout><window class='tabbed' top='0' left='0' height='5' width='cols/2' tabs='main,combat'/></layout>"
    end
    let(:movement) { 'You go through the gate in the old wall.' }

    # Change the terminal width and resize the windows.
    def resize_to(cols)
      allow(Curses).to receive(:cols).and_return(cols)
      window_mgr.resize(nil)
    end

    it "skips the prompt when a hidden tab's newest row is movement once a resize widens it" do
      resize_to(48)
      window_mgr.stream['main'].add_string_to_tab('combat', movement)
      resize_to(100)
      blank_line_with_prompt_pending

      expect(prompts).to be_empty
    end

    it "shows the prompt when a resize wraps a hidden tab's movement line onto two rows" do
      resize_to(100)
      window_mgr.stream['main'].add_string_to_tab('combat', movement)
      resize_to(48)
      blank_line_with_prompt_pending

      expect(prompts).to eq ['H>']
    end
  end

  describe '#stream_text_copy?' do
    it "is true only for the next main line with the stream line's text, and uses the text up" do
      tracker.stream_text_sent('  Ytterby whispers, "Done!" ')

      expect(tracker.stream_text_copy?('Ytterby whispers, "Done!"')).to be true
      expect(tracker.stream_text_copy?('Ytterby whispers, "Done!"')).to be false
    end

    it 'is false after a prompt tag forgot the stream line' do
      tracker.stream_text_sent('Ytterby whispers, "Done!"')
      tracker.prompt_tag('<prompt>&gt;</prompt>')

      expect(tracker.stream_text_copy?('Ytterby whispers, "Done!"')).to be false
    end
  end
end
