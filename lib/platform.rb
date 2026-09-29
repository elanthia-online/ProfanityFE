# frozen_string_literal: true

require 'rbconfig'

# The operating system ProfanityFE runs on, read from Ruby's +host_os+.
# Used to pick the browser command for LaunchURL
# ({WindowManager#open_in_browser}) and the clipboard command
# ({SelectionManager#copy_to_clipboard}).
#
# @example
#   Platform.os # => :macos on a Mac
module Platform
  # The operating system family, checked in this order: +darwin+ is
  # +:macos+, +linux+ or +bsd+ is +:unix+, +mswin+, +mingw+ or +cygwin+ is
  # +:windows+.
  #
  # @param host_os [String] the +host_os+ to classify; defaults to
  #   +RbConfig::CONFIG['host_os']+, read on every call
  # @return [Symbol, nil] +:macos+, +:unix+, +:windows+, or nil for any
  #   other system
  def self.os(host_os = RbConfig::CONFIG['host_os'])
    case host_os
    when /darwin/ then :macos
    when /linux|bsd/ then :unix
    when /mswin|mingw|cygwin/ then :windows
    end
  end
end
