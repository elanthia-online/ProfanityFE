# frozen_string_literal: true

# Stream ids with characters outside ASCII. The line from the game
# connection is made ASCII before anything reads it (ServerText), and an id
# is written losslessly there (ServerText.identity: % and each character
# outside ASCII as %XX). A layout, a tab, a sink, a preset and a
# suppression exception naming that stream must reach the same key, and
# two names that differed must not.
#
# Every case runs lines through the real server loop
# (GameTextProcessor#run) into windows of the bundled default.xml layout,
# edited as each case says, on the virtual screen.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'
require_relative '../../lib/server_text'
require_relative '../../lib/windows/effects_window'

RSpec.describe 'Stream ids outside ASCII' do
  let(:default_xml) { File.expand_path('../../templates/default.xml', __dir__) }
  let(:event_bus) { EventBus.new }
  let(:wm) { WindowManager.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: wm,
      shared_state: state,
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus,
      game_rules: Games.rules_for('DR')
    )
  end
  let(:errors) { [] }
  # "cafe" with an acute e (the source is ASCII), and the ASCII name that
  # spells its %XX form.
  let(:cafe) { "caf#{[0xE9].pack('U')}" }
  let(:cafe_spelled) { 'caf%C3%A9' }

  before do
    allow(Curses).to receive_messages(lines: 50, cols: 200)
    allow(ProfanityLog).to receive(:write) { |context, message, **| errors << "#{context}: #{message}" }
    GagPatterns.load_defaults
  end

  # Load default.xml with its text passed through +edit+, and subscribe
  # the windows.
  def load_layout(&edit)
    Dir.mktmpdir('stream-identity') do |dir|
      path = File.join(dir, 'settings.xml')
      File.write(path, edit.call(File.read(default_xml)))
      expect(SettingsLoader.load(path, {}, {}, proc {})).to be_nil
    end
    wm.load_layout('default')
    wm.subscribe_to_events(event_bus)
    errors.clear
  end

  def with_tabs(tabs)
    load_layout { |xml| xml.sub("tabs='main,combat,assess'", "tabs='#{tabs}'") }
  end

  def receive_from_server(*lines)
    allow(processor).to receive(:show_disconnect_message)
    allow(processor).to receive(:exit)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    allow(IO).to receive(:select).and_return(nil)
    processor.run(server)
  end

  # A line of text on +stream+, as a script sends it.
  def on_stream(stream, text)
    %(<pushStream id="#{stream}"/>#{text}<popStream/>)
  end

  # A tab's lines, oldest first, without the blank rows.
  def tab_rows(name)
    wm.stream['main'].tabs.fetch(name).map { |row| row.first.rstrip }.reject(&:empty?).reverse
  end

  it 'shows the stream in the tab that names it' do
    with_tabs("main,combat,assess,#{cafe}")

    receive_from_server(on_stream(cafe, 'Hello from the cafe.'), 'Back in main.')

    expect(tab_rows(ServerText.identity(cafe))).to eq ['Hello from the cafe.']
    expect(tab_rows('main')).to eq ['Back in main.']
    expect(errors).to be_empty
  end

  it 'keeps apart a tab named with characters outside ASCII and one named with their %XX form' do
    with_tabs("main,#{cafe},#{cafe_spelled}")

    receive_from_server(on_stream(cafe, 'One.'), on_stream(cafe_spelled, 'Two.'))

    expect(tab_rows(ServerText.identity(cafe))).to eq ['One.']
    expect(tab_rows(ServerText.identity(cafe_spelled))).to eq ['Two.']
  end

  # A stream with no window is dropped, so main alone can't tell a sink
  # that names it from none: the sink must be the window the stream's key
  # finds.
  it 'registers a sink that names the stream under the key the stream arrives with' do
    load_layout { |xml| xml.sub("<layout id='default'>", "<layout id='default'>\n<window class='sink' value='#{cafe}'/>") }
    incoming = XmlTokenizer.attrs(ServerText.normalize!(%(<pushStream id="#{cafe}"/>).b))['id']

    receive_from_server(on_stream(cafe, 'Not shown.'), 'Shown.')

    expect(wm.stream[incoming]).to be_a(SinkWindow)
    expect(tab_rows('main')).to eq ['Shown.']
  end

  it 'keys a preset, a suppression exception and the notification stream as the game connection keys the stream' do
    settings = SettingsLoader.parse(REXML::Document.new(<<~XML).root.then { |root| SettingsLoader.rexml_to_cached(root) }, {}, proc {})
      <settings>
        <preset id='#{cafe}' fg='00ffff'/>
        <duplicate-suppression enabled='on' except='#{cafe},#{cafe_spelled}'/>
        <notification-stream>#{cafe}</notification-stream>
      </settings>
    XML
    incoming = XmlTokenizer.attrs(ServerText.normalize!(%(<pushStream id="#{cafe}"/>).b))['id']

    expect(settings[:presets].keys).to eq [incoming]
    expect(settings[:duplicate_suppression][:except]).to eq [incoming, ServerText.identity(cafe_spelled)]
    expect(settings[:notification_stream]).to eq incoming
    expect(incoming).not_to eq ServerText.identity(cafe_spelled)
  end

  # The key a preset or an exact effectColor id from the connection gets.
  def incoming_id(id) = XmlTokenizer.attrs(ServerText.normalize!(%(<preset id="#{id}"/>).b))['id']

  # A preset is keyed as the connection keys it, so the room window's
  # references to presets must be too.
  it 'colors the room title with a preset the room window names, even one with a %' do
    load_layout do |xml|
      xml.sub("<layout id='default'>", "<preset id='50%' fg='ff0000'/>\n<layout id='default'>")
         .sub("title-preset='roomName'", "title-preset='50%' desc-preset='#{cafe}'")
         .sub("<layout id='default'>", "<preset id='#{cafe}' fg='00ff00'/>\n<layout id='default'>")
    end
    room = wm.room[Streams::ROOM]

    expect(Presets.colors(room.title_preset)).to eq(fg: 'ff0000', bg: nil)
    expect(Presets.colors(room.desc_preset)).to eq(fg: '00ff00', bg: nil)
  end

  # An exact effectColor id matches the timer the connection keys the same
  # way, and not one whose id it spells.
  it "matches an exact effectColor id against the connection's key for that id" do
    expect(EffectsWindow::ColorRule.new(id: '50%').match?(incoming_id('50%'), nil)).to be true
    expect(EffectsWindow::ColorRule.new(id: cafe).match?(incoming_id(cafe), nil)).to be true
    expect(EffectsWindow::ColorRule.new(id: cafe_spelled).match?(incoming_id(cafe), nil)).to be false
  end
end
