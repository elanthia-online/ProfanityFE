# frozen_string_literal: true

# Tests EventBridge: each parser event shows up in the window it's for.
# Windows are built from layout XML by WindowManager#load_layout on the
# virtual screen (24x80), the bridge subscribes to a real EventBus, and
# the examples assert what the windows then show. Colors are covered in
# window_contracts_spec.rb.

require 'rexml/document'
require_relative '../../lib/event_bus'
require_relative '../../lib/window_manager'
require_relative '../../lib/windows/sink_window' # real SinkWindow

RSpec.describe EventBridge do
  let(:now) { [1_000_000.0] }
  let(:clock) { Clock.new(now: -> { Time.at(now[0]) }) }
  let(:wm) { WindowManager.new(clock: clock) }
  let(:event_bus) { EventBus.new }

  let(:layout) do
    <<~XML
      <window class='text' top='0' left='0' height='4' width='42' value='main'/>
      <window class='text' top='0' left='42' height='4' width='22' value='death'/>
      <window class='indicator' top='5' left='0' height='1' width='6' value='kneeling' label='kneel'/>
      <window class='indicator' top='5' left='10' height='1' width='1' value='compass:n' label='n'/>
      <window class='indicator' top='5' left='12' height='1' width='1' value='compass:s' label='s'/>
      <window class='progress' top='6' left='0' height='1' width='20' value='health' label='hp'/>
      <window class='countdown' top='7' left='0' height='1' width='20' value='roundtime' label='RT'/>
      <window class='countdown' top='8' left='0' height='1' width='20' value='stunned' label='ST'/>
      <window class='exp' top='9' left='0' height='3' width='61'/>
      <window class='percWindow' top='12' left='0' height='3' width='31'/>
      <window class='room' top='15' left='0' height='6' width='60' value='room'/>
      <window class='sink' value='atmospherics'/>
      <window class='indicator' top='23' left='0' height='1' width='1' value='prompt' label='&gt;'/>
      <window class='command' top='23' left='1' height='1' width='79'/>
    XML
  end

  let(:main) { wm.stream['main'] }
  let(:room) { wm.room['room'] }

  def load(windows_xml, id: 'bridge')
    LAYOUT[id] = REXML::Document.new("<layout>#{windows_xml}</layout>").root
    wm.load_layout(id)
  end

  def stream_text(stream, text)
    event_bus.emit(:stream_text, stream: stream, text: text, colors: [])
  end

  before do
    load(layout)
    described_class.new(wm).subscribe(event_bus)
  end

  it 'is what WindowManager#subscribe_to_events subscribes' do
    bus = EventBus.new
    bridge = instance_double(described_class, subscribe: nil)
    allow(described_class).to receive(:new).with(wm).and_return(bridge)

    wm.subscribe_to_events(bus)

    expect(bridge).to have_received(:subscribe).with(bus)
  end

  describe ':stream_text' do
    it 'shows the text in the window of its stream' do
      stream_text('main', 'You wave.')
      stream_text('death', 'Bob died.')

      expect(main.rows.first).to eq 'You wave.'
      expect(wm.stream['death'].rows.first).to eq 'Bob died.'
    end

    it 'wraps text with or without an indent, as the event says' do
      event_bus.emit(:stream_text, stream: 'main', text: "#{'word ' * 9}end", colors: [])
      event_bus.emit(:stream_text, stream: 'main', text: "#{'word ' * 9}end", colors: [], indent: false)

      expect(main.rows).to eq ["#{'word ' * 7}word", '  word end', "#{'word ' * 7}word", 'word end']
    end

    it 'drops text for a sunk stream or a stream with no window' do
      expect { stream_text('atmospherics', 'A breeze.') }.not_to raise_error
      expect { stream_text('nowhere', 'Lost.') }.not_to raise_error
      expect(main.rows).to all(eq '')
    end
  end

  describe ':add_prompt' do
    it 'shows the prompt, with the command after it, in main unless a stream is named' do
      event_bus.emit(:add_prompt, text: 'H>')
      event_bus.emit(:add_prompt, text: 'H>', command: 'look')
      event_bus.emit(:add_prompt, stream: 'death', text: 'R>')

      expect(main.rows[0, 2]).to eq ['H>', 'H>look']
      expect(wm.stream['death'].rows.first).to eq 'R>'
    end

    it 'shows a repeated bare prompt once' do
      2.times { event_bus.emit(:add_prompt, text: 'H>') }

      expect(main.rows[0, 2]).to eq ['H>', '']
    end

    it 'ignores a prompt for a stream with no window' do
      expect { event_bus.emit(:add_prompt, stream: 'nowhere', text: 'H>') }.not_to raise_error
      expect(main.rows).to all(eq '')
    end
  end

  describe ':indicator_update and :compass_update' do
    it 'sets the label and value of the indicator with that id' do
      event_bus.emit(:indicator_update, id: 'kneeling', label: 'KNEEL', value: true)

      expect(wm.indicator['kneeling'].rows).to eq ['KNEEL']
      expect(wm.indicator['kneeling'].value).to be true
    end

    it 'turns each compass direction on or off by whether the room has it' do
      event_bus.emit(:compass_update, dirs: %w[n up])

      expect([wm.indicator['compass:n'].value, wm.indicator['compass:s'].value]).to eq [true, false]

      event_bus.emit(:compass_update, dirs: %w[s])

      expect([wm.indicator['compass:n'].value, wm.indicator['compass:s'].value]).to eq [false, true]
    end

    it 'ignores an indicator the layout does not have' do
      expect { event_bus.emit(:indicator_update, id: 'sitting', value: true) }.not_to raise_error
    end
  end

  describe ':progress_update' do
    it 'shows the new label and value on the bar with that id' do
      event_bus.emit(:progress_update, id: 'health', label: 'HP', value: 40, max: 100)

      expect(wm.progress['health'].rows).to eq ["HP#{'40'.rjust(18)}"]
    end

    it 'ignores a bar the layout does not have' do
      expect { event_bus.emit(:progress_update, id: 'mana', value: 1, max: 2) }.not_to raise_error
    end
  end

  describe 'countdowns' do
    it 'shows the seconds left until the end time of :countdown_update' do
      event_bus.emit(:countdown_update, id: 'roundtime', end_time: now[0] + 5)

      expect(wm.countdown['roundtime'].rows).to eq ["RT#{'5'.rjust(18)}"]
    end

    it 'shows the later of the two end times' do
      event_bus.emit(:countdown_update, id: 'roundtime', end_time: now[0] + 2, secondary_end_time: now[0] + 4)

      expect(wm.countdown['roundtime'].rows).to eq ["RT#{'4'.rjust(18)}"]
    end

    it 'shows ? for an active countdown with no time left' do
      event_bus.emit(:countdown_active, id: 'roundtime', active: true)

      expect(wm.countdown['roundtime'].rows).to eq ["RT#{'?'.rjust(18)}"]
    end

    it 'counts a stun from now on the clock, in server time' do
      clock.server_time_offset = 3.0

      event_bus.emit(:stun, seconds: 6)

      expect(wm.countdown['stunned'].end_time).to eq now[0] - 3.0 + 6
      expect(wm.countdown['stunned'].rows).to eq ["ST#{'6'.rjust(18)}"]
    end

    it 'ignores countdowns the layout does not have' do
      load(layout.lines.grep_v(/countdown/).join, id: 'no-countdowns')

      expect do
        event_bus.emit(:countdown_update, id: 'roundtime', end_time: now[0] + 5)
        event_bus.emit(:countdown_active, id: 'roundtime', active: true)
        event_bus.emit(:stun, seconds: 6)
      end.not_to raise_error
    end
  end

  describe ':prompt_changed' do
    it 'shows the prompt and moves the command line over by its width' do
      event_bus.emit(:prompt_changed, text: 'RH>')

      expect(wm.indicator['prompt'].rows).to eq ['RH>']
      expect([wm.command_window.begx, wm.command_window.maxx]).to eq [3, 77]
    end
  end

  describe 'room events' do
    it 'shows every part of the room once the exits arrive' do
      event_bus.emit(:room_title, text: '[Town Square]')
      event_bus.emit(:room_desc, text: 'Old stones.')
      event_bus.emit(:room_objects, text: 'You also see a rock.')
      event_bus.emit(:room_players, text: 'Also here: Bob.')
      expect(room.rows).to all(eq '')

      event_bus.emit(:room_exits, text: 'Obvious paths: north.')

      expect(room.rows).to eq ['[[Town Square]]', 'Old stones.', 'You also see a rock.', 'Also here: Bob.',
                               'Obvious paths: north.', '']
    end

    it 'shows the Lich parts, and clears them' do
      event_bus.emit(:room_title, text: '[Town Square]')
      event_bus.emit(:room_lich_exits, text: 'Room Exits: go gate')
      event_bus.emit(:room_number, text: 'Room Number: 1234')
      event_bus.emit(:room_stringprocs, text: 'StringProcs: climb wall')
      shown = room.rows

      event_bus.emit(:room_supplemental_clear)
      event_bus.emit(:room_render)

      expect(shown.join("\n")).to include('go gate', '1234', 'climb wall')
      expect(room.rows).to eq ['[[Town Square]]', '', '', '', '', '']
    end

    it 'ignores room events when the layout has no room window' do
      load(layout.lines.grep_v(/class='room'/).join, id: 'no-room')

      expect do
        %i[room_title room_desc room_objects room_players room_exits room_lich_exits room_number room_stringprocs]
          .each { |event| event_bus.emit(event, text: 'x') }
        event_bus.emit(:room_supplemental_clear)
        event_bus.emit(:room_render)
      end.not_to raise_error
    end
  end

  describe 'exp and spell window events' do
    it 'files a skill line under the current skill and deletes it again' do
      event_bus.emit(:exp_set_current, skill: 'Evasion')
      stream_text('exp', '         Evasion:  800 12%  [ 5/34]')
      shown = wm.stream['exp'].rows.first

      event_bus.emit(:exp_set_current, skill: 'Evasion')
      event_bus.emit(:exp_delete_skill)

      expect(shown).to eq ' Evasion:  800 12% [ 5/34]'
      expect(wm.stream['exp'].rows).to all(eq '')
    end

    it 'clears the spell window for the next batch' do
      stream_text('percWindow', 'Shadows (2 roisaen)')

      event_bus.emit(:clear_spells)

      expect(wm.stream['percWindow'].rows).to all(eq '')
    end

    it 'ignores exp and spell events when the layout has neither window' do
      load(layout.lines.grep_v(/class='(exp|percWindow)'/).join, id: 'no-exp')

      expect do
        event_bus.emit(:exp_set_current, skill: 'Evasion')
        event_bus.emit(:exp_delete_skill)
        event_bus.emit(:clear_spells)
      end.not_to raise_error
    end
  end

  describe ':launch_url' do
    before do
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:detach)
    end

    it 'shows the URL in the main window for --remote-url and opens nothing' do
      event_bus.emit(:launch_url, url: 'https://www.play.net/dr', remote: true)

      expect(main.rows).to eq [' *', ' * LaunchURL: https://www.play.net/dr', ' *', '']
      expect(Process).not_to have_received(:spawn)
    end

    it 'opens the URL with UrlLauncher otherwise, showing nothing' do
      allow(UrlLauncher).to receive(:open)

      event_bus.emit(:launch_url, url: 'https://www.play.net/dr', remote: false)

      expect(UrlLauncher).to have_received(:open).with('https://www.play.net/dr')
      expect(main.rows).to all(eq '')
    end

    it 'does neither when the layout has no main window' do
      allow(UrlLauncher).to receive(:open)
      load(layout.lines.grep_v(/value='main'/).join, id: 'no-main')

      event_bus.emit(:launch_url, url: 'https://www.play.net/dr', remote: false)

      expect(UrlLauncher).not_to have_received(:open)
    end
  end

  describe ':disconnect' do
    it 'shows the connection-closed banner in the main window' do
      event_bus.emit(:disconnect)

      expect(main.rows).to eq ['*', '* Connection closed', '* Press any key to exit...', '*']
    end
  end

  it 'follows a layout reload to the new windows' do
    old_room = room
    load(<<~XML, id: 'switched')
      <window class='text' top='0' left='0' height='4' width='42' value='main'/>
      <window class='tabbed' top='4' left='0' height='4' width='42' tabs='death'/>
      <window class='room' top='10' left='0' height='4' width='60' value='room'/>
    XML

    stream_text('death', 'Bob died.')
    event_bus.emit(:room_exits, text: 'Obvious paths: none.')

    expect(wm.stream['death']).to be_a TabbedTextWindow
    expect(wm.stream['death'].rows[1]).to eq 'Bob died.'
    # The room window is kept, at its new place
    expect(wm.room['room']).to be old_room
    expect([old_room.begy, old_room.maxy]).to eq [10, 4]
    expect(wm.room['room'].rows.first).to eq 'Obvious paths: none.'
  end
end
