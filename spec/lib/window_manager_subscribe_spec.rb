# frozen_string_literal: true

# Tests WindowManager#subscribe_to_events: verifies that each event type
# is correctly bridged to the appropriate window method — stream routing,
# prompt display, indicator/progress/countdown updates, room data,
# exp/perc stream management, and special events (launch URL, disconnect).

require_relative '../../lib/event_bus'
require_relative '../../lib/window_manager'
require_relative '../../lib/windows/sink_window' # real SinkWindow (spec_helper only declares the class)

# Spy objects that record method calls for verification

class SpyStreamWindow
  attr_reader :calls

  def initialize
    @calls = []
    @last_text = nil
  end

  def route_string(text, colors, stream, **opts)
    @calls << { method: :route_string, text: text, colors: colors, stream: stream, **opts }
    @last_text = text
  end

  def add_string(text, colors = [])
    @calls << { method: :add_string, text: text, colors: colors }
  end

  def component_opened(key)
    @calls << { method: :component_opened, key: key }
  end

  def component_closed
    @calls << { method: :component_closed }
  end

  def stream_cleared
    @calls << { method: :stream_cleared }
  end

  def duplicate_prompt?(_text) = false
  def respond_to?(m, *) = m == :duplicate_prompt? ? true : super
end

class SpyIndicatorWindow
  attr_accessor :label, :label_colors
  attr_reader :calls, :value

  def initialize
    @calls = []
    @label = nil
    @label_colors = nil
    @value = nil
  end

  def update(value)
    @calls << { method: :update, value: value }
    true
  end

  def redraw
    @calls << { method: :redraw }
    true
  end
end

class SpyCountdownWindow
  attr_accessor :end_time, :secondary_end_time, :active
  attr_reader :calls

  def initialize
    @calls = []
  end

  def tick
    @calls << { method: :tick }
    true
  end
end

class SpyRoomWindow
  attr_reader :calls

  def initialize
    @calls = []
  end

  def update_title(text) = @calls << { method: :update_title, text: text }
  def update_desc(text, links: []) = @calls << { method: :update_desc, text: text, links: links }
  def update_objects(text, links: [], creatures: []) = @calls << { method: :update_objects, text: text, links: links, creatures: creatures }
  def update_players(text, links: []) = @calls << { method: :update_players, text: text, links: links }
  def update_exits(text, links: [])   = @calls << { method: :update_exits, text: text, links: links }
  def update_room_number(text) = @calls << { method: :update_room_number, text: text }
  def update_stringprocs(text) = @calls << { method: :update_stringprocs, text: text }
  def clear_supplemental  = @calls << { method: :clear_supplemental }
  def render              = @calls << { method: :render }
end

