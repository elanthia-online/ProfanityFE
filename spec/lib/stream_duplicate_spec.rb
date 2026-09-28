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
require_relative '../../lib/window_manager'

RSpec.describe 'GameTextProcessor main copy of a stream-window line' do
  let(:event_bus) { EventBus.new }
  let(:state) do
    Struct.new(:need_prompt, :prompt_text, :skip_server_time_offset,
               :room_title, :blue_links, :room_window_only, :server_time_offset,
               :remote_url, :log_gags) do
      def update_terminal_title = nil
    end.new(false, '>', true, '', false, false, 0.0, false, false)
  end

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
