# frozen_string_literal: true

# cli_options.rb: command-line option parsing for profanity.rb.
#
# Parsed before curses starts, so a bad option or --help prints to the
# normal terminal instead of the curses screen.

require 'optparse'
require_relative 'version'
require_relative 'games'

# Command-line options for profanity.rb.
module CliOptions
  # Raised by {parse_command_line} for a bad command line. The message is
  # what profanity.rb prints to stderr before it exits 1.
  class UsageError < StandardError; end

  # Option values used when an option is not given on the command line.
  DEFAULTS = {
    port: 8000,
    host: '127.0.0.1',
    default_color_id: 7,
    default_background_color_id: 0,
    use_default_colors: false,
    custom_colors: nil,
    settings_file: nil,
    log_dir: nil,
    log_file: nil,
    char: nil,
    config: nil,
    template: nil,
    no_status: false,
    links: false,
    speech_ts: false,
    room_window_only: false,
    remote_url: false,
    log_gags: false,
    profile: false,
    game: nil,
  }.freeze

  # Parse the command line into an options hash.
  #
  # OptionParser accepts any unambiguous abbreviation of a long option
  # (+--prof+ for +--profile+), so the returned hash, not ARGV, is the
  # only place to read an option from.
  #
  # @param argv [Array<String>] command-line arguments; parsed options are
  #   removed from it
  # @return [Hash{Symbol => Object}] {DEFAULTS} overridden by the given options
  # @raise [OptionParser::ParseError] on an unknown, ambiguous or invalid option
  def self.parse(argv)
    options = DEFAULTS.dup
    parser(options).parse!(argv)
    options
  end

  # Parse the command line; on a bad option, raise {UsageError} carrying
  # the error and a usage hint.
  #
  # @param argv [Array<String>] command-line arguments; parsed options are
  #   removed from it
  # @param program [String] program name shown in the error and hint
  # @return [Hash{Symbol => Object}] the options from {parse}
  # @raise [UsageError] on an unknown, ambiguous or invalid option
  # @raise [SystemExit] with status 0 after printing --help (OptionParser's
  #   built-in --help does that)
  def self.parse_command_line(argv, program: File.basename($PROGRAM_NAME))
    parse(argv)
  rescue OptionParser::ParseError => e
    raise UsageError, "#{program}: #{e.message}\n" \
                      "Try '#{program} --help' for the list of options."
  end

  # Build the OptionParser that fills in +options+.
  #
  # @param options [Hash{Symbol => Object}] hash the option handlers write to
  # @return [OptionParser]
  def self.parser(options)
    OptionParser.new do |opts|
      opts.banner = "\nProfanity FrontEnd v#{VERSION}\n\n"

      opts.on('--char=NAME', 'Character name (for log file & process title)') { |v| options[:char] = v }
      opts.on('--config=NAME', 'Config name to load (default: same as --char)') { |v| options[:config] = v }
      opts.on('--template=FILE', 'Template file name (from templates/)') { |v| options[:template] = v }
      opts.on('--port=PORT', Integer, 'Game server port (default: 8000)') { |v| options[:port] = v }
      opts.on('--host=HOST', 'Game server host (default: 127.0.0.1)') { |v| options[:host] = v }
      opts.on('--default-color-id=ID', Integer, 'Default foreground color (default: 7)') { |v| options[:default_color_id] = v }
      opts.on('--default-background-color-id=ID', Integer, 'Default background color (default: 0)') { |v| options[:default_background_color_id] = v }
      opts.on('--custom-colors=MODE', %w[on off yes no], 'Force custom color mode (on/off/yes/no)') do |v|
        options[:custom_colors] = %w[on yes].include?(v)
      end
      opts.on('--use-default-colors', 'Use terminal default colors') { options[:use_default_colors] = true }
      opts.on('--no-status', 'Disable process title updates') { options[:no_status] = true }
      opts.on('--links', 'Enable in-game link highlighting') { options[:links] = true }
      opts.on('--speech-ts', 'Add timestamps to speech, familiar, and thought windows') { options[:speech_ts] = true }
      opts.on('--room-window-only', 'Do not echo room data to the story window') { options[:room_window_only] = true }
      opts.on('--remote-url', 'Display LaunchURLs on screen instead of opening browser') { options[:remote_url] = true }
      opts.on('--log-gags', 'Log every gagged line in full (diagnostics)') { options[:log_gags] = true }
      opts.on('--log-file=PATH', 'Log file path (default: profanity.log)') { |v| options[:log_file] = v }
      opts.on('--log-dir=DIR', 'Log directory (default: current directory)') { |v| options[:log_dir] = v }
      opts.on('--settings-file=FILE', 'Settings XML file path (overrides --char/--config lookup)') { |v| options[:settings_file] = v }
      opts.on('--profile', 'Log boot timing to log file') { options[:profile] = true }
      opts.on('--game=CODE', "Game's rules only: DR or GS (Lich codes like GS4 work; default: both)") do |v|
        raise OptionParser::InvalidArgument, v unless Games.known_code?(v)

        options[:game] = v.upcase
      end
    end
  end
  private_class_method :parser
end
