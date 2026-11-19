# frozen_string_literal: true

# ruby_advisory.rb: whether the running Ruby has the Regexp and String
# security bugs that Ruby 4.0.10, 3.4.13 and 3.3.14 fixed on 2026-11-18,
# and the warning to show the user if it does.
#
# Requiring this file loads nothing else.

# The Ruby security advisory of 2026-11-18 (seven bugs in regular
# expressions and string case conversion). profanity.rb asks for
# {.warning} once at startup, and {Application} shows it in the main
# window once.
#
# Ruby 3.3.13 and earlier, 3.4.0 to 3.4.12 and 4.0.0 to 4.0.9 are
# affected; Ruby 3.2 and earlier are past their end of life and get no
# fix. Only CRuby (+RUBY_ENGINE+ "ruby") is checked: the bugs are in its
# own regular expression engine.
#
# @example
#   RubyAdvisory.warning(version: '4.0.9')
#   # => ["Ruby 4.0.9 has security bugs in regular expressions and strings, fixed in Ruby 4.0.10. Please upgrade Ruby.",
#   #     "Details: https://www.ruby-lang.org/en/news/2026/11/18/multiple-vulnerabilities-in-regexp-and-string/"]
#   RubyAdvisory.warning(version: '4.0.10') # => nil
module RubyAdvisory
  # The advisory, on ruby-lang.org.
  URL = 'https://www.ruby-lang.org/en/news/2026/11/18/multiple-vulnerabilities-in-regexp-and-string/'

  # The first fixed release of each series that got a fix, by series
  # ("major.minor").
  FIXED_RELEASES = { '3.3' => '3.3.14', '3.4' => '3.4.13', '4.0' => '4.0.10' }.freeze

  # The release to upgrade to from a series older than all of
  # {FIXED_RELEASES}, which gets no fix.
  NEWEST_FIXED_RELEASE = '4.0.10'

  # The oldest series with a fix. Older series are past their end of life
  # and are affected.
  OLDEST_FIXED_SERIES = Gem::Version.new('3.3')

  # The warning for a Ruby that has the bugs, or nil for one that
  # doesn't: a release at or after its series' fix, a series newer than
  # 4.0, a Ruby other than CRuby, or a version that can't be read.
  #
  # @param version [String] the Ruby version, such as "4.0.9"
  # @param engine [String] the Ruby implementation, such as "ruby"
  # @return [Array<String>, nil] the warning's lines, or nil
  def self.warning(version: RUBY_VERSION, engine: RUBY_ENGINE)
    return nil unless engine == 'ruby'

    fix = fixed_release(version)
    fix && ["Ruby #{version} has security bugs in regular expressions and strings, fixed in Ruby #{fix}. " \
            'Please upgrade Ruby.',
            "Details: #{URL}"]
  end

  # The release that fixes the bugs for +version+, or nil when +version+
  # doesn't have them or can't be read.
  #
  # @param version [String] the Ruby version
  # @return [String, nil] the fixed release to upgrade to, or nil
  def self.fixed_release(version)
    release = Gem::Version.new(version)
    series = release.segments.first(2).join('.')
    fix = FIXED_RELEASES[series]
    return (release < Gem::Version.new(fix) ? fix : nil) if fix

    NEWEST_FIXED_RELEASE if release < OLDEST_FIXED_SERIES
  rescue ArgumentError
    nil
  end
  private_class_method :fixed_release
end
