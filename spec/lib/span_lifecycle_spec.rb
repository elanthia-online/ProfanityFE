# frozen_string_literal: true

# Characterizes the life of each kind of color span (bold, preset, color,
# style, link) as the parser sees it: how each opens and closes, what it
# colors at a mid-line flush and at the end of a line, and what it leaves
# for the next line. Lines are driven through the real server loop into
# windows built from layout XML; the assertions are on the color runs each
# window is handed with its text.
#
# Some of what is pinned here is odd (an unclosed color colors to the end
# of the line but an unclosed preset colors nothing; a style carries across
# lines and prompts; a link open at a flush is dropped). It is today's
# behaviour, pinned so that a refactor keeps it; changing it is a separate
# decision.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

# Load the REAL GagPatterns module (replaces the spec_helper stub)
original_verbose = $VERBOSE
$VERBOSE = nil
load File.expand_path('../../lib/gag_patterns.rb', __dir__)
$VERBOSE = original_verbose

RSpec.describe 'Color span lifecycle' do
  before { GagPatterns.load_defaults }
  after { GagPatterns.load_defaults }

  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:bold) { { fg: 'ffff00', bg: nil } }
  let(:speech) { { fg: '00ff00', bg: nil } }
  let(:whisper) { { fg: '0000ff', bg: nil } }
  let(:link) { { fg: '00ffff', bg: nil } }

  before do
    PRESET['monsterbold'] = ['ffff00', nil]
    PRESET['speech'] = ['00ff00', nil]
    PRESET['whisper'] = ['0000ff', nil]
    PRESET['links'] = ['00ffff', nil]
    allow(HighlightProcessor).to receive(:get_color_pair_id).and_return(0)
    allow(IO).to receive(:select).and_return(nil)
  end

  # Build main and thoughts windows (and a room window when asked) from
  # layout XML, and a processor that parses into them.
  #
  # @param room_window [Boolean] whether the layout has a room window
  # @return [void]
  def load_layout(room_window: false)
    room = room_window ? "<window class='room' top='12' left='0' height='8' width='80'/>" : ''
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='8' width='80' value='main'/>
        <window class='text' top='8' left='0' height='4' width='80' value='thoughts'/>
        #{room}
      </layout>
    XML
    @wm = WindowManager.new
    @wm.load_layout('test')
    @wm.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would, and return what each window was handed: [stream, text, colors]
  # per piece of text, in order. Lich ends every line with CRLF.
  #
  # @param lines [Array<String>] raw server lines
  # @return [Array<Array(String, String, Array<Hash>)>]
  def receive_from_server(*lines)
    handed = []
    event_bus.on(:stream_text) { |d| handed << [d[:stream], d[:text], d[:colors].map(&:dup)] }
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    @processor.run(server)
    handed
  end

  let(:room_window) { false }

  before { load_layout(room_window: room_window) }

  describe 'at the end of a line' do
    it 'an unclosed color colors to the end of its line, and not the next line' do
      expect(receive_from_server("<color fg='ff0000'>red to end", 'next')).to eq [
        ['main', 'red to end', [{ start: 0, fg: 'ff0000', end: 10 }]],
        ['main', 'next', []]
      ]
    end

    it 'an unclosed preset colors nothing' do
      expect(receive_from_server("<preset id='speech'>green to end", 'next')).to eq [
        ['main', 'green to end', []],
        ['main', 'next', []]
      ]
    end

    it 'an unclosed style colors every later line, across a prompt' do
      expect(receive_from_server("<style id='whisper'/>one", 'two', '<prompt time="1">&gt;</prompt>', 'three')).to eq [
        ['main', 'one', [{ start: 0, **whisper, end: 3 }]],
        ['main', 'two', [{ start: 0, **whisper, end: 3 }]],
        ['main', 'three', [{ start: 0, **whisper, end: 5 }]]
      ]
    end

    it 'unclosed bold colors to the end of its line and stops at a prompt (bold carry-over)' do
      expect(receive_from_server('<pushBold/>a goblin', '<prompt time="1">&gt;</prompt>', 'next')).to eq [
        ['main', 'a goblin', [{ start: 0, **bold, end: 8 }]],
        ['main', 'next', []]
      ]
    end

    it 'an unclosed <b> colors nothing, and is gone on the next line (the bold carry-over reads only pushBold and popBold)' do
      expect(receive_from_server('<b>bold to end', 'x<popBold/>y')).to eq [
        ['main', 'bold to end', []],
        ['main', 'xy', []]
      ]
    end
  end

  describe 'closing' do
    it 'a style closes at an empty style id' do
      expect(receive_from_server("<style id='whisper'/>one<style id=''/> two")).to eq [
        ['main', 'one two', [{ start: 0, **whisper, end: 3 }]]
      ]
    end

    it 'a style closed around no text records no run' do
      expect(receive_from_server("<style id='whisper'/><style id=''/>plain")).to eq [['main', 'plain', []]]
    end

    it 'a style has a single slot: a second style replaces the first' do
      expect(receive_from_server("<style id='whisper'/>ab<style id='speech'/>cd<style id=''/>ef")).to eq [
        ['main', 'abcdef', [{ start: 2, **speech, end: 4 }]]
      ]
    end

    it 'an open style without colors records a colorless run; closed, it records none' do
      expect(receive_from_server("<style id='plain'/>text", "<style id=''/>x<style id='plain'/>ab<style id=''/>cd")).to eq [
        ['main', 'text', [{ start: 0, end: 4 }]],
        ['main', 'xabcd', []]
      ]
    end

    it 'a color records its run even without colors' do
      expect(receive_from_server('<color>ab</color>cd')).to eq [['main', 'abcd', [{ start: 0, end: 2 }]]]
    end

    it 'bold records its run only when monsterbold has a color' do
      PRESET.delete('monsterbold')
      expect(receive_from_server('<pushBold/>ab<popBold/>cd')).to eq [['main', 'abcd', []]]
    end

    it 'bold closed around no text records an empty run' do
      expect(receive_from_server('<pushBold/><popBold/>ab')).to eq [['main', 'ab', [{ start: 0, **bold, end: 0 }]]]
    end

    it '<b> and <pushBold/> are one kind: a <popBold/> closes a <b>' do
      expect(receive_from_server('<b>ab<popBold/>cd')).to eq [['main', 'abcd', [{ start: 0, **bold, end: 2 }]]]
    end

    it 'nested bold closes innermost first' do
      expect(receive_from_server('<pushBold/>a<pushBold/>b<popBold/>c<popBold/>')).to eq [
        ['main', 'abc', [{ start: 1, **bold, end: 2 }, { start: 0, **bold, end: 3 }]]
      ]
    end

    it 'an unmatched closing tag records nothing' do
      state.blue_links = true
      expect(receive_from_server('a</color>b</preset>c<popBold/>d</d>e')).to eq [['main', 'abcde', []]]
    end
  end

  describe 'at a mid-line flush' do
    it 'splits every open bold, preset, style and color, after the runs already closed' do
      line = "<color fg='ff0000'>a</color><pushBold/><preset id='speech'><style id='whisper'/><color fg='abcdef'>b" \
             '<pushStream id="thoughts"/>cd<popStream/>ef'
      expect(receive_from_server(line)).to eq [
        ['main', 'ab', [{ start: 0, fg: 'ff0000', end: 1 }, { start: 1, **bold, end: 2 }, { start: 1, **speech, end: 2 },
                        { start: 1, **whisper, end: 2 }, { start: 1, fg: 'abcdef', end: 2 }]],
        ['thoughts', 'cd', [{ start: 0, **bold, end: 2 }, { start: 0, **speech, end: 2 }, { start: 0, **whisper, end: 2 },
                            { start: 0, fg: 'abcdef', end: 2 }]],
        # Bold is closed by the carry-over; the unclosed preset colors
        # nothing after the last flush.
        ['main', 'ef', [{ start: 0, **bold, end: 2 }, { start: 0, **whisper, end: 2 }, { start: 0, fg: 'abcdef', end: 2 }]]
      ]
    end

    it 'splits a colorless style too' do
      expect(receive_from_server(%(<style id='plain'/><pushStream id="thoughts"/>cd<popStream/>ef))).to eq [
        ['thoughts', 'cd', [{ start: 0, end: 2 }]],
        ['main', 'ef', [{ start: 0, end: 2 }]]
      ]
    end

    it 'drops an open link: neither side is linked' do
      state.blue_links = true
      expect(receive_from_server(%(<d cmd='look'>ab<pushStream id="thoughts"/>cd<popStream/>ef</d>gh))).to eq [
        ['main', 'ab', []],
        ['thoughts', 'cd', []],
        ['main', 'efgh', []]
      ]
    end

    it 'keeps a link closed before the flush' do
      state.blue_links = true
      expect(receive_from_server(%(<d cmd='look'>ab</d><pushStream id="thoughts"/>cd<popStream/>))).to eq [
        ['main', 'ab', [{ start: 0, **link, cmd: 'look', end: 2 }]],
        ['thoughts', 'cd', []]
      ]
    end
  end

  describe 'an empty room component' do
    let(:room_window) { true }

    it 'is handed the runs recorded so far, which stay for the rest of the line' do
      players = []
      event_bus.on(:room_players) { |d| players << d[:links] }
      expect(receive_from_server(%(<component id='room players'><d cmd='look'></d></component>Hello))).to eq [
        ['main', 'Hello', [{ start: 0, **link, cmd: 'look', end: 0 }]]
      ]
      expect(players).to eq [[{ start: 0, end: 0, cmd: 'look' }]]
    end
  end
end
