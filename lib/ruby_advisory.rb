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

  # The release to upgrade to from a series that gets no fix: one past its
  # end of life (3.2 and earlier) or a preview series (3.5).
  NEWEST_FIXED_RELEASE = '4.0.10'

  # A Ruby version as +RUBY_VERSION+ gives it: three numbers, then
  # possibly a prerelease part ("4.1.0.dev").
  VERSION_FORMAT = /\A\d+\.\d+\.\d+(?:\.[0-9A-Za-z]+)*\z/

  # The warning for a Ruby that has the bugs, or nil for one that
  # doesn't: a release at or after its series' fix, a release after
  # {NEWEST_FIXED_RELEASE} in a series without a fix of its own (4.1 and
  # later), a Ruby other than CRuby, or a version not in
  # {VERSION_FORMAT}.
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

  # The release that fixes the bugs for +version+: its series' fix, or
  # {NEWEST_FIXED_RELEASE} for an older series without one. Nil when
  # +version+ doesn't have the bugs or is not in {VERSION_FORMAT}.
  #
  # @param version [String] the Ruby version
  # @return [String, nil] the fixed release to upgrade to, or nil
  def self.fixed_release(version)
    return nil unless version.is_a?(String) && version.match?(VERSION_FORMAT)

    release = Gem::Version.new(version)
    fix = FIXED_RELEASES[release.segments.first(2).join('.')] || NEWEST_FIXED_RELEASE
    fix if release < Gem::Version.new(fix)
  end
  private_class_method :fixed_release
end
