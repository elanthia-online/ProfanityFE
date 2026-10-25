# frozen_string_literal: true

# Tests the main-window copy of a stream-window line. The game sends some
# stream text twice: to its stream, then again as the next main-window line
# (DR whispers). ProfanityFE shows it only in the stream's window. Only that
# next main-bound line is a duplicate: a later main line with the same text
# is new game text and must show. The lines are driven through the real
# server loop into real windows built from layout XML; the assertions are on
# what each window shows.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'GameTextProcessor main copy of a stream-window line' do
  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }

  # Build one text window per stream list (each 8 rows high) and a
  # processor that feeds them.
  def build(*windows)
    rows = windows.each_with_index.map do |streams, i|
      "<window class='text' top='#{i * 8}' left='0' height='8' width='100' value='#{streams}'/>"
    end
    LAYOUT['test'] = REXML::Document.new("<layout>#{rows.join}</layout>").root
    @wm = WindowManager.new
    @wm.load_layout('test')
    @wm.subscribe_to_events(event_bus)
    @processor = GameTextProcessor.new(
      window_mgr: @wm, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |*| nil }
    server.define_singleton_method(:flush) { nil }
    allow(IO).to receive(:select).and_return(nil)
    @processor.run(server)
  end

  def shown_in(stream)
    @wm.stream[stream].rows.reject(&:empty?)
  end

  # Real lines from a DR session log: a whisper goes to the whispers stream
  # and then, on the next line, to main.
  let(:whisper) { 'You whisper to Jazriel, "Done!"' }
  let(:whisper_lines) do
    ['<pushStream id="whispers"/><preset id="whisper">You whisper to Jazriel,</preset> "Done!"',
     '<popStream/><preset id="whisper">You whisper to Jazriel,</preset> "Done!"']
  end
  # A real DR combat line: the balance line after a creature's attack
  # (combat stream) and after the player's own attack (main).
  let(:balance) { "[You're nimbly balanced with no advantage.]" }

  it 'suppresses speech by default with no exceptions' do
    build('main', 'speech')
    receive_from_server('<pushStream id="speech"/>Hello.', '<popStream/>', 'Hello.')
    expect(shown_in('speech')).to eq ['Hello.']
    expect(shown_in('main')).to be_empty
  end

  it 'can disable suppression for every stream' do
    CONFIG.duplicate_suppression = { enabled: false, except: [] }
    build('main', 'whispers')
    receive_from_server(*whisper_lines)
    expect(shown_in('main')).to eq [whisper]
  end

  it 'checks the current policy even if reloaded after the stream line' do
    build('main', 'whispers')
    receive_from_server(whisper_lines.first)
    CONFIG.duplicate_suppression = { enabled: false, except: [] }
    receive_from_server(whisper_lines.last)
    expect(shown_in('main')).to eq [whisper]
  end

  it 'never lets a compressed copy suppress the next identical main line' do
    CONFIG.duplicate_suppression = { enabled: true, except: ['compressed'] }
    build('main', 'compressed')
    receive_from_server('Hello.', '<prompt time="1792892704">&gt;</prompt>',
                        '<pushStream id="compressed"/>Hello.', '<popStream id="compressed"/>',
                        'Hello.', '<prompt time="1792892705">&gt;</prompt>')
    expect(shown_in('main').grep('Hello.')).to eq ['Hello.', 'Hello.']
    expect(shown_in('compressed')).to eq ['Hello.']
  end

  it 'keeps exempt speech in a combined chat pane and main' do
    CONFIG.duplicate_suppression = { enabled: true, except: ['speech'] }
    build('main', 'speech,thoughts,lnet')
    speech = %(<preset id='speech'>You <a exist="-11041888" coord="2524,1836" noun="help">say</a></preset>, "Oh sweet.")
    receive_from_server("<pushStream id=\"speech\"/>#{speech}", '<popStream/>', speech,
                        '<prompt time="1792892704">&gt;</prompt>')
    expect(shown_in('speech')).to eq ['You say, "Oh sweet."']
    expect(shown_in('main')).to eq ['You say, "Oh sweet."']
  end

  it 'clears an older stream marker when speech arrives' do
    CONFIG.duplicate_suppression = { enabled: true, except: ['speech'] }
    build('main', 'speech,thoughts')
    receive_from_server('<pushStream id="thoughts"/>Hello.', '<popStream/>',
                        '<pushStream id="speech"/>Hello.', '<popStream/>', 'Hello.')
    expect(shown_in('main')).to eq ['Hello.']
  end

  it 'shows a whisper sent to a stream window and then to main only in the stream window' do
    build('main', 'whispers')

    receive_from_server(*whisper_lines)

    expect(shown_in('whispers')).to eq [whisper]
    expect(shown_in('main')).to be_empty
  end

  it 'drops only the one main copy: the same text sent to main again shows' do
    build('main', 'whispers')

    receive_from_server(*whisper_lines, whisper)

    expect(shown_in('whispers')).to eq [whisper]
    expect(shown_in('main')).to eq [whisper]
  end

  it 'shows a main line matching a stream-window line that arrived before other main lines and prompts' do
    build('main', 'combat')

    receive_from_server(
      '<pushStream id="combat" />* A jeol moradu sidesteps and bashes at you.  You block with a shield.',
      balance,
      '<popStream id="combat" /><prompt time="1787805935">&gt;</prompt>',
      'You angle to the side and retract your arm.',
      'Making an agile leap, you slam your open palm towards a jeol moradu!',
      '',
      balance,
      'Roundtime: 3 sec.',
      '<prompt time="1787805935">R&gt;</prompt>'
    )

    expect(shown_in('combat')).to eq ['* A jeol moradu sidesteps and bashes at you.  You block with a shield.', balance]
    expect(shown_in('main')).to eq [
      '>',
      'You angle to the side and retract your arm.',
      'Making an agile leap, you slam your open palm towards a jeol moradu!',
      balance,
      'Roundtime: 3 sec.',
      'R>'
    ]
  end

  it 'compares only the next main line: after a different main line, a matching one shows' do
    build('main', 'combat')

    receive_from_server("<pushStream id=\"combat\" />#{balance}", '<popStream id="combat" />',
                        'You angle to the side and retract your arm.', balance)

    expect(shown_in('main')).to eq ['You angle to the side and retract your arm.', balance]
  end

  it 'forgets the stream-window line at the next prompt' do
    build('main', 'combat')

    receive_from_server("<pushStream id=\"combat\" />#{balance}",
                        '<popStream id="combat" /><prompt time="1787805935">R&gt;</prompt>',
                        balance)

    expect(shown_in('main')).to eq ['R>', balance]
  end

  it 'counts a window-less stream line shown in main as the next main line' do
    build('main', 'combat')

    receive_from_server("<pushStream id=\"combat\" />#{balance}", '<popStream id="combat" />',
                        '<pushStream id="thoughts"/>Your mind hears Bob thinking, "hi"', '<popStream/>',
                        balance)

    expect(shown_in('main')).to eq ['Your mind hears Bob thinking, "hi"', balance]
  end
end
