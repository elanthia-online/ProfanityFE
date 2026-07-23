# frozen_string_literal: true

require 'fileutils'
require 'json'

=begin
Application settings directory and file management for ProfanityFE.
Manages the ~/.profanity/ directory structure for config, logs, and state.
=end

# Manages the ProfanityFE application directory at +~/.profanity/+.
#
# Provides file path resolution, thread-safe read/write, and automatic
# directory creation. Used for templates, logs, and persistent state
# (e.g., mouse scroll wheel calibration).
#
# @example
#   ProfanitySettings.file('debug.log')       #=> "/home/user/.profanity/debug.log"
#   ProfanitySettings.file('mahtra.xml')      #=> "/home/user/.profanity/mahtra.xml"
#   ProfanitySettings.resolve_template('Mahtra', app_dir: '/path/to/profanity')
module ProfanitySettings
  @lock = Mutex.new

  # @return [String] the application data directory
  APP_DIR = File.join(Dir.home, '.profanity')

  # Create the app directory if it doesn't exist
  FileUtils.mkdir_p(APP_DIR)

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

  # Thread-safe file write.
  #
  # @param path [String] full path to write
  # @param data [String] content to write
  # @return [void]
  def self.write(path, data)
    @lock.synchronize { File.write(path, data) }
  end

  # Parse an XML settings file. Thread-safe — reads and parses
  # under the same lock to prevent concurrent mutation.
  #
  # @param path [String] full path to XML file
  # @return [REXML::Element] the root element
  def self.from_xml(path)
    @lock.synchronize do
      bin = File.read(path)
      REXML::Document.new(bin).root
    end
  end

  # Resolve the template/settings file path using EO-compatible logic.
  #
  # Search order for --char=Name:
  #   1. ~/.profanity/name.xml (user's personal config)
  #   2. <app_dir>/templates/name.xml (bundled template)
  #   3. <app_dir>/templates/default.xml (fallback)
  #
  # @param char [String, nil] character name from --char flag
  # @param template [String, nil] explicit template filename from --template flag
  # @param settings_file [String, nil] explicit path from --settings-file flag
  # @param app_dir [String] the ProfanityFE installation directory
  # @return [String] resolved full path to the settings XML
  def self.resolve_template(char: nil, template: nil, settings_file: nil, app_dir: '.')
    # Explicit --settings-file takes absolute precedence
    if settings_file
      path = File.expand_path(settings_file)
      return path if File.exist?(path)

      $stderr.puts "Settings file not found: #{path}"
      exit 1
    end

    # Explicit --template=filename.xml
    if template
      path = File.join(app_dir, 'templates', template.downcase)
      return path if File.exist?(path)

      $stderr.puts "Template not found: #{path}"
      exit 1
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

    # Legacy fallback: ~/.profanity.xml
    legacy = File.expand_path('~/.profanity.xml')
    return legacy if File.exist?(legacy)

    $stderr.puts 'No settings file found. Use --char=<name>, --template=<file>, or --settings-file=<path>'
    $stderr.puts "Or create #{default}"
    exit 1
  end

  # Resolve the log file path.
  #
  # @param char [String, nil] character name
  # @param log_file [String, nil] explicit --log-file path
  # @param log_dir [String, nil] explicit --log-dir path
  # @return [String] resolved full path to the log file
  def self.resolve_log(char: nil, log_file: nil, log_dir: nil)
    return File.expand_path(log_file) if log_file
    return File.join(File.expand_path(log_dir), DEFAULT_LOG_FILE) if log_dir

    if char
      file("#{char.downcase}.log")
    else
      DEFAULT_LOG_FILE
    end
  end

  # Load mouse scroll settings from settings.json.
  #
  # @return [Hash, nil] parsed settings or nil if file doesn't exist
  def self.load_mouse_settings
    path = file('settings.json')
    return nil unless File.exist?(path)

    JSON.parse(read(path))
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
