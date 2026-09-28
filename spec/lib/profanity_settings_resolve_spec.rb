# frozen_string_literal: true

# Tests the file names ProfanitySettings picks from --template and from
# --log-file / --log-dir / --char. spec_helper points HOME at a throwaway
# directory, so ProfanitySettings::APP_DIR is inside it.

require_relative '../spec_helper'
require_relative '../../lib/constants'
require_relative '../../lib/profanity_settings'

RSpec.describe ProfanitySettings do
  describe '.resolve_template with --template' do
    let(:app_dir) { Dir.mktmpdir('profanity-app') }
    let(:templates) { File.join(app_dir, 'templates') }

    before { FileUtils.mkdir_p(templates) }
    after { FileUtils.remove_entry(app_dir) }

    it 'keeps the case the user typed' do
      File.write(File.join(templates, 'MyLayout.xml'), '<settings/>')

      expect(described_class.resolve_template(template: 'MyLayout.xml', app_dir: app_dir))
        .to eq(File.join(templates, 'MyLayout.xml'))
    end

    it 'still finds a lowercase template typed with capitals, as before' do
      default = File.join(templates, 'default.xml')
      File.write(default, '<settings/>')

      path = described_class.resolve_template(template: 'Default.xml', app_dir: app_dir)
      expect(File.identical?(path, default)).to be(true)
    end

    it 'raises NotFoundError naming the template as typed when no such template exists' do
      expect { described_class.resolve_template(template: 'NoSuch.xml', app_dir: app_dir) }
        .to raise_error(described_class::NotFoundError, "Template not found: #{File.join(templates, 'NoSuch.xml')}")
        .and output('').to_stderr
    end

    it 'raises for a missing --template even when a default template exists' do
      File.write(File.join(templates, 'default.xml'), '<settings/>')

      expect { described_class.resolve_template(template: 'NoSuch.xml', app_dir: app_dir) }
        .to raise_error(described_class::NotFoundError, /\ATemplate not found: /)
    end
  end

  describe '.resolve_log' do
    let(:log_dir) { Dir.mktmpdir('profanity-logs') }

    after { FileUtils.remove_entry(log_dir) }

    it 'names the log after --char inside --log-dir' do
      expect(described_class.resolve_log(char: 'Mahtra', log_dir: log_dir))
        .to eq(File.join(log_dir, 'mahtra.log'))
    end

    it 'uses the same char-based name with and without --log-dir' do
      without_dir = described_class.resolve_log(char: 'Mahtra')
      with_dir = described_class.resolve_log(char: 'Mahtra', log_dir: log_dir)

      expect(without_dir).to eq(described_class.file('mahtra.log'))
      expect(File.basename(with_dir)).to eq(File.basename(without_dir))
    end

    it 'uses profanity.log inside --log-dir when there is no --char' do
      expect(described_class.resolve_log(log_dir: log_dir)).to eq(File.join(log_dir, 'profanity.log'))
    end

    it 'expands a relative --log-dir to an absolute path' do
      Dir.chdir(log_dir) do
        expect(described_class.resolve_log(char: 'Mahtra', log_dir: 'logs'))
          .to eq(File.join(Dir.pwd, 'logs', 'mahtra.log'))
      end
    end

    it 'returns an absolute path in the current directory with no --char, --log-file or --log-dir' do
      Dir.chdir(log_dir) do
        path = described_class.resolve_log

        expect(path).to eq(File.join(Dir.pwd, 'profanity.log'))
        expect(Pathname.new(path)).to be_absolute
      end
    end

    it 'lets --log-file win over --log-dir and --char' do
      expect(described_class.resolve_log(char: 'Mahtra', log_dir: log_dir, log_file: 'x/custom.log'))
        .to eq(File.expand_path('x/custom.log'))
    end
  end
end
