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

  # Checked before curses starts: a log that can't be written would
  # otherwise send every log line to stderr, which curses draws over the
  # client's screen.
  describe '.choose_log' do
    let(:dir) { File.realpath(Dir.mktmpdir('profanity-choose-log')) }
    let(:app_dir) { described_class::APP_DIR }
    let(:fallback) { File.join(app_dir, 'profanity.log') }

    before { described_class.ensure_app_dir }

    after do
      # Give the directories back their permissions (not chmod_R, which
      # follows the dangling links some examples leave), then remove them.
      [dir, *Dir.children(dir).map { |name| File.join(dir, name) }].each do |path|
        File.chmod(0o700, path) if File.directory?(path) && !File.symlink?(path)
      end
      FileUtils.chmod('u+w', app_dir) if File.exist?(app_dir)
      FileUtils.remove_entry(dir)
    end

    # Root can write to read-only directories and search any directory, so
    # an example that takes permissions away is skipped for root.
    def skip_for_root
      skip 'root ignores file permissions' if Process.uid.zero?
    end

    # Run the block with +path+ read-only, then make it writable again.
    def read_only(path)
      skip_for_root
      FileUtils.chmod('a-w', path)
      yield
    ensure
      FileUtils.chmod('u+w', path) if File.exist?(path)
    end

    # What a directory holds, so a check can show it created nothing.
    def contents(path) = Dir.children(path).sort

    describe 'with the default path' do
      it 'keeps profanity.log in the current directory when it can be written' do
        Dir.chdir(dir) do
          expect(described_class.choose_log).to eq [File.join(dir, 'profanity.log'), nil]
        end
        expect(contents(dir)).to be_empty
      end

      it 'keeps an existing, writable profanity.log' do
        File.write(File.join(dir, 'profanity.log'), "earlier\n")

        Dir.chdir(dir) { expect(described_class.choose_log).to eq [File.join(dir, 'profanity.log'), nil] }
      end

      it 'falls back to ~/.profanity/profanity.log, with a notice, when the current directory is read-only' do
        before_app_dir = contents(app_dir)
        result = read_only(dir) { Dir.chdir(dir) { described_class.choose_log } }

        expect(result).to eq [fallback, "Can't write the log file #{File.join(dir, 'profanity.log')}: " \
                                        "the directory #{dir} can't be written. Logging to #{fallback} instead."]
        expect(contents(dir)).to be_empty
        expect(contents(app_dir)).to eq before_app_dir
      end

      it 'falls back when profanity.log is there but read-only' do
        log = File.join(dir, 'profanity.log')
        File.write(log, '')

        result = read_only(log) { Dir.chdir(dir) { described_class.choose_log } }

        expect(result).to eq [fallback, "Can't write the log file #{log}: permission denied. Logging to #{fallback} instead."]
      end

      it 'falls back when profanity.log is a link to a file in a directory that does not exist' do
        File.symlink(File.join(dir, 'gone', 'x.log'), File.join(dir, 'profanity.log'))

        path, notice = Dir.chdir(dir) { described_class.choose_log }

        expect(path).to eq fallback
        expect(notice).to include(': no such file or directory. Logging to ')
      end

      it 'falls back when profanity.log is a directory' do
        FileUtils.mkdir(File.join(dir, 'profanity.log'))

        path, notice = Dir.chdir(dir) { described_class.choose_log }

        expect(path).to eq fallback
        expect(notice).to include(': it is a directory. ')
      end

      it 'raises when ~/.profanity is read-only too' do
        read_only(dir) do
          read_only(app_dir) do
            Dir.chdir(dir) do
              expect { described_class.choose_log }
                .to raise_error(described_class::LogNotWritableError,
                                "Can't write the log file #{File.join(dir, 'profanity.log')}: the directory #{dir} " \
                                "can't be written. Use --log-file=<path> or --log-dir=<dir> to choose one that can be written.")
            end
          end
        end
      end

      it 'raises for --char when ~/.profanity is read-only, as the fallback is there too' do
        read_only(app_dir) do
          expect { described_class.choose_log(char: 'Mahtra') }
            .to raise_error(described_class::LogNotWritableError, /\ACan't write the log file #{Regexp.escape(File.join(app_dir, 'mahtra.log'))}: .*Use --log-file/)
        end
      end

      it 'raises, rather than falling back to the same file, when started from a read-only ~/.profanity' do
        read_only(app_dir) do
          Dir.chdir(app_dir) do
            expect { described_class.choose_log }
              .to raise_error(described_class::LogNotWritableError, %r{\ACan.t write the log file \S*/\.profanity/profanity\.log: .*Use --log-file})
          end
        end
      end
    end

    describe 'with --log-dir or --log-file' do
      it 'accepts a writable --log-dir' do
        expect(described_class.choose_log(char: 'Mahtra', log_dir: dir)).to eq [File.join(dir, 'mahtra.log'), nil]
      end

      it 'accepts a writable --log-file, existing or not' do
        log = File.join(dir, 'custom.log')
        expect(described_class.choose_log(log_file: log)).to eq [log, nil]

        File.write(log, '')
        expect(described_class.choose_log(log_file: log)).to eq [log, nil]
      end

      it 'raises for a --log-dir that does not exist, without falling back' do
        missing = File.join(dir, 'missing')

        expect { described_class.choose_log(char: 'Mahtra', log_dir: missing) }
          .to raise_error(described_class::LogNotWritableError,
                          "Can't write the log file #{File.join(missing, 'mahtra.log')}: " \
                          "the directory #{missing} doesn't exist. Check --log-dir.")
        expect(contents(dir)).to be_empty
      end

      it 'raises for a read-only --log-dir' do
        read_only(dir) do
          expect { described_class.choose_log(log_dir: dir) }
            .to raise_error(described_class::LogNotWritableError,
                            "Can't write the log file #{File.join(dir, 'profanity.log')}: " \
                            "the directory #{dir} can't be written. Check --log-dir.")
        end
      end

      it 'raises for a --log-file in a directory that does not exist' do
        log = File.join(dir, 'missing', 'custom.log')

        expect { described_class.choose_log(char: 'Mahtra', log_dir: dir, log_file: log) }
          .to raise_error(described_class::LogNotWritableError, /: the directory .*missing doesn't exist\. Check --log-file\.\z/)
      end

      it 'raises for a read-only --log-file' do
        log = File.join(dir, 'custom.log')
        File.write(log, '')

        read_only(log) do
          expect { described_class.choose_log(log_file: log) }
            .to raise_error(described_class::LogNotWritableError,
                            "Can't write the log file #{log}: permission denied. Check --log-file.")
        end
      end

      it 'raises for a --log-file whose directory is a file' do
        File.write(File.join(dir, 'afile'), '')
        log = File.join(dir, 'afile', 'x.log')

        expect { described_class.choose_log(log_file: log) }
          .to raise_error(described_class::LogNotWritableError,
                          "Can't write the log file #{log}: #{File.join(dir, 'afile')} is not a directory. Check --log-file.")
      end

      # A link is followed before the checks: these all used to pass the
      # check and then fail to open, so every log line of the session was
      # lost.
      describe 'given as a link' do
        it 'raises for a link to a file in a directory that does not exist' do
          log = File.join(dir, 'link.log')
          File.symlink(File.join(dir, 'gone', 'x.log'), log)

          expect { described_class.choose_log(log_file: log) }
            .to raise_error(described_class::LogNotWritableError,
                            "Can't write the log file #{log}: no such file or directory. Check --log-file.")
        end

        it 'raises for a link to a file in a read-only directory, naming that directory' do
          target_dir = File.join(dir, 'ro')
          FileUtils.mkdir(target_dir)
          log = File.join(dir, 'link.log')
          File.symlink(File.join(target_dir, 'x.log'), log)

          read_only(target_dir) do
            expect { described_class.choose_log(log_file: log) }
              .to raise_error(described_class::LogNotWritableError,
                              "Can't write the log file #{log}: the directory #{target_dir} can't be written. Check --log-file.")
          end
        end

        it 'raises for a link loop' do
          log = File.join(dir, 'loop1')
          File.symlink(File.join(dir, 'loop2'), log)
          File.symlink(log, File.join(dir, 'loop2'))

          expect { described_class.choose_log(log_file: log) }
            .to raise_error(described_class::LogNotWritableError, /: too many levels of symbolic links\. Check --log-file\.\z/)
        end

        it 'accepts a link to a writable file, and a link to a new file in a writable directory, creating nothing' do
          target = File.join(dir, 'real.log')
          File.write(target, '')
          File.symlink(target, File.join(dir, 'to-file.log'))
          File.symlink(File.join(dir, 'new.log'), File.join(dir, 'to-new.log'))

          expect(described_class.choose_log(log_file: File.join(dir, 'to-file.log'))).to eq [File.join(dir, 'to-file.log'), nil]
          expect(described_class.choose_log(log_file: File.join(dir, 'to-new.log'))).to eq [File.join(dir, 'to-new.log'), nil]
          expect(File.exist?(File.join(dir, 'new.log'))).to be false
        end
      end

      it 'raises for a --log-dir that can be written but not searched' do
        skip_for_root
        no_search = File.join(dir, 'no-search')
        FileUtils.mkdir(no_search)
        FileUtils.chmod(0o200, no_search)

        expect { described_class.choose_log(log_dir: no_search) }
          .to raise_error(described_class::LogNotWritableError, /: permission denied\. Check --log-dir\.\z/)
      end

      # Under LANG=C the command line comes in as bytes; the reason must not
      # depend on the path's encoding being valid.
      it 'gives the reason for a path that is not valid in its encoding' do
        skip_for_root
        no_search = File.join(dir, 'no-search')
        FileUtils.mkdir(no_search)
        FileUtils.chmod(0o200, no_search)
        log = File.join(no_search, "caf#{[0xFF].pack('C')}.log").force_encoding(Encoding::US_ASCII)

        expect { described_class.choose_log(log_file: log) }.to raise_error(described_class::LogNotWritableError) do |error|
          expect(error.message.b).to end_with(": permission denied. Check --log-file.")
        end
      end

      it 'names a read-only directory by the path given, even through a linked parent' do
        target = File.join(dir, 'ro')
        FileUtils.mkdir(target)
        File.symlink(target, File.join(dir, 'link-to-ro'))
        log = File.join(dir, 'link-to-ro', 'x.log')

        read_only(target) do
          expect { described_class.choose_log(log_file: log) }
            .to raise_error(described_class::LogNotWritableError,
                            "Can't write the log file #{log}: the directory #{File.join(dir, 'link-to-ro')} " \
                            "can't be written. Check --log-file.")
        end
      end

      it 'raises for a --log-file whose name is too long' do
        log = File.join(dir, "#{'a' * 300}.log")

        expect { described_class.choose_log(log_file: log) }
          .to raise_error(described_class::LogNotWritableError, /: file name too long\. Check --log-file\.\z/)
      end

      it 'raises for a --log-file that is a directory' do
        expect { described_class.choose_log(log_file: dir) }
          .to raise_error(described_class::LogNotWritableError, "Can't write the log file #{dir}: it is a directory. Check --log-file.")
      end
    end
  end
end
