# frozen_string_literal: true

# Tests ProfanitySettings.resolve_template's final fallback. There is no
# legacy ~/.profanity.xml lookup: when templates/default.xml is absent the
# resolver raises NotFoundError, whatever sits in HOME.
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

    # The message profanity.rb prints before exiting 1. The resolver itself
    # prints nothing and doesn't exit.
    def not_found_message
      "No settings file found. Use --char=<name>, --template=<file>, or --settings-file=<path>\n" \
        "Or create #{File.join(app_dir, 'templates', 'default.xml')}"
    end

    it 'ignores ~/.profanity.xml and raises NotFoundError when templates/default.xml is absent' do
      expect { described_class.resolve_template(app_dir: app_dir) }
        .to raise_error(described_class::NotFoundError, not_found_message)
        .and output('').to_stderr
    end

    it 'ignores ~/.profanity.xml for an unknown --char when templates/default.xml is absent' do
      expect { described_class.resolve_template(char: 'Nobody', app_dir: app_dir) }
        .to raise_error(described_class::NotFoundError, not_found_message)
        .and output('').to_stderr
    end

    it 'raises NotFoundError naming the expanded path for a missing --settings-file' do
      missing = File.join(app_dir, 'nope', '..', 'missing.xml')

      expect { described_class.resolve_template(settings_file: missing, app_dir: app_dir) }
        .to raise_error(described_class::NotFoundError, "Settings file not found: #{File.join(app_dir, 'missing.xml')}")
        .and output('').to_stderr
    end

    it 'raises for a missing --settings-file even when a default template exists' do
      FileUtils.mkdir_p(File.join(app_dir, 'templates'))
      File.write(File.join(app_dir, 'templates', 'default.xml'), '<settings/>')

      expect { described_class.resolve_template(settings_file: File.join(app_dir, 'missing.xml'), app_dir: app_dir) }
        .to raise_error(described_class::NotFoundError, /\ASettings file not found: /)
    end

    it 'still returns templates/default.xml when it exists' do
      FileUtils.mkdir_p(File.join(app_dir, 'templates'))
      default = File.join(app_dir, 'templates', 'default.xml')
      File.write(default, '<settings/>')

      expect(described_class.resolve_template(app_dir: app_dir)).to eq(default)
    end
  end
end
