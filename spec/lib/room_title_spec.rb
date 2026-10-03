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
# decoded. The terminal title names the room from the same parse: the
# title row's text without the brackets around the name. The
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
        <window class='indicator' top='12' left='0' height='1' width='60' value='room'/>
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

  # The subtitle of a room component names the terminal title only: the
  # empty room component close that follows it is an empty room title,
  # which hides the title row, as an empty component clears any room
  # section. An empty popStream is not: it ends a room push and sends no
  # title (see "GemStone's empty popStream closing a room push" below).
  title_row_carriers = %i[stream_window room_name room_title_component room_stream].freeze
  carriers = (title_row_carriers + %i[component_subtitle]).freeze

  # What the game sends (decoded) => the title row, and the room as the
  # terminal title names it (the row's text without the name's brackets).
  titles = {
    # Text after the closing bracket is shown as the game sends it.
    '[The Heavens] (**)'         => ['[The Heavens] (**)', 'The Heavens (**)'],
    ' - [The Heavens] (**)'      => ['[The Heavens] (**)', 'The Heavens (**)'],
    '[Town Square] (u230008)'    => ['[Town Square] (u230008)', 'Town Square (u230008)'],
    '[Town Square] (unknown)'    => ['[Town Square] (unknown)', 'Town Square (unknown)'],
    '[A] x'                      => ['[A] x', 'A x'],
    '[A] [B]'                    => ['[A] [B]', 'A [B]'],
    '[[Town Square]]'            => ['[[Town Square]]', '[Town Square]'],
    # Brackets are neither doubled nor lost, on every carrier.
    '[Town Square] (1234)'       => ['[Town Square] (1234)', 'Town Square (1234)'],
    '[Town Square]'              => ['[Town Square]', 'Town Square'],
    # A subtitle's leading " - ", surrounding spaces, and the spaces
    # between the name and what follows it.
    ' - [Town Square] (1234)'    => ['[Town Square] (1234)', 'Town Square (1234)'],
    '   [Town Square] (1234)   ' => ['[Town Square] (1234)', 'Town Square (1234)'],
    '[Town Square]  (1234)'      => ['[Town Square] (1234)', 'Town Square (1234)'],
    # Spaces just inside the brackets are not part of the name.
    '[ Town Square ] (1234)'     => ['[Town Square] (1234)', 'Town Square (1234)'],
    # A title without brackets.
    'Town Square'                => ['[Town Square]', 'Town Square'],
    'Town Square (1234)'         => ['[Town Square] (1234)', 'Town Square (1234)'],
    '(1234)'                     => ['[(1234)]', '(1234)'],
    # Without brackets only a room number is split off; other text in
    # parentheses stays part of the name.
    'The Heavens (**)'           => ['[The Heavens (**)]', 'The Heavens (**)'],
    'Town Square (u230008)'      => ['[Town Square (u230008)]', 'Town Square (u230008)'],
    'Town Square(1234)'          => ['[Town Square(1234)]', 'Town Square(1234)'],
    # Lich's forms and non-ASCII names.
    '[Room - 1234] (230008)'     => ['[Room - 1234] (230008)', 'Room - 1234 (230008)'],
    '[Room - 1234 - (u230008)]'  => ['[Room - 1234 - (u230008)]', 'Room - 1234 - (u230008)'],
    '[Room - (**)]'              => ['[Room - (**)]', 'Room - (**)'],
    '[Café, Ünïcödé] (1234)'     => ['[Café, Ünïcödé] (1234)', 'Café, Ünïcödé (1234)'],
    # XML entities, decoded once.
    '[Smith & Sons] (1234)'      => ['[Smith & Sons] (1234)', 'Smith & Sons (1234)'],
    "[Smith's Forge]"            => ["[Smith's Forge]", "Smith's Forge"],
    '[The "Inn"] (1234)'         => ['[The "Inn"] (1234)', 'The "Inn" (1234)'],
    '[A < B > C]'                => ['[A < B > C]', 'A < B > C'],
    '[Tom &amp; Jerry]'          => ['[Tom &amp; Jerry]', 'Tom &amp; Jerry']
  }.freeze

  carriers.each do |carrier|
    describe "sent as #{carrier}" do
      titles.each do |sent, (expected, room)|
        it "shows #{sent.inspect} as #{expected.inspect}" do
          row = title_row_carriers.include?(carrier) ? expected : nil

          expect(shown(carrier, sent)).to eq(row: row, terminal: "Mahtra [#{room}]")
        end
      end
    end
  end

  # Unbalanced brackets: no real source is known. What the parser makes of
  # them is accepted as it is; this pins it.
  describe 'unbalanced brackets (accepted as the parser gives them)' do
    {
      '[Town Square'   => ['[[Town Square]', '[Town Square'],
      'Town Square]'   => ['[Town Square]]', 'Town Square]'],
      '[Town Square]]' => ['[Town Square]]', 'Town Square]']
    }.each do |sent, (expected, room)|
      carriers.each do |carrier|
        it "shows #{sent.inspect} as #{expected.inspect} when sent as #{carrier}" do
          row = title_row_carriers.include?(carrier) ? expected : nil

          expect(shown(carrier, sent)).to eq(row: row, terminal: "Mahtra [#{room}]")
        end
      end
    end
  end

  # An empty name is no title: no title row, and the terminal title keeps
  # the room it named.
  describe 'a title with an empty name' do
    ['[]', '[] (1234)', ' - [] (1234)', '[ ] (1234)'].each do |sent|
      carriers.each do |carrier|
        it "shows no title row for #{sent.inspect} when sent as #{carrier}" do
          expect(shown(carrier, sent)).to eq(row: nil, terminal: nil)
        end

        it "hides the last room's title row and keeps its terminal title for #{sent.inspect} when sent as #{carrier}" do
          receive_from_server(*lines_for(carrier, '[Old Room] (1)'))

          receive_from_server(*lines_for(carrier, sent))

          expect(row: title_row, terminal: terminal_title).to eq(row: nil, terminal: 'Mahtra [Old Room (1)]')
        end
      end
    end
  end

  # A blank subtitle sends no title and changes nothing; a subtitle that
  # sends only the " - " before a name has an empty name.
  it "keeps the last room's title row for a blank room streamWindow subtitle, and hides it for an empty name" do
    receive_from_server(*lines_for(:stream_window, '[Old Room] (1)'))

    receive_from_server(*lines_for(:stream_window, '  '))
    after_blank = title_row
    receive_from_server(*lines_for(:stream_window, ' - '))

    expect(after_blank).to eq '[Old Room] (1)'
    expect(title_row).to be_nil
    expect(terminal_title).to eq 'Mahtra [Old Room (1)]'
  end

  # A room component that closes itself sends no room text, so nothing
  # clears the title row but its subtitle: a blank subtitle changes nothing,
  # an empty name hides the row.
  it "keeps the last room's title row for a blank self-closing room component subtitle, and hides it for an empty name" do
    exits = %(<component id='room exits'>Obvious paths: <d>north</d>.</component>)
    receive_from_server(*lines_for(:stream_window, '[Old Room] (1)'))

    receive_from_server(%(<component id='room' subtitle="  "/>), exits)
    after_blank = title_row
    receive_from_server(%(<component id='room' subtitle="[] (1234)"/>), exits)

    expect(after_blank).to eq '[Old Room] (1)'
    expect(title_row).to be_nil
    expect(terminal_title).to eq 'Mahtra [Old Room (1)]'
  end

  # An inline room's "Obvious paths:" commits the title the room title
  # component sent, parsed like every other title.
  it 'shows the room title component title when an inline room commits it' do
    receive_from_server("<component id='room title'> - [Town Square]  (1234)</component>", 'Obvious paths: <d>north</d>.')

    expect(row: title_row, terminal: terminal_title).to eq(row: '[Town Square] (1234)', terminal: 'Mahtra [Town Square (1234)]')
  end

  # The room indicator (a layout's indicator window for 'room') shows the
  # streamWindow subtitle's room without its brackets, as before; its
  # entities are decoded like every other room title's.
  it 'names the room on the room indicator without brackets, entities decoded' do
    sent = [' - [Town Square] (1234)', ' - [The Heavens] (**)', ' - [Smith & Sons] (1234)', ' - [A] [B]']
    shown = sent.map do |subtitle|
      receive_from_server(*lines_for(:stream_window, subtitle))
      @wm.indicator['room'].rows.first.rstrip
    end

    expect(shown).to eq ['Town Square (1234)', 'The Heavens (**)', 'Smith & Sons (1234)', 'A [B]']
  end

  it 'names the terminal title from the room title component without a room window' do
    load_layout(room_window: false)

    receive_from_server(*lines_for(:room_title_component, '[Smith & Sons] (1234)'))

    expect(terminal_title).to eq 'Mahtra [Smith & Sons (1234)]'
  end

  it 'shows the same title on a move that sends both the subtitle and the roomName' do
    receive_from_server(*lines_for(:stream_window, " - [Smith's Forge] (1234)"))
    after_subtitle = { row: title_row, terminal: terminal_title }

    receive_from_server(*lines_for(:room_name, "[Smith's Forge] (1234)"))

    expect(after_subtitle).to eq(row: "[Smith's Forge] (1234)", terminal: "Mahtra [Smith's Forge (1234)]")
    expect(title_row).to eq "[Smith's Forge] (1234)"
    expect(terminal_title).to eq "Mahtra [Smith's Forge (1234)]"
  end

  # Two inline views can reach one burst (a lost prompt, or none between
  # them). Each roomName names the terminal title, so each view's must
  # reach the row too, even when it equals the subtitle's title.
  describe 'a second inline view in the burst of a subtitle' do
    it 'shows the room the second view named, as the terminal title does' do
      receive_from_server(*lines_for(:stream_window, ' - [Town Square] (1)'),
                          "<component id='room exits'>Obvious paths: <d>north</d>.<compass></compass></component>",
                          *lines_for(:room_name, '[Deep Wood]'), *lines_for(:room_name, '[Town Square] (1)'),
                          '<prompt time="1">&gt;</prompt>')

      expect(row: title_row, terminal: terminal_title).to eq(row: '[Town Square] (1)', terminal: 'Mahtra [Town Square (1)]')
    end

    it 'hides the row for an empty name after a subtitle with an empty name, keeping the terminal title' do
      receive_from_server(*lines_for(:stream_window, ' - []'), *lines_for(:room_name, '[Deep Wood]'),
                          *lines_for(:room_name, '[]'), '<prompt time="1">&gt;</prompt>')

      expect(row: title_row, terminal: terminal_title).to eq(row: nil, terminal: 'Mahtra [Deep Wood]')
    end
  end

  # GemStone sends every room as a push of the room stream: the room
  # streamWindow's subtitle names the room, then <pushStream id='room'/>,
  # the room compDefs, and <compDef id='sprite'></compDef><popStream
  # id='room'/>. Nothing is sent on the room stream itself, so its empty
  # pop ends the push and sends no title: the title row keeps the room
  # the subtitle named, and agrees with the terminal title (AUDIT §0.2,
  # GS pass 1, F3). The room components' empty closes still clear their
  # sections. Real lines, trimmed from a GemStone log, are in
  # spec/fixtures/room_pipeline/gs_*.xml.
  describe "GemStone's empty popStream closing a room push" do
    # The lines of a fixture in spec/fixtures/room_pipeline.
    def fixture(name)
      File.readlines(File.expand_path("../fixtures/room_pipeline/#{name}.xml", __dir__), chomp: true)
    end

    # The room window's rows that show text, trailing spaces removed.
    def room_rows
      @wm.room['room'].rows.map(&:rstrip).reject(&:empty?)
    end

    # The title row after each of +lines+, fed one at a time.
    def title_rows_after_each(lines)
      lines.map do |line|
        receive_from_server(line)
        title_row
      end
    end

    # A death: the subtitle names "The Darkness Within", no inline view
    # follows, and the next line is the DEAD prompt (GSF-Pickasso
    # 2026-10-02_00-27-14.xml:45-51).
    it 'keeps the title row of a room with no inline view, at the prompt, as the terminal title names it' do
      lines = fixture('gs_death_no_view')
      pop_line = lines.index { |line| line.include?("<popStream id='room'/>") }

      rows = title_rows_after_each(lines)

      expect(lines.last).to include('DEAD&gt;')
      expect(rows[pop_line - 1]).to start_with('[The Darkness Within')
      expect(rows.uniq).to eq [rows[pop_line - 1]]
      expect(terminal_title).to eq "Mahtra [#{state.room_title}]"
      expect(rows.last).to eq "[#{state.room_title}]"
    end

    it 'shows the death room as a whole: title, description and exits' do
      receive_from_server(*fixture('gs_death_no_view'))

      expect(room_rows.first).to start_with('[The Darkness Within')
      expect(room_rows.drop(1).join(' ')).to eq 'A bloody haze obscures the surroundings, spinning in dizzy ' \
                                                'spirals.  All is not right with the world. Obvious paths: none'
    end

    # A move with an inline view (GSF-Pickasso 2026-10-02_00-27-14.xml:686-697,
    # trimmed): the row shows the subtitle's title from the push to the
    # inline commit, which shows the roomName's, as before.
    it 'keeps the title row from the pop to the inline view on a move' do
      lines = fixture('gs_move')
      pop_line = lines.index { |line| line.include?("<popStream id='room'/>") }
      exits_line = lines.index { |line| line.start_with?('Obvious exits:') }

      rows = title_rows_after_each(lines)

      expect(rows[0...exits_line]).to all(start_with('[Walk of the Unliving, Statuary'))
      expect(rows[pop_line]).to eq rows[pop_line - 1]
      expect(rows[exits_line..]).to all(eq('[Walk of the Unliving, Statuary] (4216047)'))
      expect(terminal_title).to eq 'Mahtra [Walk of the Unliving, Statuary (4216047)]'
    end

    it 'shows the next room the push names after a room with no inline view' do
      receive_from_server(*fixture('gs_death_no_view'))
      death_row = title_row

      receive_from_server(*fixture('gs_move'))

      expect(death_row).to start_with('[The Darkness Within')
      expect(row: title_row, terminal: terminal_title)
        .to eq(row: '[Walk of the Unliving, Statuary] (4216047)', terminal: 'Mahtra [Walk of the Unliving, Statuary (4216047)]')
    end

    # The room components' empty closes keep clearing (59328ea): Nodens
    # arrives and leaves in place (GSF-Pickasso 2026-10-02_00-27-14.xml:226-230,
    # after the death room's push).
    it "still clears the room players when an empty room players component follows the push's pop" do
      receive_from_server(*fixture('gs_death_no_view'))
      receive_from_server("<component id='room players'>Also here: <a exist=\"-11219547\" noun=\"Nodens\">Nodens</a></component>")
      with_nodens = room_rows

      receive_from_server("<component id='room players'></component>")

      expect(with_nodens).to include('Also here: Nodens')
      expect(room_rows).not_to include('Also here: Nodens')
      expect(room_rows.first).to start_with('[The Darkness Within')
    end

    it 'keeps the title row for a bare <popStream/> closing the room push' do
      receive_from_server(*lines_for(:stream_window, ' - [Town Square] (1)'),
                          "<clearStream id='room'/><pushStream id='room'/>" \
                          "<compDef id='room exits'>Obvious paths: none</compDef><popStream/>")

      expect(row: title_row, terminal: terminal_title).to eq(row: '[Town Square] (1)', terminal: 'Mahtra [Town Square (1)]')
    end

    # No game sends a subtitle on the pushStream; it shows with the room
    # part that follows (see TagHandlers#handle_stream_open).
    it "keeps a room pushStream's own subtitle in the title row, and its empty name hidden" do
      exits = "<compDef id='room exits'>Obvious paths: none</compDef>"
      receive_from_server(%(<pushStream id='room' subtitle=" - [Town Square] (1)"/>#{exits}<popStream id='room'/>))
      named = { row: title_row, terminal: terminal_title }

      receive_from_server(%(<pushStream id='room' subtitle=" - [] (2)"/>#{exits}<popStream id='room'/>))

      expect(named).to eq(row: '[Town Square] (1)', terminal: 'Mahtra [Town Square (1)]')
      expect(row: title_row, terminal: terminal_title).to eq(row: nil, terminal: 'Mahtra [Town Square (1)]')
    end

    it 'still shows text sent on the room stream itself as the title' do
      receive_from_server(*lines_for(:stream_window, ' - [Old Room] (1)'))

      receive_from_server("<pushStream id='room'/>[Town Square] (2)<popStream id='room'/>")

      expect(row: title_row, terminal: terminal_title).to eq(row: '[Town Square] (2)', terminal: 'Mahtra [Town Square (2)]')
    end

    it 'still hides the title row for an empty room component, which is an empty room title' do
      receive_from_server(*lines_for(:stream_window, ' - [Old Room] (1)'))

      receive_from_server("<component id='room'></component>")

      expect(row: title_row, terminal: terminal_title).to eq(row: nil, terminal: 'Mahtra [Old Room (1)]')
    end

    it "still clears a room component section whose compDef the push's pop closes" do
      receive_from_server(*lines_for(:stream_window, ' - [Old Room] (1)'),
                          "<component id='room players'>Also here: Nodens</component>")
      with_nodens = room_rows

      receive_from_server("<pushStream id='room'/><compDef id='room players'><popStream id='room'/>")

      expect(with_nodens).to include('Also here: Nodens')
      expect(room_rows).to eq ['[Old Room] (1)']
    end

    it 'leaves the terminal title alone without a room window' do
      load_layout(room_window: false)

      receive_from_server(*fixture('gs_death_no_view'))

      expect(terminal_title).to eq "Mahtra [#{state.room_title}]"
      expect(state.room_title).to start_with('The Darkness Within')
    end
  end
end
