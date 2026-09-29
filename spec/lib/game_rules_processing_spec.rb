# frozen_string_literal: true

# The per-game rules as the player sees them: raw server lines fed through
# the real GameTextProcessor#run, and what reaches each window (death and
# logon lines rewritten to "HH:MM Name ...", stuns, shortened spell names in
# the spell window).
#
# Both games' rules run on every line, DragonRealms first (there is no game
# detection yet), so the tables below pin that combined behaviour line by
# line, including the one line both games claim.

require_relative '../spec_helper'
require 'rexml/document'
require_relative '../../lib/game_text_processor'
require_relative '../../lib/shared_state'
require_relative '../../lib/window_manager'

RSpec.describe 'GameTextProcessor per-game rules' do
  let(:event_bus) { EventBus.new }
  let(:wm) do
    windows = %w[main death logons percWindow].to_h { |id| [id, Object.new] }
    Struct.new(:stream, :indicator, :progress, :countdown, :room,
               :command_window, :command_window_layout).new(windows, {}, {}, {}, {}, nil, nil)
  end
  let(:state) { SharedState.new.tap { |s| s.skip_server_time_offset = true } }
  let(:processor) do
    GameTextProcessor.new(
      window_mgr: wm,
      shared_state: state,
      cmd_buffer: Struct.new(:window).new(nil),
      xml_escapes: { '&lt;' => '<', '&gt;' => '>', '&quot;' => '"', '&apos;' => "'", '&amp;' => '&' },
      event_bus: event_bus,
      clock: Clock.new(now: -> { Time.new(2026, 9, 29, 9, 5, 7) })
    )
  end
  let(:shown) { [] }
  let(:stuns) { [] }

  before do
    event_bus.on(:stream_text) { |data| shown << data }
    event_bus.on(:stun) { |data| stuns << data[:seconds] }
  end

  # Feed raw server lines through GameTextProcessor#run, as the socket would.
  def receive_from_server(*lines)
    queue = lines.map { |line| "#{line}\r\n" }
    server = Object.new
    server.define_singleton_method(:gets) { queue.shift&.dup }
    allow(IO).to receive(:select).and_return(nil)
    allow(processor).to receive(:show_disconnect_message)
    allow(processor).to receive(:exit)
    processor.run(server)
  end

  # Send +text+ on +stream+ (a pushStream/popStream pair, as the game does).
  def receive_on(stream, text)
    receive_from_server("<pushStream id=\"#{stream}\"/>#{text}", '<popStream/>')
  end

  # The non-empty texts shown on +stream+.
  def lines_on(stream)
    shown.select { |data| data[:stream] == stream && !data[:text].empty? }.map { |data| data[:text] }
  end

  describe 'DragonRealms death lines' do
    {
      ' * Hawthrick was just struck down! '                                                          => '09:05 Hawthrick',
      " * Valeiria was just struck down at Hara'jaal, Fal Daelfa!"                                   => '09:05 Valeiria',
      ' * Mahtra just disintegrated!'                                                                => '09:05 Mahtra',
      ' * Mahtra was lost to the Plane of Exile!'                                                    => '09:05 Mahtra',
      " * A fiery phoenix soars into the heavens as Mahtra's spirit arises from the ashes of death." => '09:05 Mahtra MF',
      " * Mahtra's spirit arises from the ashes of death."                                           => '09:05 Mahtra',
      ' * Mahtra was smote by Kertigen!'                                                             => '09:05 Mahtra',
      ' * Mahtra failed within the Temple of Hodierna!'                                              => '09:05 Mahtra',
      ' * Mahtra was just sacrificed to Harawep!'                                                    => '09:05 Mahtra Sacrifice',
    }.each do |line, expected|
      it "shows #{line.strip.inspect} as #{expected.inspect}, the time in red" do
        receive_on('death', line)

        expect(lines_on('death')).to eq [expected]
        expect(shown.last[:colors]).to eq [{ start: 0, end: 5, fg: 'ff0000' }]
      end
    end
  end

  describe 'GemStone death lines' do
    {
      ' * Mahtra just bit the dust!'                                           => 'WL',
      ' * Mahtra is off to a rough start!  She just bit the dust!'             => 'WL',
      ' * The death cry of Mahtra echoes in your mind!'                        => 'RIFT',
      ' * Mahtra just got squashed!'                                           => 'CY',
      ' * Mahtra has gone to feed the fishes!'                                 => 'RR',
      " * Mahtra's life on land appears to be as rough as her life at sea."    => 'KF',
      ' * Mahtra just turned her last page!'                                   => 'TI',
      ' * Mahtra is off to a rough start!  She was just put on ice!'           => 'IMT',
      ' * Mahtra was just put on ice!'                                         => 'IMT',
      ' * Mahtra just sank to the bottom of the Great Western Sea!'            => 'OSA',
      ' * Mahtra just sank to the bottom of the Tenebrous Cauldron!'           => 'OSA',
      ' * Mahtra just gave up the ghost!'                                      => 'TRAIL',
      ' * Mahtra just got iced in the Hinterwilds!'                            => 'HW',
      ' * Mahtra just punched a one-way ticket!'                               => 'KD',
      ' * Mahtra is going home on her shield!'                                 => 'TV',
      ' * Mahtra just took a long walk off of a short pier!'                   => 'SOL',
      ' * Mahtra is dust in the wind!'                                         => 'FWI',
      ' * Mahtra is six hundred feet under!'                                   => 'ZUL',
      ' * Mahtra just lost her way somewhere in the Settlement of Reim!'       => 'REIM',
      ' * Bob may just be going home on his shield!'                           => 'RED',
      " * Mahtra's flame just burnt out in the Sea of Fire!"                   => 'SOS',
      ' * Mahtra failed within the Bank at Bloodriven'                         => 'DR-B',
      ' * Mahtra was just defeated in Duskruin Arena!'                         => 'DR-A',
      ' * Mahtra was just defeated during round 12 in Endless Duskruin Arena!' => 'DR-A',
      ' * Mahtra was just defeated in the Arena of the Abyss!'                 => 'EG-A',
      ' * Mahtra failed to bring a shrubbery to the Night at the Academy!'     => 'NATA',
      ' * Mahtra has just returned to Gosaena!'                                => '??',
    }.each do |line, code|
      it "shows #{line.strip.inspect} with the area code #{code}" do
        receive_on('death', line)

        name = line[/(?:Mahtra|Bob)/]
        expect(lines_on('death')).to eq ["09:05 #{name} #{code}"]
        expect(shown.last[:colors]).to eq [{ start: 0, end: 5, fg: 'ff0000' }]
      end
    end

    [
      ' * Mahtra has been vaporized!',
      ' * Mahtra was just incinerated!',
      ' * The death cry of Mahtra was just incinerated!',
    ].each do |line|
      it "shows nothing for #{line.strip.inspect}" do
        receive_on('death', line)

        expect(shown.map { |data| data[:text] }).to all(eq '')
      end
    end
  end

  describe 'a death line neither game recognizes' do
    it 'is shown as sent, without a time' do
      receive_on('death', ' * Mahtra fell off a very tall cliff.')

      expect(lines_on('death')).to eq [' * Mahtra fell off a very tall cliff.']
    end
  end

  describe 'a death line both games recognize' do
    # Characterization: both rule sets run, DragonRealms first, so DR's
    # "failed within .*!" catch-all takes a "!"-terminated Bloodriven line
    # before GemStone's DR-B entry sees it. Whether GemStone really ends
    # the line with "!" is unknown (AUDIT 6a Q7); applying only the active
    # game's rules is the planned fix (AUDIT 0.3 G).
    it 'goes to DragonRealms when it ends with "!"' do
      receive_on('death', ' * Mahtra failed within the Bank at Bloodriven!')

      expect(lines_on('death')).to eq ['09:05 Mahtra']
    end

    it 'goes to GemStone without the "!"' do
      receive_on('death', ' * Mahtra failed within the Bank at Bloodriven')

      expect(lines_on('death')).to eq ['09:05 Mahtra DR-B']
    end
  end

  describe 'logon lines' do
    login = '007700'
    logout = '777700'
    disconnect = 'aa7733'
    {
      # DragonRealms
      'joins the adventure with little fanfare.'                             => login,
      'just sauntered into the adventure with an annoying tune on his lips.' => login,
      'just wandered into another adventure.'                                => login,
      'just limped in for another adventure.'                                => login,
      'snuck out of the shadow he was hiding in.'                            => login,
      'joins the adventure with a gleam in her eye.'                         => login,
      'joins the adventure with a gleam in his eye.'                         => login,
      'comes out from within the shadows with renewed vigor.'                => login,
      'just crawled into the adventure.'                                     => login,
      'has woken up in search of new ale!'                                   => login,
      'just popped into existance.'                                          => login,
      'has joined the adventure after escaping another.'                     => login,
      'has left to contemplate the life of a warrior.'                       => logout,
      'just sauntered off-duty to get some rest.'                            => logout,
      'departs from the adventure with little fanfare.'                      => logout,
      'limped away from the adventure for now.'                              => logout,
      'thankfully just returned home to work on a new tune.'                 => logout,
      'fades swiftly into the shadows.'                                      => logout,
      'retires from the adventure for now.'                                  => logout,
      'just found a shadow to hide out in.'                                  => logout,
      'quietly departs the adventure.'                                       => logout,
      # Both games
      'joins the adventure.'                                                 => login,
      'returns home from a hard day of adventuring.'                         => logout,
      'has disconnected.'                                                    => disconnect,
    }.each do |message, fg|
      it "shows \" * Mahtra #{message}\" as \"09:05 Mahtra\", the time in #{fg}" do
        receive_on('logons', " * Mahtra #{message}")

        expect(lines_on('logons')).to eq ['09:05 Mahtra']
        expect(shown.last[:colors]).to eq [{ start: 0, end: 5, fg: fg }]
      end
    end

    it 'shows a logon line neither game knows as sent' do
      receive_on('logons', ' * Mahtra tiptoes into the adventure.')

      expect(lines_on('logons')).to eq [' * Mahtra tiptoes into the adventure.']
    end

    it 'needs the " * " in front of the name' do
      receive_on('logons', 'Mahtra joins the adventure.')

      expect(lines_on('logons')).to eq ['Mahtra joins the adventure.']
    end
  end

  describe 'stuns' do
    # Raise Dead: one line per deity's chant
    raise_dead = [
      'Deep and resonating, you feel the chant that falls from your lips.',
      'Moisture beads upon your skin and you feel your eyes cloud over.',
      'Lifting your finger, you begin to chant and draw a series of conjoined circles.',
      'Crouching beside the prone form of Bob, you begin to chant.',
      'Murmuring softly, you call upon your connection with the Destroyer.',
      'Rich and lively, the scent of wild flowers suddenly fills the air.',
      'Breathing slowly, you extend your senses towards the world around you.',
      'Your surroundings grow dim...you lapse into a state of awareness only.',
      'Murmuring softly, a mournful chant slips from your lips.',
      'Emptying all breathe from your body, you slowly still yourself.',
      'Thin at first, a fine layer of rime tickles your hands.',
      'As you begin to chant you notice the scent of dry, dusty parchment.',
      'As you begin to chant, you notice the scent of dry, dusty parchment.',
      'Wrapped in an aura of chill, you close your eyes and softly begin to chant.',
      'As Bob begins to chant, your spirit is drawn closer to your body.',
    ]
    shadow_valley = 'Just as you think the falling will never end, you crash through an ethereal barrier ' \
                    'which bursts into a dazzling kaleidoscope of color!  Your sensation of falling turns to ' \
                    'dizziness and you feel unusually heavy for a moment.  Everything seems to stop for a ' \
                    'prolonged second and then WHUMP!!!'

    raise_dead.map { |line| [line, 30.6] }.push([shadow_valley, 16.2], ['You are stunned for 3 rounds!', 15]).each do |line, seconds|
      it "stuns for #{seconds}s on #{line[0, 50].inspect}" do
        receive_from_server(line)

        expect(stuns).to eq [seconds]
        expect(lines_on('main')).to eq [line]
      end
    end

    it 'does not stun on a line that only starts like a Raise Dead chant' do
      receive_from_server('Deep and resonating, the bell tolls.')

      expect(stuns).to be_empty
    end

    it 'does not stun on a Raise Dead chant that is not at the start of the line' do
      receive_from_server('Bob says, "Deep and resonating, you feel the chant that falls from your lips."')

      expect(stuns).to be_empty
    end
  end

  describe 'spell names in the spell window' do
    {
      'Turmar Illumination  (6 roisaen)' => 'TURI (6 roisaen)',
      'Finesse  (18 roisaen)'            => 'FIN (18 roisaen)',
      'Aesandry Darlaeth (5 roisaen)'    => 'AD (5 roisaen)',
      'Noumena  (27 roisaen)'            => 'NOU (27 roisaen)',
      ' Finesse  (18 roisaen)'           => 'FIN (18 roisaen)',
      'Frobnicate  (3 roisaen)'          => 'Frobnicate (3 roisaen)',
      'aesandry darlaeth  (5 roisaen)'   => 'aesandry darlaeth (5 roisaen)',
      'X (5 roisaen)'                    => 'X (5 roisaen)',
    }.each do |line, expected|
      it "shows #{line.inspect} as #{expected.inspect}" do
        receive_on('percWindow', line)

        expect(lines_on('percWindow')).to eq [expected]
      end
    end
  end
end
