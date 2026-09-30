# frozen_string_literal: true

# Tests the room title the user sees, the room window's title row and the
# terminal title, for every way the game sends a room's title:
#
# - the subtitle of <streamWindow id='room'>,
# - the subtitle of <pushStream id='room'> / <component id='room'>,
# - the text of a roomName style (committed at "Obvious paths:"),
# - the text of the <component id='room title'>, or of the room stream.
#
# All of them parse the title the same way (RoomTitle): the name in the
# first brackets and whatever the game sent after them, XML entities
# decoded, and the terminal title shows exactly the title row's text. The
# lines are driven through the real server loop into windows built from
# layout XML.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'Room title' do
  let(:event_bus) { EventBus.new }
  let(:state) do
    SharedState.new.tap do |s|
      s.skip_server_time_offset = true
      s.char_name = 'Mahtra'
    end
  end
  # Everything written to the terminal (the title escapes).
  let(:terminal) { [] }

  before do
    allow(IO).to receive(:select).and_return(nil)
    allow(Process).to receive(:setproctitle)
    allow($stdout).to receive(:write) { |text| terminal << text }
    allow($stdout).to receive(:flush)
    load_layout
  end

  # Build the windows from layout XML and a processor that feeds them.
  #
  # @param room_window [Boolean] whether the layout has a room window
  def load_layout(room_window: true)
    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='6' width='60' value='main'/>
        #{"<window class='room' top='6' left='0' height='6' width='60' value='room'/>" if room_window}
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

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    @processor.run(server)
  end

  # The text as the game sends it: XML-escaped.
  def escaped(text)
    text.gsub('&', '&amp;').gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;').gsub("'", '&apos;')
  end

  # The server lines that send +title+ (the decoded text) as a room's title
  # the way +carrier+ does.
  def lines_for(carrier, title)
    case carrier
    when :stream_window
      [%(<streamWindow id='room' title='Room' subtitle="#{escaped(title)}" location='center' target='drop' ifClosed='' resident='true'/>)]
    when :component_subtitle
      [%(<component id='room' subtitle="#{escaped(title)}"></component>)]
    when :room_name
      ["<resource picture=\"0\"/><style id=\"roomName\" />#{escaped(title)}", '<style id=""/>  ', 'Obvious paths: <d>north</d>.']
    when :room_title_component
      ["<component id='room title'>#{escaped(title)}</component>"]
    when :room_stream
      ["<pushStream id='room'/>#{escaped(title)}<popStream/>"]
    end
  end

  # The room window's title row: its first row, unless that is the exits.
  def title_row
    first = @wm.room['room'].rows.map(&:rstrip).reject(&:empty?).first
    first unless first.nil? || first.start_with?('Obvious')
  end

  # The terminal title last written (OSC 0), or nil if none was.
  def terminal_title
    terminal.join.scan(/\e\]0;(.*?)\a/).flatten.last
  end

  # What +carrier+ shows for +title+ on a fresh screen.
  def shown(carrier, title)
    receive_from_server(*lines_for(carrier, title))
    { row: title_row, terminal: terminal_title }
  end

  # The subtitle of a room pushStream or component names the terminal
  # title only: the empty room component (or popStream) that follows it
  # clears the title row, as it clears any room section.
  title_row_carriers = %i[stream_window room_name room_title_component room_stream].freeze
  carriers = (title_row_carriers + %i[component_subtitle]).freeze

  # What the game sends (decoded) => the title row, which the terminal
  # title shows too.
  titles = {
    # Text after the closing bracket is shown as the game sends it.
    '[The Heavens] (**)'         => '[The Heavens] (**)',
    ' - [The Heavens] (**)'      => '[The Heavens] (**)',
    '[Town Square] (u230008)'    => '[Town Square] (u230008)',
    '[Town Square] (unknown)'    => '[Town Square] (unknown)',
    '[A] x'                      => '[A] x',
    '[A] [B]'                    => '[A] [B]',
    '[[Town Square]]'            => '[[Town Square]]',
    # Brackets are neither doubled nor lost, on every carrier.
    '[Town Square] (1234)'       => '[Town Square] (1234)',
    '[Town Square]'              => '[Town Square]',
    # A subtitle's leading " - ", surrounding spaces, and the spaces
    # between the name and what follows it.
    ' - [Town Square] (1234)'    => '[Town Square] (1234)',
    '   [Town Square] (1234)   ' => '[Town Square] (1234)',
    '[Town Square]  (1234)'      => '[Town Square] (1234)',
    # A title without brackets.
    'Town Square'                => '[Town Square]',
    'Town Square (1234)'         => '[Town Square] (1234)',
    '(1234)'                     => '[(1234)]',
    # Lich's forms and non-ASCII names.
    '[Room - 1234] (230008)'     => '[Room - 1234] (230008)',
    '[Room - 1234 - (u230008)]'  => '[Room - 1234 - (u230008)]',
    '[Room - (**)]'              => '[Room - (**)]',
    '[Café, Ünïcödé] (1234)'     => '[Café, Ünïcödé] (1234)',
    # XML entities, decoded once.
    '[Smith & Sons] (1234)'      => '[Smith & Sons] (1234)',
    "[Smith's Forge]"            => "[Smith's Forge]",
    '[The "Inn"] (1234)'         => '[The "Inn"] (1234)',
    '[A < B > C]'                => '[A < B > C]',
    '[Tom &amp; Jerry]'          => '[Tom &amp; Jerry]'
  }.freeze

  carriers.each do |carrier|
    describe "sent as #{carrier}" do
      titles.each do |sent, expected|
        it "shows #{sent.inspect} as #{expected.inspect}" do
          row = title_row_carriers.include?(carrier) ? expected : nil

          expect(shown(carrier, sent)).to eq(row: row, terminal: "Mahtra [#{expected}]")
        end
      end
    end
  end

  # Unbalanced brackets: no real source is known. What the parser makes of
  # them is accepted as it is; this pins it.
  describe 'unbalanced brackets (accepted as the parser gives them)' do
    {
      '[Town Square'   => '[[Town Square]',
      'Town Square]'   => '[Town Square]]',
      '[Town Square]]' => '[Town Square]]'
    }.each do |sent, expected|
      carriers.each do |carrier|
        it "shows #{sent.inspect} as #{expected.inspect} when sent as #{carrier}" do
          row = title_row_carriers.include?(carrier) ? expected : nil

          expect(shown(carrier, sent)).to eq(row: row, terminal: "Mahtra [#{expected}]")
        end
      end
    end
  end

  # An empty name is no title: no title row, and the terminal title keeps
  # the room it named.
  describe 'a title with an empty name' do
    ['[]', '[] (1234)', ' - [] (1234)'].each do |sent|
      carriers.each do |carrier|
        it "shows no title row for #{sent.inspect} when sent as #{carrier}" do
          expect(shown(carrier, sent)).to eq(row: nil, terminal: nil)
        end

        it "keeps the terminal title for #{sent.inspect} when sent as #{carrier}" do
          receive_from_server(*lines_for(carrier, '[Old Room] (1)'))

          receive_from_server(*lines_for(carrier, sent))

          expect(terminal_title).to eq 'Mahtra [[Old Room] (1)]'
        end
      end

      %i[room_name room_title_component room_stream].each do |carrier|
        it "hides the last room's title row for #{sent.inspect} when sent as #{carrier}" do
          receive_from_server(*lines_for(carrier, '[Old Room] (1)'))

          receive_from_server(*lines_for(carrier, sent))

          expect(title_row).to be_nil
        end
      end
    end
  end

  it 'names the terminal title from the room title component without a room window' do
    load_layout(room_window: false)

    receive_from_server(*lines_for(:room_title_component, '[Smith & Sons] (1234)'))

    expect(terminal_title).to eq 'Mahtra [[Smith & Sons] (1234)]'
  end

  it 'shows the same title on a move that sends both the subtitle and the roomName' do
    receive_from_server(*lines_for(:stream_window, " - [Smith's Forge] (1234)"))
    after_subtitle = { row: title_row, terminal: terminal_title }

    receive_from_server(*lines_for(:room_name, "[Smith's Forge] (1234)"))

    expect(after_subtitle).to eq(row: "[Smith's Forge] (1234)", terminal: "Mahtra [[Smith's Forge] (1234)]")
    expect(title_row).to eq "[Smith's Forge] (1234)"
    expect(terminal_title).to eq "Mahtra [[Smith's Forge] (1234)]"
  end
end
