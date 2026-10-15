# frozen_string_literal: true

require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

# Feeds real server lines through the server loop (GameTextProcessor#run)
# into windows built from layout XML, and reads back what the user sees:
# the room window's rows with the color of each cell and the command a
# click on it sends, the main window's rows, an indicator, the compass and
# the terminal title (SharedState#room_title).
#
# Include it in an example group that defines +state+, the SharedState.
# Colors are read back by name: a cell drawn in a foreground listed in
# {COLOR_NAMES} shows as +{text:name}+ (see {#markup}).
#
# @example
#   load_layout(extra: "<window class='percWindow' ... value='percWindow'/>")
#   receive_from_server(*fixture('room_pipeline', 'dr_rich_move'))
#   expect(room_screen.first).to eq '{[Bosque Deriel, Greengrove] (230006):green}'
module ScreenReplay
  # Color pair number per foreground, so a cell's color can be read back
  # from its attributes.
  PAIRS = { 'ff0000' => 1, '00ff00' => 2, 'ffff00' => 3, '444444' => 4, '5555ff' => 5, '00ffff' => 6,
            'ff00ff' => 7 }.freeze

  # The name each foreground shows as in {#markup}.
  COLOR_NAMES = { 'ff0000' => 'red', '00ff00' => 'green', 'ffff00' => 'yellow', '444444' => 'grey',
                  '5555ff' => 'link', '00ffff' => 'cyan', 'ff00ff' => 'magenta' }.freeze

  # The compass directions, as the compass indicators are named.
  COMPASS = %w[up down out n ne e se s sw w nw].freeze

  # The presets {#stub_screen} sets, and their colors.
  SCREEN_PRESETS = { 'monsterbold' => ['ff0000', nil], 'roomName' => ['00ff00', nil],
                     'links' => ['5555ff', nil] }.freeze

  # Stub the color pairs and the desktop, and give the presets the colors
  # the screens are read in. Call from a +before+ block, and
  # {#restore_screen} from an +after+ block.
  #
  # @return [void]
  def stub_screen
    allow(IO).to receive(:select).and_return(nil)
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| PAIRS.fetch(fg, 0) }
    allow_any_instance_of(BaseWindow).to receive(:get_color_pair_id) { |_window, fg, _bg| PAIRS.fetch(fg, 0) }
    # Nothing here may reach the desktop (a browser or a clipboard tool).
    expect(Process).not_to receive(:spawn)
    @saved_presets = SCREEN_PRESETS.keys.to_h { |id| [id, PRESET[id]] }
    PRESET.merge!(SCREEN_PRESETS)
  end

  # Put back the presets {#stub_screen} changed, so no other spec sees them.
  #
  # @return [void]
  def restore_screen
    @saved_presets.each { |id, colors| colors ? PRESET[id] = colors : PRESET.delete(id) }
  end

  # Build the windows of a layout and a processor that feeds them: a tall
  # main window, a room window (unless +room_window+ is false), the room
  # players indicator and the compass indicators. The windows overlap: each
  # keeps its own rows on the virtual screen.
  #
  # @param room_window [Boolean] whether the layout has a room window
  # @param extra [String] extra <window> elements
  # @return [void]
  def load_layout(room_window: true, extra: '')
    compass = COMPASS.map do |dir|
      "<window class='indicator' top='3' left='0' height='1' width='5' label='#{dir}' value='compass:#{dir}'/>"
    end
    LAYOUT['replay'] = REXML::Document.new(<<~XML).root
      <layout>
        <window class='text' top='0' left='0' height='60' width='100' value='main'/>
        #{"<window class='room' top='1' left='0' height='30' width='100' value='room'/>" if room_window}
        <window class='indicator' top='2' left='0' height='1' width='60' label=' ' value='room players' fg='444444,ffff00'/>
        #{compass.join("\n")}
        #{extra}
      </layout>
    XML
    event_bus = EventBus.new
    @window_manager = WindowManager.new(shared_state: state)
    @window_manager.load_layout('replay')
    @window_manager.subscribe_to_events(event_bus)
    @lit = []
    event_bus.on(:compass_update) { |data| @lit = data[:dirs] }
    @processor = GameTextProcessor.new(
      window_mgr: @window_manager, shared_state: state, cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus
    )
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket
  # would (Lich ends every line with CRLF).
  #
  # @param lines [Array<String>] server lines, without line endings
  # @return [void]
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    server.define_singleton_method(:puts) { |_command| nil }
    server.define_singleton_method(:flush) { nil }
    @processor.run(server)
  end

  # The lines of a fixture, spec/fixtures/DIR/NAME.xml.
  #
  # @param dir [String] the fixture directory
  # @param name [String] the fixture name, without .xml
  # @return [Array<String>]
  def fixture(dir, name)
    File.readlines(File.expand_path("../fixtures/#{dir}/#{name}.xml", __dir__), chomp: true)
  end

  # The room window's rows as the user sees them, blank rows left out, in
  # {#markup}'s notation.
  #
  # @return [Array<String>]
  def room_screen
    window_rows(@window_manager.room['room']) { |room, y, x| room.link_cmd_at(y, x) }
  end

  # The main window's rows in {#markup}'s notation (links aren't
  # clickable in main, so no commands), blank rows left out.
  #
  # @return [Array<String>]
  def main_screen
    window_rows(@window_manager.stream['main'])
  end

  # The main window's rows as plain text, blank rows and trailing blanks
  # left out.
  #
  # @return [Array<String>]
  def main_rows = @window_manager.stream['main'].rows.map(&:rstrip).reject(&:empty?)

  # A text window's rows as plain text, blank rows left out.
  #
  # @param stream [String] the window's stream
  # @return [Array<String>]
  def window_text(stream) = @window_manager.stream[stream].rows.map(&:rstrip).reject(&:empty?)

  # The room players indicator's label.
  #
  # @return [String]
  def indicator = @window_manager.indicator['room players'].rows.first.rstrip

  # The compass directions the last compass update lit.
  #
  # @return [Array<String>]
  def compass_lit = @lit

  private

  # A window's rows in {#markup}'s notation, blank rows left out.
  #
  # @param window [BaseWindow] the window
  # @yieldparam window [BaseWindow] the window
  # @yieldparam y [Integer] a row
  # @yieldparam x [Integer] a column
  # @yieldreturn [String, nil] the command a click on the cell sends
  # @return [Array<String>]
  def window_rows(window)
    window.rows.each_index.filter_map do |y|
      next if window.row(y).strip.empty?

      cell = ->(x) { [COLOR_NAMES[PAIRS.key(window.attrs_at(y, x) >> 8)], (yield(window, y, x) if block_given?)] }
      runs = window.row(y).rstrip.each_char.with_index.chunk_while { |(_, a), (_, b)| cell.(a) == cell.(b) }
      runs.map { |chars| markup(chars.map(&:first).join, *cell.(chars.first.last)) }.join
    end
  end

  # One run of equal cells: "{text:color}" where the cells are drawn in a
  # color, "[text](cmd)" where a click sends +cmd+ and the cells are drawn
  # in the link color ("[text:color](cmd)" in another color).
  #
  # @param text [String] the run's text
  # @param color [String, nil] its color's name
  # @param cmd [String, nil] the command a click on it sends
  # @return [String]
  def markup(text, color, cmd)
    if cmd
      color == 'link' ? "[#{text}](#{cmd})" : "[#{text}:#{color}](#{cmd})"
    elsif color
      "{#{text}:#{color}}"
    else
      text
    end
  end
end
