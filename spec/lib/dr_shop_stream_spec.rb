# frozen_string_literal: true

# Tests where DragonRealms' shop listings go. After SHOP WINDOW the game
# opens a "Shopping" stream window and sends the listing, and every SHOP
# after it, on that stream:
#
#   <streamWindow id='ShopWindow' title='Shopping' location='center' save='true' />
#   <pushStream id="ShopWindow" /> ... <popStream id="ShopWindow" /><exposeStream id='ShopWindow'/>
#
# The game sent the stream as "shopWindow" when shop support was added;
# it sends "ShopWindow" now. Stream ids are matched exactly, so before
# Streams::ALIASES a "shopWindow" tab got nothing, and with no shop window
# the listing was dropped instead of falling back to main.
#
# Every case runs real lines (trimmed from DR-Kvofe/2026-11-10_18-39-20.xml
# lines 3646-3677) through the real server loop (GameTextProcessor#run)
# into windows of the bundled default.xml layout on the virtual screen.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'DragonRealms shop listings (the shop stream)' do
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
  let(:shown) { [] }
  let(:errors) { [] }

  # SHOP WINDOW, then SHOP #47795 (one surface's goods), then a main line.
  let(:shop_session) do
    [
      "<streamWindow id='ShopWindow' title='Shopping' location='center' save='true' />",
      '<pushStream id="ShopWindow" />',
      'The following items contain goods for sale:',
      "  <d cmd='shop #47795'>a grey oak pegboard</d>",
      "  <d cmd='shop #47790'>a haon display case</d>",
      "<popStream id=\"ShopWindow\" /><exposeStream id='ShopWindow'/>",
      '<prompt time="1794289730">&gt;</prompt>',
      '<pushStream id="ShopWindow" />',
      "On the <d cmd='shop'>grey pegboard</d>, you see:",
      "  <d cmd='shop #47800 on #47795'>a rosy pearwood mallet adorned with pearl blossoms and silver bands " \
      'for 1625 copper Kronars</d>',
      '<popStream id="ShopWindow" /><prompt time="1794289733">&gt;</prompt>',
      'You also see a grey canvas tent.',
    ]
  end

  let(:shop_rows) do
    ['The following items contain goods for sale:', '  a grey oak pegboard', '  a haon display case',
     'On the grey pegboard, you see:',
     '  a rosy pearwood mallet adorned with pearl blossoms and silver bands for 1625 copper Kronars']
  end

  before do
    allow(Curses).to receive_messages(lines: 50, cols: 200)
    allow(ProfanityLog).to receive(:write) { |context, message, **| errors << "#{context}: #{message}" }
    GagPatterns.load_defaults
    expect(SettingsLoader.load(default_xml, {}, {}, proc {})).to be_nil
    errors.clear
    event_bus.on(:stream_text) { |data| shown << [data[:stream], data[:text]] unless data[:text].empty? }
  end

  after { PRESET.delete(Streams::SHOP) }

  # Load default.xml with its <layout id='default'> body passed through
  # +edit+ (a copy in a directory of its own), and subscribe the windows.
  def load_layout(&edit)
    if edit
      Dir.mktmpdir('default-shop') do |dir|
        path = File.join(dir, 'default_shop.xml')
        File.write(path, edit.call(File.read(default_xml)))
        expect(SettingsLoader.load(path, {}, {}, proc {})).to be_nil
      end
    end
    wm.load_layout('default')
    wm.subscribe_to_events(event_bus)
    # Loading with no key actions logs every binding; only what the game
    # text logs matters here.
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
    server.define_singleton_method(:puts) { |*| nil }
    server.define_singleton_method(:flush) { nil }
    allow(IO).to receive(:select).and_return(nil)
    processor.run(server)
  end

  # Main with the listing elsewhere: the two prompts with nothing shown
  # between them in main draw one prompt row.
  def main_without_shop
    ['>', 'You also see a grey canvas tent.']
  end

  def tabbed
    wm.stream['main']
  end

  # A tab's lines, oldest first, without the blank rows.
  def tab_rows(name)
    tabbed.tabs.fetch(name).map { |row| row.first.rstrip }.reject(&:empty?).reverse
  end

  describe 'with the bundled tabs (no shop tab)' do
    before { load_layout }

    it 'shows the listing in main, where it was dropped before' do
      receive_from_server(*shop_session)

      expect(tab_rows('main')).to eq [*shop_rows.first(3), '>', *shop_rows.drop(3), '>',
                                      'You also see a grey canvas tent.']
      expect(errors).to be_empty
    end

    it "colours it with a preset named either way, as a stream's preset colours a fallback" do
      [Streams::SHOP, 'ShopWindow'].each do |id|
        PRESET.delete(Streams::SHOP)
        settings = SettingsLoader.parse(REXML::Document.new(
          "<settings><preset id='#{id}' fg='00ffff'/></settings>"
        ).root.then { |root| SettingsLoader.rexml_to_cached(root) }, {}, proc {})
        expect(settings[:presets]).to eq(Streams::SHOP => ['00ffff', nil])
      end
    end
  end

  {
    'shopWindow' => 'the spelling the user guide documents',
    'ShopWindow' => 'the spelling the game sends',
  }.each do |tab, why|
    describe "with a fourth tab named #{tab} (#{why})" do
      before { with_tabs("main,combat,assess,#{tab}") }

      it 'names the tab shopWindow' do
        expect(tabbed.tab_names).to eq %w[main combat assess shopWindow]
        expect(wm.stream[Streams::SHOP]).to equal tabbed
        expect(wm.stream).not_to have_key('ShopWindow')
      end

      it 'shows the listing in that tab only, and the prompts and later text in main' do
        receive_from_server(*shop_session)

        expect(tab_rows('shopWindow')).to eq shop_rows
        expect(tab_rows('main')).to eq main_without_shop
        expect(tab_rows('combat')).to be_empty
        expect(errors).to be_empty
      end

      it 'marks the tab unread while main is shown' do
        receive_from_server(*shop_session)

        expect(tabbed.active_tab).to eq 'main'
        expect(tabbed.instance_variable_get(:@tab_activity)).to include('shopWindow' => true, 'main' => false)
      end
    end
  end

  it 'lists both spellings once: one tab, and both streams reach it' do
    with_tabs('main,shopWindow,ShopWindow')
    expect(tabbed.tab_names).to eq %w[main shopWindow]

    receive_from_server('<pushStream id="shopWindow" />', 'old spelling', '<popStream id="shopWindow" />',
                        '<pushStream id="ShopWindow" />', 'new spelling', '<popStream id="ShopWindow" />')

    expect(tab_rows('shopWindow')).to eq ['old spelling', 'new spelling']
  end

  it 'routes it to a text window whose value names ShopWindow' do
    load_layout do |xml|
      xml.sub('</layout>', "<window class='text' top='0' left='150' height='10' width='50' value='ShopWindow'/></layout>")
    end
    receive_from_server(*shop_session)

    shop = wm.stream[Streams::SHOP]
    expect(shop).to be_a(TextWindow)
    expect(shop).not_to equal tabbed
    expect(shown.select { |stream, _| stream == Streams::SHOP }.map(&:last)).to eq shop_rows
    expect(tab_rows('main')).to eq main_without_shop
  end

  it 'swallows it into a sink whose value names ShopWindow' do
    load_layout { |xml| xml.sub('</layout>', "<window class='sink' value='ShopWindow'/></layout>") }
    receive_from_server(*shop_session)

    expect(wm.stream[Streams::SHOP]).to be_a(SinkWindow)
    expect(tab_rows('main')).to eq main_without_shop
  end

  # A popStream id="ShopWindow" closes the shop push even with an inner
  # push left open after it: the text after the pop, on the same line,
  # goes back to main. Matching the pop's id against the stack only by its
  # raw spelling would close the inner push and leave text in the shop tab.
  it 'closes the shop push by its id when a stream opened inside it was never popped' do
    with_tabs('main,shopWindow')
    receive_from_server('<pushStream id="ShopWindow" />listing<pushStream id="atmospherics"/>' \
                        '<popStream id="ShopWindow" />after the pop')

    expect(tab_rows('shopWindow')).to eq ['listing']
    expect(tab_rows('main')).to eq ['after the pop']
  end

  describe 'Streams.canonical' do
    it 'maps the spelling the game sends now to the shop stream' do
      expect(Streams.canonical('ShopWindow')).to eq Streams::SHOP
    end

    it 'leaves every other id as it is, including other cases of the shop id and of other streams' do
      ['shopWindow', 'shopwindow', 'SHOPWINDOW', 'ShopWindow ', 'Death', 'percWindow', 'main', ''].each do |id|
        expect(Streams.canonical(id)).to equal id
      end
      expect(Streams.canonical(nil)).to be_nil
    end
  end
end
