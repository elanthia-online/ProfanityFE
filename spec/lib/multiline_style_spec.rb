# frozen_string_literal: true

# Tests a style (<style id='...'/> ... <style id=''/>) that stays open past
# the end of its line. It follows multi-line bold: it colors the lines after
# it until it closes or a prompt ends it, and a gagged line still opens and
# closes it. The lines are driven through the real server loop into a real
# window built from layout XML, and the assertions are on what the window
# shows.

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

RSpec.describe 'Styles across lines' do
  before { GagPatterns.load_defaults }
  after { GagPatterns.load_defaults }

  let(:event_bus) { EventBus.new }
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  # Color pair number per foreground color, so a cell's color can be read
  # back from its attributes.
  let(:pairs) { { 'ff00ff' => 1, '0000ff' => 2 } }

  before do
    PRESET['roomName'] = ['ff00ff', nil]
    PRESET['whisper'] = ['0000ff', nil]
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    allow(IO).to receive(:select).and_return(nil)

    LAYOUT['test'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='10' width='80' value='main'/>
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
  # would. Lich ends every line with CRLF. The first prompt sends a look.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |*| nil }
    server.define_singleton_method(:flush) { nil }
    @processor.run(server)
  end

  # Color of each character of +text+ where main shows it: a color code,
  # nil when uncolored, or an Array when mixed.
  def color_on_screen(text)
    win = @wm.stream['main']
    y = win.rows.index { |row| row.include?(text) }
    raise "#{text.inspect} not on screen: #{win.rows.reject(&:empty?).inspect}" unless y

    x = win.row(y).index(text)
    colors = (x...(x + text.length)).map { |col| pairs.key(win.attrs_at(y, col) >> 8) }.uniq
    colors.size == 1 ? colors.first : colors
  end

  describe 'at a prompt' do
    it 'carries a style to the following lines, and a prompt ends it' do
      receive_from_server('<style id="whisper"/>Bob whispers, "Meet me',
                          'at the gate."',
                          '<prompt time="1790395961">&gt;</prompt>',
                          'You wave.')

      expect(color_on_screen('Bob whispers, "Meet me')).to eq '0000ff'
      expect(color_on_screen('at the gate."')).to eq '0000ff'
      expect(color_on_screen('You wave.')).to be_nil
    end

    it "colors the rest of the prompt's line, as carried bold does" do
      receive_from_server('<style id="whisper"/>Bob whispers,',
                          '<prompt time="1790395961">&gt;</prompt>"Meet me."',
                          'You wave.')

      expect(color_on_screen('"Meet me."')).to eq '0000ff'
      expect(color_on_screen('You wave.')).to be_nil
    end
  end

  describe 'on a gagged line' do
    # A room title leaves roomName open to the start of the next line; here
    # the user gags that line.
    it 'still closes the style when a general gag drops the line holding <style id=""/>' do
      GagPatterns.add_general_pattern('You also see .*rat')

      receive_from_server('<style id="roomName" />[Town Square]',
                          '<style id=""/>  You also see a rat.',
                          'Obvious exits: north.',
                          '<prompt time="1790395961">&gt;</prompt>',
                          'Bob waves.')

      expect(color_on_screen('[Town Square]')).to eq 'ff00ff'
      expect(color_on_screen('Obvious exits: north.')).to be_nil
      expect(color_on_screen('Bob waves.')).to be_nil
    end

    it 'still closes the style when a multi-line gag block spans the <style id=""/>' do
      GagPatterns.add_multiline_gag('Knowledge from your sanowret crystal', '^End of knowledge\.')

      receive_from_server('<style id="roomName" />[Town Square]',
                          '<style id=""/>Knowledge from your sanowret crystal about Arcana rings clear in your mind:',
                          'Mana is the basic building block of magic.',
                          'End of knowledge.',
                          'You wave.')

      expect(color_on_screen('You wave.')).to be_nil
    end

    it 'still opens the style for the lines after it' do
      GagPatterns.add_general_pattern('Bob whispers')

      receive_from_server('<style id="whisper"/>Bob whispers, "Meet me',
                          'at the gate."<style id=""/> Bob leaves.')

      expect(color_on_screen('at the gate."')).to eq '0000ff'
      expect(color_on_screen(' Bob leaves.')).to be_nil
    end

    it 'does not take the next line as the room title when the gagged line opened roomName' do
      GagPatterns.add_general_pattern('Secret Room')

      receive_from_server('<style id="roomName" />[Secret Room]',
                          'Bob waves.')

      expect(state.room_title).to eq ''
      expect(color_on_screen('Bob waves.')).to eq 'ff00ff'
    end
  end
end
