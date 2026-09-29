# frozen_string_literal: true

# Tests .reload typed in the real client (Application#run) on the virtual
# screen: it applies the settings file again, keeps everything as it was
# (and says why in the main window) when the file cannot be loaded, and
# keeps the highlights added with .highlight on top of the file's.

require 'rexml/document'
require_relative '../../lib/shared_state'
require_relative '../../lib/kill_ring'
require_relative '../../lib/string_classification'
require_relative '../../lib/command_buffer'
require_relative '../../lib/window_manager'
require_relative '../../lib/mouse_scroll'
require_relative '../../lib/autocomplete'
require_relative '../../lib/selection_manager'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/application'
require_relative '../../lib/key_codes'
require_relative '../../lib/settings_loader'
require_relative '../support/client_run'

RSpec.describe 'Reloading the settings with .reload' do
  include ClientRun

  let(:settings_path) { File.join(@dir, 'settings.xml') }
  let(:app) do
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: settings_path, host: '127.0.0.1', port: 8000)
  end
  let(:settings) do
    <<~XML
      <settings>
        <highlight fg='ff0000'>goblin</highlight>
        <perc-transform pattern='Osrel Meraud' replace='OM'/>
        <key id='enter' action='send_command'/>
        <key id='ctrl+x' action='previous_command'/>
        <layout id='default'>
          <window class='text' top='0' left='0' height='8' width='200' value='main'/>
          <window class='command' top='9' left='0' height='1' width='200'/>
        </layout>
      </settings>
    XML
  end
  let(:main) { app.window_mgr.stream['main'] }
  let(:command_line) { app.cmd_buffer.window }
  let(:inline) { Application::INLINE_HIGHLIGHT_COLOR }
  # A distinct color pair per color, so the screen shows which color each
  # character was drawn in.
  let(:pairs) { { inline => 1, 'ff0000' => 2, FEEDBACK_COLOR => 3 } }

  around do |example|
    Dir.mktmpdir { |dir| @dir = dir; example.run }
  end

  before do
    allow(ProfanityLog).to receive(:write)
    allow(ProfanitySettings).to receive(:load_mouse_settings).and_return(nil)
    allow(HighlightProcessor).to receive(:get_color_pair_id) { |fg, _bg| pairs.fetch(fg, 0) }
    # Wide enough for a reload error naming the settings file on one row
    allow(Curses).to receive(:cols).and_return(210)
    File.write(settings_path, settings)
  end

  # Keyboard step: replace the settings file with +xml+
  def edit_settings(xml)
    -> { File.write(settings_path, xml) }
  end

  # Keyboard steps: the game sends +line+, and the user waits until the
  # main window shows it.
  def game_says(line)
    [-> { game_server.say(line) }, wait_until { main.rows.any? { |row| row.include?(line) } }]
  end

  # The color of +word+ on the newest main-window row showing +line+: a
  # color from +pairs+, nil when uncolored, or an Array when mixed.
  def color_on_screen(line, word)
    y = main.rows.rindex { |row| row.include?(line) }
    x = main.row(y).index(word)
    colors = (x...(x + word.length)).map { |col| pairs.key(main.attrs_at(y, col) >> 8) }.uniq
    colors.size == 1 ? colors.first : colors
  end

  # BUG FOUND (fixed here): .reload cleared highlights and perc transforms
  # before parsing the file, so a typo in the settings file silently left
  # the user without them; the only trace was a line in the log.
  it 'keeps the settings and says why when the file is malformed' do
    recalled_after_reload = nil
    press_ctrl_x = ["\x18", -> { recalled_after_reload = command_line.row(0) }]

    run_client(keyboard(edit_settings(settings.sub('goblin</highlight>', 'kobold</hilight>')),
                        ".reload\n", *press_ctrl_x))

    expect(HIGHLIGHT).to eq(/goblin/ => ['ff0000', nil, nil])
    expect(PERC_TRANSFORMS).to eq [[/Osrel Meraud/, 'OM']]
    expect(recalled_after_reload).to eq '.reload'
    expect(main.rows.last(2)).to eq ['>.reload',
                                     "* Reload failed, settings unchanged: Missing end tag for 'highlight' (got 'hilight') (line 2)"]
  end

  it 'shows the error in the feedback color' do
    run_client(keyboard(edit_settings('<settings><gag>x</gags></settings>'), ".reload\n"))

    message = "* Reload failed, settings unchanged: Missing end tag for 'gag' (got 'gags') (line 1)"
    expect(main.rows.last).to eq message
    expect(color_on_screen(message, message)).to eq FEEDBACK_COLOR
  end

  # BUG FOUND (fixed here): an empty file was reported as
  # "undefined method 'attributes' for nil".
  it 'keeps the settings and says the file is empty when it is empty' do
    run_client(keyboard(edit_settings(''), ".reload\n"))

    expect(HIGHLIGHT).to eq(/goblin/ => ['ff0000', nil, nil])
    expect(main.rows.last(2)).to eq ['>.reload', "* Reload failed, settings unchanged: Settings file is empty: #{settings_path}"]
  end

  it 'applies a good file without printing anything' do
    run_client(keyboard(edit_settings(settings.sub('goblin', 'kobold')), ".reload\n"))

    expect(HIGHLIGHT).to eq(/kobold/ => ['ff0000', nil, nil])
    expect(main.rows.last).to eq '>.reload'
  end

  it 'applies a changed history size to the command history' do
    recalled = []
    press_ctrl_x = ["\x18", -> { recalled << command_line.row(0) }]

    run_client(keyboard(edit_settings(settings.sub('<settings>', '<settings><history-size>2</history-size>')),
                        ".reload\n", "north\n", "south\n", "east\n", *press_ctrl_x, *press_ctrl_x, *press_ctrl_x))

    expect(recalled).to eq %w[east south south]
  end

  # BUG FOUND (fixed here): .reload replaced the highlights with the
  # file's, so a .highlight added in the session stopped coloring text
  # while .highlight still listed it and .unhighlight claimed to remove it.
  describe 'a highlight added with .highlight' do
    it 'keeps coloring text after a reload' do
      run_client(keyboard(".highlight goblin\n", edit_settings(settings.sub('goblin', 'troll')), ".reload\n",
                          *game_says('A goblin attacks a troll.')))

      expect(color_on_screen('A goblin attacks a troll.', 'goblin')).to eq inline
      expect(color_on_screen('A goblin attacks a troll.', 'troll')).to eq 'ff0000'
    end

    it 'is still listed after a reload' do
      run_client(keyboard(".highlight goblin\n", ".reload\n", ".highlight\n"))

      expect(main.rows.last(3)).to eq ['*', '*   goblin', '*']
    end

    it 'is removed by .unhighlight after a reload' do
      goblin_color_before_unhighlight = nil
      note_color = -> { goblin_color_before_unhighlight = color_on_screen('A goblin arrives.', 'goblin') }

      run_client(keyboard(".highlight goblin\n", edit_settings(settings.sub('goblin', 'troll')), ".reload\n",
                          *game_says('A goblin arrives.'), note_color,
                          ".unhighlight goblin\n", *game_says('A goblin attacks a troll.')))

      expect(goblin_color_before_unhighlight).to eq inline
      expect(main.rows).to include('* Highlight removed: goblin')
      expect(color_on_screen('A goblin attacks a troll.', 'goblin')).to be_nil
      expect(color_on_screen('A goblin attacks a troll.', 'troll')).to eq 'ff0000'
    end

    it 'colors a word the file also highlights the same after a reload as before it' do
      run_client(keyboard(".highlight goblin\n", *game_says('A goblin arrives.'), ".reload\n",
                          *game_says('Another goblin arrives.')))

      expect(color_on_screen('Another goblin arrives.', 'goblin')).to eq color_on_screen('A goblin arrives.', 'goblin')
      expect(HIGHLIGHT.to_a).to eq [[/goblin/, ['ff0000', nil, nil]], [/goblin/i, [inline, nil, nil]]]
    end

    # The server thread reads HIGHLIGHT under SETTINGS_LOCK, so it can only
    # see HIGHLIGHT as it is whenever the lock is released.
    it 'is in the highlights every time the reload releases the settings lock' do
      seen = []
      watch_the_lock = lambda do
        allow(SETTINGS_LOCK).to receive(:synchronize).and_wrap_original do |original, &block|
          original.call(&block).tap { seen << HIGHLIGHT.keys }
        end
      end

      run_client(keyboard(".highlight goblin\n", edit_settings(settings.sub('goblin', 'troll')), watch_the_lock,
                          ".reload\n"))

      expect(seen).not_to be_empty
      expect(seen).to all(include(/goblin/i))
      expect(seen.last).to eq [/troll/, /goblin/i]
    end

    it 'is unchanged by a reload that fails' do
      run_client(keyboard(".highlight goblin\n", edit_settings(settings.sub('goblin</highlight>', 'troll</hilight>')),
                          ".reload\n"))

      expect(HIGHLIGHT.to_a).to eq [[/goblin/, ['ff0000', nil, nil]], [/goblin/i, [inline, nil, nil]]]
    end
  end
end
