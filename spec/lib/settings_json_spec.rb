# frozen_string_literal: true

# Tests that ~/.profanity/settings.json can't stop the client from starting
# (a top level that isn't an object, or non-ASCII text under a C locale, is
# ignored with a warning) and that it is replaced atomically, keeping its
# mode. spec_helper points HOME at a throwaway directory.

require_relative '../spec_helper'
require_relative '../../lib/profanity_settings'
require_relative '../../lib/mouse_scroll'

RSpec.describe ProfanitySettings do
  let(:path) { described_class.file('settings.json') }

  before do
    allow(ProfanityLog).to receive(:write)
    allow(Curses).to receive(:mousemask)
  end

  after { Dir.glob(File.join(described_class::APP_DIR, 'settings.json*')).each { |f| File.delete(f) } }

  describe 'a settings.json that is not a JSON object' do
    # BUG FOUND (fixed here): MouseScroll.new called key? on whatever the
    # file held, so an array, string or number crashed startup.
    ['[]', '"x"', '3', 'null'].each do |json|
      context "(#{json})" do
        before { File.write(path, json) }

        it 'is treated as empty, so startup uses the defaults' do
          mouse = nil
          expect { mouse = MouseScroll.new({}, ->(_msg) {}) }.not_to raise_error

          expect(mouse.drag_highlight).to be true
          expect(described_class.load_setting('DRAG_HIGHLIGHT', :default)).to eq :default
        end

        it 'logs a warning' do
          described_class.load_mouse_settings

          expect(ProfanityLog).to have_received(:write)
            .with('settings', "Ignoring settings.json: expected a JSON object, got #{json}")
        end

        it 'is replaced by an object holding the saved setting' do
          described_class.save_setting('DRAG_HIGHLIGHT', false)

          expect(JSON.parse(File.read(path))).to eq('DRAG_HIGHLIGHT' => false)
        end
      end
    end
  end

  # BUG FOUND (fixed here): the file was read in the locale's encoding, so a
  # non-ASCII character under LANG=C raised Encoding::InvalidByteSequenceError
  # out of MouseScroll.new.
  it 'reads settings.json as UTF-8 whatever the locale' do
    File.write(path, '{"DRAG_HIGHLIGHT": false, "note": "café"}')
    original = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII

    expect(described_class.load_setting('DRAG_HIGHLIGHT', true)).to be false
  ensure
    Encoding.default_external = original
  end

  describe 'saving' do
    # BUG FOUND (fixed here): the file was truncated and rewritten in place,
    # so a crash or a concurrent read mid-write saw an empty or partial file.
    it 'replaces the file whole: a reader that opened it before the save still reads the old content' do
      described_class.save_setting('DRAG_HIGHLIGHT', true)
      old_content = File.read(path)

      File.open(path) do |reader|
        described_class.save_setting('BUTTON4_PRESSED_MASK', 524_288)

        expect(reader.read).to eq old_content
      end
      expect(JSON.parse(File.read(path))).to eq('DRAG_HIGHLIGHT' => true, 'BUTTON4_PRESSED_MASK' => 524_288)
    end

    it 'leaves no temporary file behind' do
      described_class.save_mouse_settings(1, 2)

      expect(Dir.children(described_class::APP_DIR).grep(/settings\.json/)).to eq ['settings.json']
    end

    it 'keeps the existing file and removes its temporary file when the save fails' do
      File.write(path, '{"DRAG_HIGHLIGHT": true}')
      allow(File).to receive(:rename).and_raise(Errno::EACCES)

      expect { described_class.save_setting('DRAG_HIGHLIGHT', false) }.to raise_error(Errno::EACCES)

      expect(File.read(path)).to eq '{"DRAG_HIGHLIGHT": true}'
      expect(Dir.children(described_class::APP_DIR).grep(/settings\.json/)).to eq ['settings.json']
    end

    it "keeps an existing file's mode" do
      File.write(path, '{}')
      File.chmod(0o640, path)

      described_class.save_setting('DRAG_HIGHLIGHT', false)

      expect(File.stat(path).mode & 0o7777).to eq 0o640
    end

    it 'creates a new file with the usual mode (0666 less the umask)' do
      described_class.save_setting('DRAG_HIGHLIGHT', false)

      expect(File.stat(path).mode & 0o7777).to eq(0o666 & ~File.umask)
    end

    it 'writes through a symlink, as before, rather than replacing it' do
      target = File.join(Dir.mktmpdir('profanity-dotfiles'), 'settings.json')
      File.write(target, '{}')
      File.symlink(target, path)

      described_class.save_setting('DRAG_HIGHLIGHT', false)

      expect(File.symlink?(path)).to be true
      expect(JSON.parse(File.read(target))).to eq('DRAG_HIGHLIGHT' => false)
    ensure
      FileUtils.remove_entry(File.dirname(target))
    end
  end
end
