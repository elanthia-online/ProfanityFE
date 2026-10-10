# frozen_string_literal: true

# Tests how the effects window is wired into the running client, through the
# real Application on the virtual screen: the input loop ticking the
# countdowns, the .effects <category> dot-command, the one-time
# `spell active` request, the categories being remembered in settings.json
# between sessions, and the eleazzar.xml template carrying the window. spec_helper points HOME at a throwaway
# directory, so settings.json is the real file there.

require 'json'
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

RSpec.describe 'The effects window in the running client' do
  let(:server) { StringIO.new }
  let(:settings_file) { ProfanitySettings.file('settings.json') }
  let(:now) { [1_000_000.0] }
  let(:layout) do
    <<~XML
      <layout>
        <window class='text' top='0' left='0' height='6' width='100' value='main'/>
        <window class='effects' top='0' left='101' height='6' width='30'/>
        <window class='indicator' top='9' left='0' height='1' width='1' value='prompt' label='&gt;'/>
        <window class='command' top='9' left='1' height='1' width='20'/>
      </layout>
    XML
  end
  let(:app) { build_app }
  let(:main) { app.window_mgr.stream['main'] }
  let(:effects) { app.window_mgr.effects['effects'] }
  let(:cmd_window) { app.cmd_buffer.window }

  def build_app
    Application.new({ char: nil, no_status: true, links: false, room_window_only: false },
                    settings_file: File.join(SPEC_HOME, 'settings.xml'), host: '127.0.0.1', port: 8000)
  end

  # Build an app and its layout the way the client does at startup.
  def start(app)
    app.send(:apply_layout, 'effects_spec')
    app.connection.attach(server)
    app
  end

  # An effect as the backend sends it; +seconds+ is the time left now.
  def effect(name, seconds)
    { id: name, name: name, percent: 50, end_time: now[0] + seconds }
  end

  def saved
    JSON.parse(File.read(settings_file))
  end

  def shown
    main.rows.reject { |row| row.strip.empty? }
  end

  before do
    ProfanitySettings.ensure_app_dir
    allow(ProfanityLog).to receive(:write)
    allow(Curses).to receive(:mousemask)
    allow(Curses).to receive(:cols).and_return(140)
    allow(Time).to receive(:now) { Time.at(now[0]) }
    stub_const('Curses::ALL_MOUSE_EVENTS', Curses::REPORT_MOUSE_POSITION - 1)
    LAYOUT['effects_spec'] = REXML::Document.new(layout).root
  end

  after { Dir.glob(File.join(ProfanitySettings::APP_DIR, 'settings.json*')).each { |f| File.delete(f) } }

  describe 'ticking' do
    before { start(app) }

    it 'tick_effects is true when an effects window redrew, then false until the clock moves on' do
      effects.apply_effects(:spells, [effect('Strength', 100)])
      now[0] += 5

      expect(app.send(:tick_effects)).to be true
      expect(effects.rows.grep(/\AStrength.*00:01:35\z/)).not_to be_empty
      expect(app.send(:tick_effects)).to be false
    end

    it 'tick_effects ticks every effects window and is true if any changed' do
      LAYOUT['two_effects'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='effects' top='0' left='0' height='6' width='30' value='first'/>
          <window class='effects' top='0' left='31' height='6' width='30' value='second' categories='buffs'/>
          <window class='command' top='9' left='1' height='1' width='20'/>
        </layout>
      XML
      app.send(:apply_layout, 'two_effects')
      app.window_mgr.effects['first'].apply_effects(:spells, [effect('Strength', 100)])
      app.window_mgr.effects['second'].apply_effects(:buffs, [effect('Haste', 100)])
      now[0] += 1

      expect(app.window_mgr.effects.each_value.map(&:tick).count(true)).to eq 2
      now[0] += 1
      expect(app.send(:tick_effects)).to be true
    end

    it 'tick_effects is false without an effects window' do
      LAYOUT['no_effects'] = REXML::Document.new("<layout><window class='command' top='9' left='1' height='1' width='20'/></layout>").root
      app.send(:apply_layout, 'no_effects')

      expect(app.send(:tick_effects)).to be false
    end

    describe 'the input loop' do
      # Run the real input loop for one tick with no key pressed, then end it
      # as Ctrl+C would.
      def run_input_loop_for_one_tick
        allow(IO).to receive(:select).and_return(nil)
        keys = [nil]
        %i[get_char getch].each do |reader|
          cmd_window.define_singleton_method(reader) { keys.empty? ? raise(Interrupt) : keys.shift }
        end
        app.send(:input_loop)
      end

      before do
        effects.apply_effects(:spells, [effect('Strength', 100)])
        allow(app.cmd_buffer).to receive(:flush_screen).and_call_original
      end

      it 'redraws the countdowns and flushes the screen when an effect changed' do
        now[0] += 5

        run_input_loop_for_one_tick

        expect(effects.rows.grep(/\AStrength.*00:01:35\z/)).not_to be_empty
        expect(app.cmd_buffer).to have_received(:flush_screen)
      end

      it 'does not flush the screen when no effect changed' do
        run_input_loop_for_one_tick

        expect(app.cmd_buffer).not_to have_received(:flush_screen)
      end
    end
  end

  describe 'the .effects dot-command' do
    before { start(app) }

    let(:all_categories) { %i[debuffs cooldowns buffs custom spells] }

    def categories_line
      '* Categories: spells, buffs, debuffs, cooldowns, custom (toggle with .effects <category>)'
    end

    it 'shows every category by default' do
      expect(effects.enabled_categories).to eq all_categories
    end

    describe 'without an argument' do
      it 'says which categories are shown and which names there are, and changes nothing' do
        app.execute_command('.effects')

        expect(shown.last(2)).to eq ['* Effects showing: debuffs, cooldowns, buffs, custom, spells', categories_line]
        expect(effects.enabled_categories).to eq all_categories
        expect(server.string).to be_empty
        expect(File.exist?(settings_file)).to be false
      end

      it 'shows the categories that are drawn, in drawing order' do
        effects.enabled_categories = %i[cooldowns spells]

        app.execute_command('.effects')

        expect(shown.last(2)).to eq ['* Effects showing: cooldowns, spells', categories_line]
      end

      it 'says so when none is shown' do
        effects.enabled_categories = []

        app.execute_command('.effects   ')

        expect(shown.last(2)).to eq ['* Effects: none shown', categories_line]
      end
    end

    describe 'with category names' do
      it 'toggles a category off, and on again' do
        app.execute_command('.effects buffs')
        expect(effects.enabled_categories).to eq %i[debuffs cooldowns custom spells]
        expect(shown.last).to eq '* Effects showing: debuffs, cooldowns, custom, spells'

        app.execute_command('.effects buffs')
        expect(effects.enabled_categories).to eq all_categories
        expect(shown.last).to eq '* Effects showing: debuffs, cooldowns, buffs, custom, spells'
      end

      it 'toggles twice back to where it was, for every category' do
        EffectsWindow::CATEGORIES.each do |category|
          app.execute_command(".effects #{category}")
          expect(effects.category_enabled?(category)).to be false
          app.execute_command(".effects #{category}")
          expect(effects.category_enabled?(category)).to be true
        end
        expect(effects.enabled_categories).to eq all_categories
      end

      it 'toggles several categories in one command, each from its own state' do
        effects.hide_category(:cooldowns)

        app.execute_command('.effects spells cooldowns debuffs')

        expect(effects.enabled_categories).to eq %i[cooldowns buffs custom]
        expect(shown.last).to eq '* Effects showing: cooldowns, buffs, custom'
      end

      it 'accepts commas, any case and extra spaces, and toggles a repeated name once' do
        app.execute_command('.EFFECTS  Spells,BUFFS   buffs ')

        expect(effects.enabled_categories).to eq %i[debuffs cooldowns custom]
      end

      it 'draws or stops drawing the category at once' do
        effects.apply_effects(:buffs, [effect('Haste', 100)])
        expect(effects.rows.grep(/\AHaste/)).not_to be_empty

        app.execute_command('.effects buffs')
        expect(effects.rows.grep(/\AHaste|Buffs/)).to be_empty

        app.execute_command('.effects buffs')
        expect(effects.rows.grep(/\AHaste/)).not_to be_empty
      end

      it 'toggles every effects window, each from its own state' do
        LAYOUT['two_effects'] = REXML::Document.new(<<~XML).root
          <layout>
            <window class='effects' top='0' left='0' height='6' width='30' value='first'/>
            <window class='effects' top='0' left='31' height='6' width='30' value='second' categories='buffs'/>
            <window class='command' top='9' left='1' height='1' width='20'/>
          </layout>
        XML
        app.send(:apply_layout, 'two_effects')

        app.execute_command('.effects buffs')

        expect(app.window_mgr.effects.transform_values(&:enabled_categories))
          .to eq('first' => %i[debuffs cooldowns custom spells], 'second' => [])
      end

      it 'toggles nothing and names the unknown categories and the valid ones when any name is unknown' do
        app.execute_command('.effects buffs potions Auras')

        expect(effects.enabled_categories).to eq all_categories
        expect(shown.last).to eq '* Unknown effects category: potions, auras (valid: spells, buffs, debuffs, cooldowns, custom)'
        expect(server.string).to be_empty
        expect(File.exist?(settings_file)).to be false
      end

      it 'toggles the Custom section of the Lich timers, which needs no other change' do
        effects.apply_effects(:custom, [effect('My Timer', 100)])
        expect(effects.rows.grep(/Custom/)).not_to be_empty

        app.execute_command('.effects custom')

        expect(effects.enabled_categories).to eq %i[debuffs cooldowns buffs spells]
        expect(shown.last).to eq '* Effects showing: debuffs, cooldowns, buffs, spells'
        expect(effects.rows.grep(/Custom|My Timer/)).to be_empty
      end

      it 'does not take a category by prefix' do
        app.execute_command('.effects spell')

        expect(effects.enabled_categories).to eq all_categories
        expect(shown.last).to start_with('* Unknown effects category: spell ')
      end

      it 'is still a whole-word command: .effectsx goes to the game' do
        app.execute_command('.effectsx buffs')

        expect(server.string).to eq ";effectsx buffs\n"
        expect(effects.enabled_categories).to eq all_categories
      end
    end

    it 'does nothing but say so when the layout has no effects window' do
      LAYOUT['no_effects'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='text' top='0' left='0' height='6' width='42' value='main'/>
          <window class='command' top='9' left='1' height='1' width='20'/>
        </layout>
      XML
      app.send(:apply_layout, 'no_effects')

      ['.effects', '.effects buffs', '.effects nonsense'].each do |cmd|
        expect { app.execute_command(cmd) }.not_to raise_error
        expect(shown.last).to eq '* No effects window in this layout'
      end
      expect(server.string).to be_empty
      expect(File.exist?(settings_file)).to be false
    end

    it 'is listed by .help on two lines, just above .help itself' do
      expect(Application::DOT_COMMANDS.flat_map(&:help).last(3)).to eq [
        '.effects            Show which effect timer categories are visible',
        '.effects <cat...>   Toggle categories: spells, buffs, debuffs, cooldowns, custom',
        '.help              Show this help'
      ]
    end

    it 'is the only effects command in DOT_COMMANDS, a flat frozen table of dot-commands' do
      expect(Application::DOT_COMMANDS).to be_frozen
      expect(Application::DOT_COMMANDS).to all(be_a(DotCommand))
      expect(Application::DOT_COMMANDS.map(&:name).grep(/effects/)).to eq ['effects']
      expect(Application::DOT_COMMANDS.find { |command| command.name == 'effects' }.args).to eq :optional
      expect(Application.const_defined?(:EFFECTS_DOT_COMMANDS)).to be false
    end

    describe 'the one-time `spell active` request' do
      it 'is sent the first time a toggle turns a category on' do
        effects.hide_category(:buffs)

        app.execute_command('.effects buffs')

        expect(server.string).to eq "spell active\n"
      end

      it 'is not sent again by later toggles that turn a category on' do
        effects.enabled_categories = []

        app.execute_command('.effects buffs')
        app.execute_command('.effects buffs')
        app.execute_command('.effects buffs cooldowns')

        expect(server.string).to eq "spell active\n"
      end

      it 'is not sent without an argument' do
        app.execute_command('.effects')
        app.execute_command('.effects   ')

        expect(server.string).to be_empty
      end

      it 'is not sent by toggles that only turn categories off, and waits for the first one that turns one on' do
        app.execute_command('.effects spells')
        app.execute_command('.effects buffs debuffs')
        expect(server.string).to be_empty

        app.execute_command('.effects spells')
        app.execute_command('.effects spells')

        expect(server.string).to eq "spell active\n"
      end

      it 'is sent when a command turns one category on and another off' do
        effects.hide_category(:buffs)

        app.execute_command('.effects spells buffs')

        expect(server.string).to eq "spell active\n"
      end

      it 'is not sent for an unknown category' do
        app.execute_command('.effects potions')

        expect(server.string).to be_empty
        app.execute_command('.effects buffs')
        app.execute_command('.effects buffs')
        expect(server.string).to eq "spell active\n"
      end

      it 'uses the connection send_line' do
        allow(app.connection).to receive(:send_line)
        effects.hide_category(:debuffs)

        app.execute_command('.effects debuffs')

        expect(app.connection).to have_received(:send_line).with('spell active').once
      end
    end
  end

  describe 'remembering the categories' do
    before { File.delete(settings_file) if File.exist?(settings_file) }

    it 'saves them under EFFECTS_CATEGORIES, by window key, on every toggle' do
      start(app)

      app.execute_command('.effects buffs')
      expect(saved['EFFECTS_CATEGORIES']).to eq('effects' => %w[debuffs cooldowns custom spells])

      app.execute_command('.effects spells')
      expect(saved['EFFECTS_CATEGORIES']).to eq('effects' => %w[debuffs cooldowns custom])
    end

    it 'keeps the other settings in the file' do
      File.write(settings_file, JSON.generate('DRAG_HIGHLIGHT' => false, 'EFFECTS_CATEGORIES' => { 'other' => ['buffs'] }))
      start(app)

      app.execute_command('.effects debuffs')

      expect(saved).to eq('DRAG_HIGHLIGHT'     => false,
                          'EFFECTS_CATEGORIES' => { 'other' => ['buffs'], 'effects' => %w[cooldowns buffs custom spells] })
    end

    it 'applies the saved categories over the layout\'s in the next session' do
      first = start(build_app)
      first.execute_command('.effects cooldowns spells')

      second = start(build_app)

      expect(second.window_mgr.effects['effects'].enabled_categories).to eq %i[debuffs buffs custom]
    end

    it 'applies them again when a layout is switched to' do
      start(app)
      app.execute_command('.effects cooldowns')
      # A layout file that names categories has the builder apply them again
      LAYOUT['named'] = REXML::Document.new(<<~XML).root
        <layout>
          <window class='effects' top='0' left='0' height='6' width='30' categories='spells'/>
          <window class='command' top='9' left='1' height='1' width='20'/>
        </layout>
      XML

      app.send(:apply_layout, 'named')

      expect(app.window_mgr.effects['effects'].enabled_categories).to eq %i[debuffs buffs custom spells]
    end

    it 'saves and restores the custom category with the others' do
      first = start(build_app)
      first.execute_command('.effects custom')
      expect(saved['EFFECTS_CATEGORIES']).to eq('effects' => %w[debuffs cooldowns buffs spells])

      second = start(build_app)
      expect(second.window_mgr.effects['effects'].enabled_categories).to eq %i[debuffs cooldowns buffs spells]
      second.execute_command('.effects custom')
      expect(saved['EFFECTS_CATEGORIES']).to eq('effects' => %w[debuffs cooldowns buffs custom spells])
    end

    it 'restores a file saved before custom existed without crashing, with custom off until toggled on' do
      File.write(settings_file, JSON.generate('EFFECTS_CATEGORIES' => { 'effects' => %w[spells buffs debuffs cooldowns] }))

      start(app)

      expect(effects.enabled_categories).to eq %i[debuffs cooldowns buffs spells]
      app.execute_command('.effects custom')
      expect(effects.enabled_categories).to eq %i[debuffs cooldowns buffs custom spells]
    end

    it 'keeps a choice to show nothing' do
      File.write(settings_file, JSON.generate('EFFECTS_CATEGORIES' => { 'effects' => [] }))

      start(app)

      expect(effects.enabled_categories).to eq []
    end

    it 'leaves a window with no saved entry on the layout\'s categories' do
      File.write(settings_file, JSON.generate('EFFECTS_CATEGORIES' => { 'other' => ['cooldowns'] }))

      start(app)

      expect(effects.enabled_categories).to eq %i[debuffs cooldowns buffs custom spells]
    end

    it 'ignores unknown names within a list' do
      File.write(settings_file, JSON.generate('EFFECTS_CATEGORIES' => { 'effects' => ['buffs', 'bogus', 7, nil] }))

      start(app)

      expect(effects.enabled_categories).to eq %i[buffs]
    end

    [
      ['no settings file', nil],
      ['a file that is not JSON', '{not json'],
      ['a file that is not an object', '[1, 2]'],
      ['no EFFECTS_CATEGORIES', '{"DRAG_HIGHLIGHT": true}'],
      ['a null value', '{"EFFECTS_CATEGORIES": null}'],
      ['a string value', '{"EFFECTS_CATEGORIES": "spells,buffs"}'],
      ['a list value', '{"EFFECTS_CATEGORIES": ["buffs"]}'],
      ['a window entry that is a string', '{"EFFECTS_CATEGORIES": {"effects": "buffs"}}'],
      ['a window entry that is a number', '{"EFFECTS_CATEGORIES": {"effects": 3}}'],
      ['a window entry with no known category', '{"EFFECTS_CATEGORIES": {"effects": ["nonsense", 5]}}']
    ].each do |description, content|
      it "falls back to the layout's categories (all five unless it names some) for #{description}" do
        File.write(settings_file, content) if content

        expect { start(app) }.not_to raise_error
        expect(effects.enabled_categories).to eq %i[debuffs cooldowns buffs custom spells]

        LAYOUT['named'] = REXML::Document.new(
          "<layout><window class='effects' top='0' left='0' height='6' width='30' categories='buffs'/></layout>"
        ).root
        app.send(:apply_layout, 'named')
        expect(app.window_mgr.effects['effects'].enabled_categories).to eq %i[buffs]
      end
    end

    it 'logs and falls back when the saved settings cannot be read' do
      app
      allow(ProfanitySettings).to receive(:load_setting).and_raise(Errno::EACCES)

      expect { start(app) }.not_to raise_error

      expect(effects.enabled_categories).to eq %i[debuffs cooldowns buffs custom spells]
      expect(ProfanityLog).to have_received(:write).with('settings', /Could not restore the effects categories/)
    end

    it 'logs a failure to save and still changes the window' do
      start(app)
      allow(ProfanitySettings).to receive(:save_setting).and_raise(Errno::EACCES)

      expect { app.execute_command('.effects buffs') }.not_to raise_error

      expect(effects.category_enabled?(:buffs)).to be false
      expect(ProfanityLog).to have_received(:write).with('settings', /Could not save the effects categories/)
    end

    it 'does not read the settings for a layout without an effects window' do
      allow(ProfanitySettings).to receive(:load_setting).and_call_original
      LAYOUT['no_effects'] = REXML::Document.new("<layout><window class='command' top='9' left='1' height='1' width='20'/></layout>").root

      app.send(:apply_layout, 'no_effects')

      expect(ProfanitySettings).not_to have_received(:load_setting).with(Application::EFFECTS_SETTING_KEY, anything)
    end
  end

  describe 'the eleazzar_effect_window.xml template' do
    let(:template) { File.expand_path('../../templates/eleazzar_effect_window.xml', __dir__) }
    let(:element) do
      REXML::Document.new(File.read(template)).root.elements["layout[@id='default']"]
    end
    let(:windows) { element.elements.to_a('window') }

    it 'has one effects window on the right and none of the old effectmon rows' do
      effects_windows = windows.select { |w| w.attributes['class'] == 'effects' }
      old_rows = windows.select { |w| w.attributes['value'].to_s.match?(/\A(?:buff|debuff|cooldown|spell)\d+\z/) }

      expect(effects_windows.size).to eq 1
      expect(%w[left top].map { |name| effects_windows.first.attributes[name] }).to eq %w[160 0]
      expect(effects_windows.first.attributes['width']).to eq 'min(30, cols-160)'
      expect(old_rows).to be_empty
      expect(windows.select { |w| w.attributes['class'] == 'progress' && w.attributes['left'] == '160' }).to be_empty
    end

    it 'builds the effects window at the right-hand panel and shows every category' do
      allow(Curses).to receive(:lines).and_return(50)
      allow(Curses).to receive(:cols).and_return(190)
      expect(SettingsLoader.load(template, {}, Hash.new { |hash, key| hash[key] = proc {} }, proc {})).to be_nil
      wm = WindowManager.new
      wm.load_layout('default')

      window = wm.effects['effects']
      expect(window).to be_a(EffectsWindow)
      expect([window.begy, window.begx, window.maxx, window.maxy]).to eq [0, 160, 30, 49]
      expect(window.enabled_categories).to eq EffectsWindow::DRAW_ORDER
    end
  end
end
