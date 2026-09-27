# frozen_string_literal: true

# Tests ProfanitySettings.resolve_template's final fallback. There is no
# legacy ~/.profanity.xml lookup: when templates/default.xml is absent the
# resolver reports the missing file and exits, whatever sits in HOME.
# spec_helper points HOME at a throwaway directory.

require_relative '../spec_helper'
require_relative '../../lib/profanity_settings'

RSpec.describe ProfanitySettings do
  describe '.resolve_template' do
    let(:app_dir) { Dir.mktmpdir('profanity-app') }
    let(:legacy) { File.join(Dir.home, '.profanity.xml') }

    before { File.write(legacy, '<settings/>') }

    after do
      FileUtils.rm_f(legacy)
      FileUtils.remove_entry(app_dir)
    end

    def resolve_exit(**)
      status = nil
      expect do
        described_class.resolve_template(app_dir: app_dir, **)
      rescue SystemExit => e
        status = e.status
      end.to output(/No settings file found/).to_stderr
      status
    end

    it 'ignores ~/.profanity.xml and exits 1 when templates/default.xml is absent' do
      expect(resolve_exit).to eq(1)
    end

    it 'ignores ~/.profanity.xml for an unknown --char when templates/default.xml is absent' do
      expect(resolve_exit(char: 'Nobody')).to eq(1)
    end

    it 'still returns templates/default.xml when it exists' do
      FileUtils.mkdir_p(File.join(app_dir, 'templates'))
      default = File.join(app_dir, 'templates', 'default.xml')
      File.write(default, '<settings/>')

      expect(described_class.resolve_template(app_dir: app_dir)).to eq(default)
    end
  end
end
