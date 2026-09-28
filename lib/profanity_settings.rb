# frozen_string_literal: true

require 'fileutils'
require 'json'
# DEFAULT_LOG_FILE: profanity.rb resolves the log path before it loads the
# rest of lib (and before curses starts), so load it here.
require_relative 'constants'

=begin
Application settings directory and file management for ProfanityFE.
Manages the ~/.profanity/ directory structure for config, logs, and state.
=end

# Manages the ProfanityFE application directory at +~/.profanity/+.
#
# Provides file path resolution, thread-safe read/write, and directory
# creation ({ensure_app_dir}). Used for templates, logs, and persistent state
# (e.g., mouse scroll wheel calibration).
#
# @example
#   ProfanitySettings.file('debug.log')       #=> "/home/user/.profanity/debug.log"
#   ProfanitySettings.file('mahtra.xml')      #=> "/home/user/.profanity/mahtra.xml"
#   ProfanitySettings.resolve_template('Mahtra', app_dir: '/path/to/profanity')
module ProfanitySettings
  @lock = Mutex.new

  # Raised by {resolve_template} when no settings file can be found. The
  # message is what profanity.rb prints to stderr before it exits 1.
  class NotFoundError < StandardError; end

  # @return [String] the application data directory
  APP_DIR = File.join(Dir.home, '.profanity')

  # Create {APP_DIR} if it doesn't exist. profanity.rb calls this at
  # startup, before anything is written there (log, settings cache,
  # settings.json, selection.txt); requiring this file doesn't create it.
  #
  # @return [void]
  # @raise [SystemCallError] if the directory can't be created
  def self.ensure_app_dir
    FileUtils.mkdir_p(APP_DIR)
  end

  # Resolve a file path within the app directory.
  #
  # @param path [String] relative file name
  # @return [String] full path under ~/.profanity/
  def self.file(path)
    File.join(APP_DIR, path)
  end

  # Thread-safe file read.
  #
  # @param path [String] full path to read
  # @return [String] file contents
  def self.read(path)
    @lock.synchronize { File.read(path) }
  end

  # Thread-safe, atomic file write: the data goes to a temporary file in the
  # same directory, which is then renamed over +path+, so a reader or a crash
  # never sees a partly written file. An existing file keeps its mode (a new
  # one gets 0666 less the umask), and a symlink is written through, as
  # File.write would.
  #
  # @param path [String] full path to write
  # @param data [String] content to write
  # @return [void]
  # @raise [SystemCallError] if the file can't be written; +path+ is unchanged
  def self.write(path, data)
    @lock.synchronize do
      target = File.exist?(path) ? File.realpath(path) : path
      mode = File.exist?(target) ? File.stat(target).mode & 0o7777 : 0o666 & ~File.umask
      tmp = "#{target}.#{Process.pid}.tmp"
      begin
        File.open(tmp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
          f.write(data)
          f.chmod(mode)
          f.fsync
        end
        File.rename(tmp, target)
      rescue StandardError
        FileUtils.rm_f(tmp)
        raise
      end
    end
  end

  # Resolve the template/settings file path using EO-compatible logic.
  #
  # Search order for --char=Name:
  #   1. ~/.profanity/name.xml (user's personal config)
  #   2. <app_dir>/templates/name.xml (bundled template)
  #   3. <app_dir>/templates/default.xml (fallback)
  #
  # Without --char, only step 3 applies. ~/.profanity.xml is never
  # consulted.
  #
  # @param char [String, nil] character name from --char flag
  # @param template [String, nil] explicit template filename from --template flag,
  #   looked up in <app_dir>/templates/ as typed, then lowercased
  # @param settings_file [String, nil] explicit path from --settings-file flag
  # @param app_dir [String] the ProfanityFE installation directory
  # @return [String] resolved full path to the settings XML
  # @raise [NotFoundError] if --settings-file or --template names a file
  #   that doesn't exist, or no settings file is found at all
  def self.resolve_template(char: nil, template: nil, settings_file: nil, app_dir: '.')
    # Explicit --settings-file takes absolute precedence
    if settings_file
      path = File.expand_path(settings_file)
      return path if File.exist?(path)

      raise NotFoundError, "Settings file not found: #{path}"
    end

    # Explicit --template=filename.xml, as typed; then lowercased, which is
    # how it was always looked up, so a capitalised name keeps finding the
    # lowercase bundled templates on case-sensitive filesystems.
    if template
      path = File.join(app_dir, 'templates', template)
      return path if File.exist?(path)

      lowercase = File.join(app_dir, 'templates', template.downcase)
      return lowercase if File.exist?(lowercase)

      raise NotFoundError, "Template not found: #{path}"
    end

    # --char=Name: search user dir, then bundled templates
    if char
      name = char.downcase
      user_config = file("#{name}.xml")
      return user_config if File.exist?(user_config)

      bundled = File.join(app_dir, 'templates', "#{name}.xml")
      return bundled if File.exist?(bundled)

      # Fall through to default
    end

    # Default template
    default = File.join(app_dir, 'templates', 'default.xml')
    return default if File.exist?(default)

    raise NotFoundError, "No settings file found. Use --char=<name>, --template=<file>, or --settings-file=<path>\n" \
                         "Or create #{default}"
  end

  # Resolve the log file path.
  #
  # --log-file wins. Otherwise the file is named +<char>.log+ (lowercased)
  # with --char, or {DEFAULT_LOG_FILE} without, and is placed in --log-dir
  # when given, else in ~/.profanity/ (with --char) or the current
  # directory (without).
  #
  # @param char [String, nil] character name
  # @param log_file [String, nil] explicit --log-file path
  # @param log_dir [String, nil] explicit --log-dir path
  # @return [String] resolved absolute path to the log file
  def self.resolve_log(char: nil, log_file: nil, log_dir: nil)
    return File.expand_path(log_file) if log_file

    name = char ? "#{char.downcase}.log" : DEFAULT_LOG_FILE
    return File.join(File.expand_path(log_dir), name) if log_dir

    char ? file(name) : File.expand_path(name)
  end

  # Load mouse scroll settings from settings.json.
  #
  # A file that isn't valid JSON, or whose top level isn't an object, is
  # logged and treated as absent.
  #
  # @return [Hash, nil] parsed settings, or nil if the file doesn't exist or
  #   doesn't hold a JSON object
  def self.load_mouse_settings
    path = file('settings.json')
    return nil unless File.exist?(path)

    # UTF-8 whatever the locale: under LANG=C a non-ASCII character would
    # otherwise raise Encoding::InvalidByteSequenceError.
    settings = JSON.parse(read(path).force_encoding(Encoding::UTF_8))
    return settings if settings.is_a?(Hash)

    ProfanityLog.write('settings', "Ignoring settings.json: expected a JSON object, got #{JSON.generate(settings)[0, 40]}")
    nil
  rescue JSON::ParserError => e
    ProfanityLog.write('settings', "Failed to parse settings.json: #{e.message}")
    nil
  end

  # Save mouse scroll settings to settings.json, preserving any other
  # keys already stored there.
  #
  # @param button4_mask [Integer] scroll-up button mask
  # @param button5_mask [Integer] scroll-down button mask
  # @return [void]
  def self.save_mouse_settings(button4_mask, button5_mask)
    settings = load_mouse_settings || {}
    settings['BUTTON4_PRESSED_MASK'] = button4_mask
    settings['BUTTON5_PRESSED_MASK'] = button5_mask
    write(file('settings.json'), JSON.pretty_generate(settings))
  end

  # Read a single value from settings.json.
  #
  # @param key [String] setting name
  # @param default [Object] value returned when the file or key is absent
  # @return [Object] the stored value or the default
  def self.load_setting(key, default)
    settings = load_mouse_settings
    return default unless settings&.key?(key)

    settings[key]
  end

  # Write a single value to settings.json, preserving other keys.
  #
  # @param key [String] setting name
  # @param value [Object] JSON-serializable value
  # @return [void]
  def self.save_setting(key, value)
    settings = load_mouse_settings || {}
    settings[key] = value
    write(file('settings.json'), JSON.pretty_generate(settings))
  end
end
