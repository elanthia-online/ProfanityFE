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
#   ProfanitySettings.resolve_template(char: 'Mahtra', app_dir: '/path/to/profanity')
module ProfanitySettings
  @lock = Mutex.new

  # Raised by {resolve_template} when no settings file can be found. The
  # message is what profanity.rb prints to stderr before it exits 1.
  class NotFoundError < StandardError; end

  # Raised by {choose_log} when the log file can't be written. The message
  # is what profanity.rb prints to stderr before it exits 1.
  class LogNotWritableError < StandardError; end

  # @return [String] the application data directory
  APP_DIR = File.join(Dir.home, '.profanity')

  # The file every save of settings.json locks while it reads, changes and
  # writes it (see {update_settings}).
  SETTINGS_LOCK_FILE = 'settings.lock'

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
  #   (profanity.rb passes its own directory, which is relative when it
  #   was started with a relative path)
  # @return [String] path to the settings XML: absolute for
  #   --settings-file and ~/.profanity/, otherwise under +app_dir+ (so
  #   relative when +app_dir+ is)
  # @raise [NotFoundError] if --settings-file or --template names a file
  #   that doesn't exist (or --settings-file starts with the home directory
  #   of a user that doesn't exist), or no settings file is found at all
  def self.resolve_template(char: nil, template: nil, settings_file: nil, app_dir: '.')
    # Explicit --settings-file takes absolute precedence
    if settings_file
      begin
        path = File.expand_path(settings_file)
      rescue ArgumentError => e # ~nosuchuser: "user nosuchuser doesn't exist"
        raise NotFoundError, "Settings file not found: #{settings_file}: #{e.message}"
      end
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

  # Choose the log file for this session: the {resolve_log} path, checked
  # before curses starts so that a log that can't be written is reported
  # on the normal terminal instead of each log line being drawn over the
  # client's screen.
  #
  # A --log-file or --log-dir that can't be written is an error, like a bad
  # option. The default path (+profanity.log+ in the current directory, or
  # +<char>.log+ in {APP_DIR}) that can't be written falls back to
  # {DEFAULT_LOG_FILE} in {APP_DIR}, with a notice saying so. Nothing is
  # created: the checks only ask whether the file could be written.
  #
  # @param char [String, nil] character name
  # @param log_file [String, nil] explicit --log-file path
  # @param log_dir [String, nil] explicit --log-dir path
  # @return [Array(String, String)] the log path, and a notice for stderr
  #   when the default path was replaced
  # @return [Array(String, nil)] the log path when it is the one asked for
  # @raise [LogNotWritableError] if the given log path, or both the default
  #   and the fallback, can't be written, or the given path starts with the
  #   home directory of a user that doesn't exist (+~nosuchuser/x.log+)
  def self.choose_log(char: nil, log_file: nil, log_dir: nil)
    option = log_file ? '--log-file' : '--log-dir'
    given = log_file || log_dir
    begin
      File.expand_path(given) if given
    rescue ArgumentError => e
      # ~nosuchuser: "user nosuchuser doesn't exist"
      raise LogNotWritableError, "Can't write the log file #{given}: #{e.message}. Check #{option}."
    end
    path = resolve_log(char: char, log_file: log_file, log_dir: log_dir)
    problem = log_problem(path)
    return [path, nil] unless problem

    raise LogNotWritableError, "Can't write the log file #{path}: #{problem}. Check #{option}." if log_file || log_dir

    fallback = file(DEFAULT_LOG_FILE)
    if log_problem(fallback)
      raise LogNotWritableError, "Can't write the log file #{path}: #{problem}. " \
                                 'Use --log-file=<path> or --log-dir=<dir> to choose one that can be written.'
    end
    [fallback, "Can't write the log file #{path}: #{problem}. Logging to #{fallback} instead."]
  end

  # Why the log file at +path+ can't be written, or nil if it can. Only
  # asks the file system; creates nothing.
  #
  # Symbolic links are followed first, so the checks are on the file that
  # would be opened: a link to a file in a directory that doesn't exist,
  # a link loop, a directory that can't be searched or a name that is too
  # long fail here, as opening the file would. (A file system can still
  # refuse a name these checks allow, such as one that isn't valid UTF-8
  # on APFS.)
  #
  # @param path [String] absolute path of the log file
  # @return [String, nil] the reason, or nil
  def self.log_problem(path)
    dir = File.dirname(path)
    return "#{dir} is not a directory" if File.exist?(dir) && !File.directory?(dir)
    return "the directory #{dir} doesn't exist" unless File.directory?(dir)

    begin
      real = File.realdirpath(path)
    rescue SystemCallError => e
      # The system's text for the error alone ("Too many levels of symbolic
      # links"): e.message also holds the path, in whatever encoding it
      # came in, which may not be valid.
      reason = SystemCallError.new(nil, e.errno).message
      return reason[0].downcase + reason[1..]
    end
    return 'it is a directory' if File.directory?(real)
    # A named pipe would block the first write, and a terminal (such as
    # /dev/stderr) is the screen curses draws on. /dev/null is the one
    # other file that makes sense, for no log at all.
    return 'it is not a regular file' if File.exist?(real) && !File.file?(real) && real != File::NULL
    return (File.writable?(real) ? nil : 'permission denied') if File.exist?(real)

    # Name the directory the user gave, unless the file itself is a link to
    # somewhere else.
    real_dir = File.dirname(real)
    shown_dir = File.symlink?(path) ? real_dir : dir
    File.writable?(real_dir) ? nil : "the directory #{shown_dir} can't be written"
  end
  private_class_method :log_problem

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
    update_settings do |settings|
      settings['BUTTON4_PRESSED_MASK'] = button4_mask
      settings['BUTTON5_PRESSED_MASK'] = button5_mask
    end
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
    update_settings { |settings| settings[key] = value }
  end

  # Read settings.json, let the block change it and write it back, holding
  # an exclusive lock on {SETTINGS_LOCK_FILE} the whole time. Every
  # Profanity process shares the one settings.json, so without the lock two
  # saves that overlap (two characters' clients, say) could each read the
  # file before the other wrote it, and the later write would drop the key
  # the earlier one saved. The lock is on a file of its own because
  # {write} replaces settings.json by renaming, so a lock on settings.json
  # itself would be on a file that is no longer there.
  #
  # @yieldparam settings [Hash] the current settings (empty when the file is
  #   absent or unreadable), to change in place
  # @return [void]
  # @raise [SystemCallError] if the lock file can't be opened or
  #   settings.json can't be written; settings.json is then unchanged
  def self.update_settings
    File.open(file(SETTINGS_LOCK_FILE), File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      settings = load_mouse_settings || {}
      yield settings
      write(file('settings.json'), JSON.pretty_generate(settings))
    end
  end
end