RSpec.describe WindowManager, '#subscribe_to_events' do
  let(:event_bus) { EventBus.new }
  let(:main_window) { SpyStreamWindow.new }
  let(:wm) { described_class.new }

  before do
    wm.instance_variable_set(:@stream, { 'main' => main_window })
    wm.subscribe_to_events(event_bus)
  end

  # ---- :stream_text ----

  describe ':stream_text' do
    it 'routes text to the named stream window' do
      event_bus.emit(:stream_text, stream: 'main', text: 'Hello', colors: [])
      expect(main_window.calls.last).to include(method: :route_string, text: 'Hello', stream: 'main')
    end

    it 'ignores events for nonexistent streams' do
      expect { event_bus.emit(:stream_text, stream: 'combat', text: 'hit', colors: []) }.not_to raise_error
      expect(main_window.calls).to be_empty
    end
  end

  # ---- :add_prompt ----

  describe ':add_prompt' do
    it 'calls add_prompt with window and text' do
      event_bus.emit(:add_prompt, stream: 'main', text: '>')
      call = main_window.calls.find { |c| c[:method] == :route_string }
      expect(call[:text]).to eq '>'
    end

    it 'does not crash when command is absent from event data' do
      expect { event_bus.emit(:add_prompt, stream: 'main', text: '>') }.not_to raise_error
    end

    it 'passes command when present' do
      event_bus.emit(:add_prompt, stream: 'main', text: '>', command: 'look')
      call = main_window.calls.find { |c| c[:method] == :route_string }
      expect(call[:text]).to eq '>look'
    end

    it 'ignores events for nonexistent streams' do
      expect { event_bus.emit(:add_prompt, stream: 'nonexistent', text: '>') }.not_to raise_error
      expect(main_window.calls).to be_empty
    end
  end

  # ---- :indicator_update ----

  describe ':indicator_update' do
    # A real indicator on the virtual screen; when it redraws is covered in
    # spec/lib/windows/indicator_window_spec.rb.
    let(:indicator) { IndicatorWindow.new(1, 12, 0, 0) }

    before { wm.instance_variable_set(:@indicator, { 'spell' => indicator }) }

    it 'sets label and value and shows the label' do
      event_bus.emit(:indicator_update, id: 'spell', label: 'Fire Ball', value: 1)
      expect([indicator.label, indicator.value]).to eq ['Fire Ball', 1]
      expect(indicator.rows).to eq ['Fire Ball']
    end

    it 'sets only the label when no value is given' do
      event_bus.emit(:indicator_update, id: 'spell', label: 'None')
      expect([indicator.label, indicator.value]).to eq ['None', nil]
      expect(indicator.rows).to eq ['None']
    end

    it 'sets only the value when no label is given' do
      event_bus.emit(:indicator_update, id: 'spell', value: 0)
      expect([indicator.label, indicator.value]).to eq ['*', 0]
      expect(indicator.rows).to eq ['*']
    end

    it 'sets label_colors' do
      colors = [{ start: 0, end: 4, fg: 'ff0000' }]
      event_bus.emit(:indicator_update, id: 'spell', label: 'test', label_colors: colors)
      expect(indicator.label_colors).to eq colors
      expect(indicator.rows).to eq ['test']
    end

    it 'ignores events for nonexistent indicators' do
      expect { event_bus.emit(:indicator_update, id: 'nonexistent', value: 1) }.not_to raise_error
      expect(indicator.value).to be_nil
    end
  end

  # ---- :compass_update ----

  describe ':compass_update' do
    let(:north) { SpyIndicatorWindow.new }
    let(:south) { SpyIndicatorWindow.new }

    before do
      wm.instance_variable_set(:@indicator, { 'compass:n' => north, 'compass:s' => south })
    end

    it 'activates matching directions and deactivates others' do
      event_bus.emit(:compass_update, dirs: ['n'])
      expect(north.calls.last).to include(value: true)
      expect(south.calls.last).to include(value: false)
    end
  end

  # ---- :progress_update ----

  describe ':progress_update' do
    # A real progress bar on the virtual screen; when it redraws is covered
    # in spec/lib/arb_progress_spec.rb.
    let(:progress) { ProgressWindow.new(1, 10, 0, 0).tap { |bar| bar.label = 'hp' } }

    before { wm.instance_variable_set(:@progress, { 'health' => progress }) }

    it 'sets value and max and shows the value' do
      event_bus.emit(:progress_update, id: 'health', value: 75, max: 150)
      expect([progress.value, progress.max_value]).to eq [75, 150]
      expect(progress.rows).to eq ['hp      75']
    end

    it 'sets label, fg, bg when provided' do
      event_bus.emit(:progress_update, id: 'health', value: 50, max: 100,
                                       label: 'HP', fg: ['00ff00'], bg: ['ff0000'])
      expect([progress.label, progress.fg, progress.bg]).to eq ['HP', ['00ff00'], ['ff0000']]
      expect(progress.rows).to eq ['HP      50']
    end

    it 'ignores events for nonexistent progress bars' do
      expect { event_bus.emit(:progress_update, id: 'mana', value: 50, max: 100) }.not_to raise_error
    end
  end

  # ---- :countdown_update ----

  describe ':countdown_update' do
    let(:countdown) { SpyCountdownWindow.new }

    before { wm.instance_variable_set(:@countdown, { 'roundtime' => countdown }) }

    it 'sets end_time and triggers a redraw' do
      event_bus.emit(:countdown_update, id: 'roundtime', end_time: 12345)
      expect(countdown.end_time).to eq 12345
      expect(countdown.calls).to include(a_hash_including(method: :tick))
    end

    it 'sets secondary_end_time and triggers a redraw' do
      event_bus.emit(:countdown_update, id: 'roundtime', secondary_end_time: 99999)
      expect(countdown.secondary_end_time).to eq 99999
      expect(countdown.calls).to include(a_hash_including(method: :tick))
    end

    it 'ignores events for nonexistent countdowns' do
      expect { event_bus.emit(:countdown_update, id: 'nonexistent', end_time: 1) }.not_to raise_error
    end
  end

  # ---- :countdown_active ----

  describe ':countdown_active' do
    let(:countdown) { SpyCountdownWindow.new }

    before { wm.instance_variable_set(:@countdown, { 'stunned' => countdown }) }

    it 'sets active flag and triggers a redraw' do
      event_bus.emit(:countdown_active, id: 'stunned', active: true)
      expect(countdown.active).to be true
      expect(countdown.calls).to include(a_hash_including(method: :tick))
    end
  end

  # ---- :stun ----

  describe ':stun' do
    let(:countdown) { SpyCountdownWindow.new }
    let(:wm) { described_class.new(clock: Clock.new(now: -> { Time.at(1000.0) })) }

    before do
      wm.instance_variable_set(:@countdown, { 'stunned' => countdown })
    end

    it 'sets end_time to the server time plus the stun duration and triggers a redraw' do
      wm.clock.server_time_offset = 2.5
      event_bus.emit(:stun, seconds: 10)
      expect(countdown.end_time).to eq 1007.5
      expect(countdown.calls).to include(a_hash_including(method: :tick))
    end

    it 'ignores when no stunned countdown exists' do
      wm.instance_variable_set(:@countdown, {})
      expect { event_bus.emit(:stun, seconds: 5) }.not_to raise_error
    end
  end

  # ---- Room events ----

  describe 'room events' do
    let(:room_window) { SpyRoomWindow.new }

    before { wm.instance_variable_set(:@room, { 'room' => room_window }) }

    it ':room_title calls update_title' do
      event_bus.emit(:room_title, text: 'Town Square')
      expect(room_window.calls.last).to include(method: :update_title, text: 'Town Square')
    end

    it ':room_desc calls update_desc' do
      event_bus.emit(:room_desc, text: 'A busy square.')
      expect(room_window.calls.last).to include(method: :update_desc, text: 'A busy square.')
    end

    it ':room_objects calls update_objects' do
      event_bus.emit(:room_objects, text: 'You also see a sword.')
      expect(room_window.calls.last).to include(method: :update_objects)
    end

    it ':room_players calls update_players' do
      event_bus.emit(:room_players, text: 'Also here: Mahtra')
      expect(room_window.calls.last).to include(method: :update_players)
    end

    it ':room_exits calls update_exits' do
      event_bus.emit(:room_exits, text: 'Obvious paths: north, south')
      expect(room_window.calls.last).to include(method: :update_exits)
    end

    it ':room_number calls update_room_number' do
      event_bus.emit(:room_number, text: 'Room Number: 230008')
      expect(room_window.calls.last).to include(method: :update_room_number)
    end

    it ':room_stringprocs calls update_stringprocs' do
      event_bus.emit(:room_stringprocs, text: 'StringProcs: ...')
      expect(room_window.calls.last).to include(method: :update_stringprocs)
    end

    it ':room_supplemental_clear calls clear_supplemental' do
      event_bus.emit(:room_supplemental_clear)
      expect(room_window.calls.last).to include(method: :clear_supplemental)
    end

    it ':room_render calls render' do
      event_bus.emit(:room_render)
      expect(room_window.calls.last).to include(method: :render)
    end

    it 'room events are no-ops when no room window exists' do
      wm.instance_variable_set(:@room, {})
      %i[room_title room_desc room_objects room_players room_exits
         room_number room_stringprocs room_supplemental_clear room_render].each do |event|
        expect { event_bus.emit(event, text: 'test') }.not_to raise_error
      end
    end
  end

  # ---- Stream management events ----

  describe ':exp_set_current' do
    let(:exp_window) { SpyStreamWindow.new }

    before { wm.instance_variable_set(:@stream, { 'main' => main_window, 'exp' => exp_window }) }

    it 'calls component_opened on exp window' do
      event_bus.emit(:exp_set_current, skill: 'Athletics')
      expect(exp_window.calls.last).to include(method: :component_opened, key: 'Athletics')
    end

    it 'is a no-op when no exp window exists' do
      wm.instance_variable_set(:@stream, { 'main' => main_window })
      expect { event_bus.emit(:exp_set_current, skill: 'Athletics') }.not_to raise_error
    end
  end

  describe ':exp_delete_skill' do
    let(:exp_window) { SpyStreamWindow.new }

    before { wm.instance_variable_set(:@stream, { 'main' => main_window, 'exp' => exp_window }) }

    it 'calls component_closed on exp window' do
      event_bus.emit(:exp_delete_skill)
      expect(exp_window.calls.last).to include(method: :component_closed)
    end
  end

  describe ':clear_spells' do
    let(:perc_window) { SpyStreamWindow.new }

    before { wm.instance_variable_set(:@stream, { 'main' => main_window, 'percWindow' => perc_window }) }

    it 'calls stream_cleared on percWindow' do
      event_bus.emit(:clear_spells)
      expect(perc_window.calls.last).to include(method: :stream_cleared)
    end
  end

  # ---- Special events ----

  describe 'a sink window standing in for the exp and spell windows' do
    # <window class='sink' value='exp,percWindow'/>
    before do
      sink = SinkWindow.new
      wm.instance_variable_set(:@stream, { 'main' => main_window, 'exp' => sink, 'percWindow' => sink })
    end

    it 'silently absorbs exp and spell window events' do
      expect do
        event_bus.emit(:exp_set_current, skill: 'Athletics')
        event_bus.emit(:exp_delete_skill)
        event_bus.emit(:clear_spells)
      end.not_to raise_error
    end
  end

  describe ':launch_url' do
    it 'displays URL in main window when remote is true' do
      event_bus.emit(:launch_url, url: 'https://www.play.net/path', remote: true)
      texts = main_window.calls.map { |c| c[:text] }
      expect(texts).to include(' *')
      expect(texts).to include(' * LaunchURL: https://www.play.net/path')
    end

    context 'when remote is false' do
      before do
        stub_const('RbConfig::CONFIG', RbConfig::CONFIG.merge('host_os' => 'darwin'))
        allow(Process).to receive(:spawn).and_return(4242)
        allow(Process).to receive(:detach)
      end

      it 'opens the URL in the browser instead of displaying it' do
        event_bus.emit(:launch_url, url: 'https://www.play.net/path', remote: false)

        expect(Process).to have_received(:spawn).with('open', 'https://www.play.net/path', out: File::NULL, err: File::NULL)
        expect(main_window.calls.map { |c| c[:text] }).not_to include(' * LaunchURL: https://www.play.net/path')
      end

      it 'passes shell metacharacters in the URL through as one literal argument' do
        url = 'https://www.play.net/x$(touch /tmp/pwned)`id`'

        event_bus.emit(:launch_url, url: url, remote: false)

        expect(Process).to have_received(:spawn).with('open', url, out: File::NULL, err: File::NULL)
      end

      it 'logs instead of raising when the browser command is missing' do
        allow(Process).to receive(:spawn).and_raise(Errno::ENOENT, 'open')
        allow(ProfanityLog).to receive(:write)

        event_bus.emit(:launch_url, url: 'https://www.play.net/path', remote: false)

        expect(ProfanityLog).to have_received(:write).with('launch_url', a_string_including('could not open'))
      end
    end

    it 'is a no-op when no main window exists' do
      wm.instance_variable_set(:@stream, {})
      expect { event_bus.emit(:launch_url, url: 'https://example.com', remote: true) }.not_to raise_error
    end
  end

  describe ':disconnect' do
    it 'adds disconnect messages to main window' do
      event_bus.emit(:disconnect)
      texts = main_window.calls.map { |c| c[:text] }
      expect(texts).to include('* Connection closed')
      expect(texts).to include('* Press any key to exit...')
    end

    it 'applies feedback colors to disconnect messages' do
      event_bus.emit(:disconnect)
      colors = main_window.calls.first[:colors]
      expect(colors.first[:fg]).to eq FEEDBACK_COLOR
    end

    it 'is a no-op when no main window exists' do
      wm.instance_variable_set(:@stream, {})
      expect { event_bus.emit(:disconnect) }.not_to raise_error
    end
  end
end
