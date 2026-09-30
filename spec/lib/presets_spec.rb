# frozen_string_literal: true

# Tests Presets.colors, the one lookup from a preset id to its colors:
# a missing preset, a preset with only a foreground (or only a
# background), defaults, and presets that change after first use, which
# must be seen because the lookup reads PRESET at every call. Then checks
# that color runs built through the real server loop keep their shape at
# the lookup's call sites (no keys when a preset is missing, bg: nil when
# it has only a foreground).

require 'rexml/document'
require 'tmpdir'
require_relative '../../lib/presets'
require_relative '../../lib/key_codes'
require_relative '../../lib/profanity_settings' # enables the settings cache (APP_DIR)
require_relative '../../lib/settings_loader'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe Presets do
  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before { ProfanitySettings.ensure_app_dir }

  # Load a settings file with +body+ through the real SettingsLoader, as at
  # startup (reload: false fills PRESET) or as .reload does.
  def load_settings(body, reload: false)
    path = File.join(@dir, "settings-#{rand(1 << 30)}.xml")
    File.write(path, "<settings>#{body}</settings>")
    expect(SettingsLoader.load(path, {}, {}, proc {}, reload: reload)).to be_nil
  end

  describe '.colors' do
    it 'is nil for an id with no preset' do
      expect(described_class.colors('nosuch')).to be_nil
    end

    it 'is nil for a nil id' do
      expect(described_class.colors(nil)).to be_nil
    end

    it 'is nil for an id whose preset is nil' do
      PRESET['speech'] = nil

      expect(described_class.colors('speech')).to be_nil
    end

    it 'has bg: nil for a preset with only a foreground' do
      load_settings("<preset id='speech' fg='00ff00'/>")

      colors = described_class.colors('speech')

      expect(colors).to eq(fg: '00ff00', bg: nil)
      expect(colors.keys).to eq %i[fg bg]
    end

    it 'has fg: nil for a preset with only a background' do
      load_settings("<preset id='speech' bg='000033'/>")

      expect(described_class.colors('speech')).to eq(fg: nil, bg: '000033')
    end

    it 'reads a one-element preset as foreground only' do
      PRESET['speech'] = ['00ff00']

      expect(described_class.colors('speech')).to eq(fg: '00ff00', bg: nil)
    end

    it 'counts an empty preset as a preset with no colors (not as missing)' do
      PRESET['speech'] = []

      expect(described_class.colors('speech')).to eq(fg: nil, bg: nil)
    end

    it 'uses the default only when the id has no preset' do
      expect(described_class.colors('links', ['5555ff', nil])).to eq(fg: '5555ff', bg: nil)

      PRESET['links'] = [nil, '000000']

      expect(described_class.colors('links', ['5555ff', nil])).to eq(fg: nil, bg: '000000')
    end

    it 'uses the default for an id whose preset is nil' do
      PRESET['links'] = nil

      expect(described_class.colors('links', %w[aaaaaa bbbbbb])).to eq(fg: 'aaaaaa', bg: 'bbbbbb')
    end

    it 'returns a new Hash each time, so changing one changes neither PRESET nor later lookups' do
      PRESET['speech'] = %w[00ff00 000000]

      described_class.colors('speech')[:fg] = 'changed'

      expect(PRESET['speech']).to eq %w[00ff00 000000]
      expect(described_class.colors('speech')).to eq(fg: '00ff00', bg: '000000')
    end

    it 'sees a preset changed by loading settings after its first use' do
      load_settings("<preset id='monsterbold' fg='ff0000'/>")
      expect(described_class.colors(Presets::MONSTERBOLD)).to eq(fg: 'ff0000', bg: nil)

      load_settings("<preset id='monsterbold' fg='00ff00' bg='000000'/>")

      expect(described_class.colors(Presets::MONSTERBOLD)).to eq(fg: '00ff00', bg: '000000')
    end

    it 'sees a preset added and one removed after first use' do
      expect(described_class.colors('speech')).to be_nil
      PRESET['speech'] = ['00ff00', nil]
      expect(described_class.colors('speech')).to eq(fg: '00ff00', bg: nil)

      PRESET.delete('speech')

      expect(described_class.colors('speech')).to be_nil
    end

    it 'keeps the startup presets across .reload, which leaves PRESET alone' do
      load_settings("<preset id='monsterbold' fg='ff0000'/>")
      described_class.colors(Presets::MONSTERBOLD)

      load_settings("<preset id='monsterbold' fg='00ff00'/>", reload: true)

      expect(described_class.colors(Presets::MONSTERBOLD)).to eq(fg: 'ff0000', bg: nil)
    end
  end

  describe 'color runs built from presets' do
    let(:event_bus) { EventBus.new }
    let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
    let(:shown) { [] }

    before { event_bus.on(:stream_text) { |data| shown << data unless data[:text].empty? } }

    # Feed raw server lines through GameTextProcessor#run with only a main window.
    def receive_from_server(*lines)
      wm = Struct.new(:stream, :indicator, :progress, :countdown, :room,
                      :command_window, :command_window_layout).new({ 'main' => Object.new }, {}, {}, {}, {}, nil, nil)
      processor = GameTextProcessor.new(
        window_mgr: wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
        xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
        event_bus: event_bus
      )
      queue = lines.map { |line| "#{line}\r\n" }
      server = Object.new
      server.define_singleton_method(:gets) { queue.shift&.dup }
      allow(IO).to receive(:select).and_return(nil)
      processor.run(server)
    end

    it 'leaves bold text uncolored when there is no monsterbold preset' do
      receive_from_server('You see <pushBold/>a goblin<popBold/>.')

      expect(shown.map { |d| [d[:text], d[:colors]] }).to eq [['You see a goblin.', []]]
    end

    it 'colors bold text with a foreground-only monsterbold preset, keeping bg: nil' do
      load_settings("<preset id='monsterbold' fg='ff0000'/>")

      receive_from_server('You see <pushBold/>a goblin<popBold/>.')

      expect(shown.first[:colors]).to eq [{ start: 8, fg: 'ff0000', bg: nil, end: 16 }]
    end

    it 'colors later bold text with a monsterbold preset changed after the first' do
      load_settings("<preset id='monsterbold' fg='ff0000'/>")
      receive_from_server('You see <pushBold/>a goblin<popBold/>.')

      load_settings("<preset id='monsterbold' fg='00ff00' bg='000000'/>")
      receive_from_server('You see <pushBold/>a troll<popBold/>.')

      expect(shown.map { |d| d[:colors] }).to eq [
        [{ start: 8, fg: 'ff0000', bg: nil, end: 16 }],
        [{ start: 8, fg: '00ff00', bg: '000000', end: 15 }]
      ]
    end

    it "leaves a game preset's text uncolored when the settings have no such preset" do
      receive_from_server("<preset id='speech'>You say, \"Hi.\"</preset>")

      expect(shown.first[:colors]).to eq []
    end

    it "colors a game preset's text with the settings' preset" do
      load_settings("<preset id='speech' fg='00ffff'/>")

      receive_from_server("<preset id='speech'>You say, \"Hi.\"</preset>")

      expect(shown.first[:colors]).to eq [{ start: 0, fg: '00ffff', bg: nil, end: 14 }]
    end

    it "colors a stream falling back to main with that stream's foreground-only preset" do
      load_settings("<preset id='ooc' fg='888888'/>")

      receive_from_server("<pushStream id='ooc'/>[OOC] Bob: hi", "<popStream id='ooc'/>")

      expect(shown.map { |d| [d[:stream], d[:colors]] }).to eq [['main', [{ start: 0, fg: '888888', bg: nil, end: 13 }]]]
    end

    it "adds no run to a stream falling back to main when that stream has no preset" do
      receive_from_server("<pushStream id='ooc'/>[OOC] Bob: hi", "<popStream id='ooc'/>")

      expect(shown.map { |d| [d[:stream], d[:colors]] }).to eq [['main', []]]
    end

    it 'colors a style with only a foreground and leaves an unknown style uncolored' do
      load_settings("<preset id='whisper' fg='ff00ff'/>")

      receive_from_server("<style id='whisper'/>Bob whispers.<style id=''/> <style id='nosuch'/>Plain.<style id=''/>")

      expect(shown.first[:colors]).to eq [{ start: 0, fg: 'ff00ff', bg: nil, end: 13 }]
    end
  end

  describe 'room window sections' do
    # Color pair number per foreground color, so a cell's color can be read
    # back from its attributes.
    let(:pairs) { { 'ffff00' => 1, '00ff00' => 2, LinkExtractor::DEFAULT_LINK_COLOR[0] => 3, 'aa00aa' => 4 } }

    before { allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) } }

    def room_window(attributes = '')
      LAYOUT['test'] = REXML::Document.new(
        "<layout><window class='room' top='0' left='0' height='5' width='80' #{attributes}/></layout>"
      ).root
      window_manager = WindowManager.new
      window_manager.load_layout('test')
      window_manager.room['room']
    end

    # The characters of row +y+ drawn in color pair +pair+.
    def drawn_in(window, y, pair)
      (0...window.maxx).select { |x| window.attrs_at(y, x) >> 8 == pair }.map { |x| window.rows[y][x] }.join
    end

    def show_objects(window, text, creatures)
      window.update_objects(text, creatures: creatures)
      window.update_exits('Obvious paths: north.')
      window.render
    end

    it "doesn't highlight creatures when there is no monsterbold preset" do
      window = room_window
      show_objects(window, 'You also see a rat.', ['a rat'])

      expect(window.rows[0]).to eq 'You also see a rat.'
      expect(drawn_in(window, 0, 1)).to eq ''
    end

    it 'highlights creatures with a foreground-only monsterbold preset' do
      PRESET['monsterbold'] = ['ffff00', nil]
      window = room_window
      show_objects(window, 'You also see a rat.', ['a rat'])

      expect(drawn_in(window, 0, 1)).to eq 'a rat'
    end

    it "uses the creatures-preset attribute's preset, without falling back to monsterbold" do
      PRESET['monsterbold'] = ['ffff00', nil]
      window = room_window("creatures-preset='hunt'")
      show_objects(window, 'You also see a rat.', ['a rat'])
      expect(drawn_in(window, 0, 1)).to eq ''

      PRESET['hunt'] = ['aa00aa', nil]
      show_objects(window, 'You also see a rat.', ['a rat'])

      expect(drawn_in(window, 0, 4)).to eq 'a rat'
    end

    it 'colors the title with the roomName preset only when there is one' do
      window = room_window
      window.update_title('[Town Square]')
      window.update_exits('Obvious paths: north.')
      window.render
      expect(window.rows[0]).to eq '[Town Square]'
      expect(drawn_in(window, 0, 2)).to eq ''

      PRESET['roomName'] = ['00ff00', nil]
      window.render

      expect(drawn_in(window, 0, 2)).to eq '[Town Square]'
    end

    it 'colors exit links with the default link color, or the links preset once there is one' do
      window = room_window
      window.shared_state.blue_links = true
      window.update_exits('Obvious paths: north.', links: [{ start: 15, end: 20, cmd: 'north' }])
      window.render
      expect(drawn_in(window, 0, 3)).to eq 'north'

      PRESET['links'] = ['00ff00', nil]
      window.render

      expect(drawn_in(window, 0, 2)).to eq 'north'
    end
  end
end
