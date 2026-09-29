# frozen_string_literal: true

require_relative 'platform'

# Opens a LaunchURL in the system browser.
#
# Only the browser command lives here. Which URLs reach it is decided
# where the tag is read: {TagHandlers#handle_launch_url} drops anything
# that isn't an https URL on www.play.net before emitting +:launch_url+.
#
# @example
#   UrlLauncher.open('https://www.play.net/dr/')
module UrlLauncher
  # The browser command for +url+ on a system, as an argument list for
  # +Process.spawn+ (never a shell string).
  #
  # @param url [String] the URL to open; always the last argument, as is
  # @param os [Symbol, nil] the system, as {Platform.os} names it
  # @return [Array<String>, nil] the command and its arguments, or nil on
  #   a system with no known browser command
  def self.command(url, os = Platform.os)
    case os
    when :macos then ['open', url]
    when :unix then ['xdg-open', url]
    when :windows then ['rundll32', 'url.dll,FileProtocolHandler', url]
    end
  end

  # Open a URL in the system browser without blocking the caller.
  #
  # The command is spawned as an argument list, so the URL is never parsed
  # by a shell: characters such as +$(...)+ or backticks in a server-supplied
  # URL stay literal. Does nothing on a system {.command} doesn't know. A
  # command that can't be started is logged, not raised.
  #
  # @param url [String] the URL to open
  # @return [void]
  def self.open(url)
    command = command(url)
    return unless command

    Process.detach(Process.spawn(*command, out: File::NULL, err: File::NULL))
  rescue SystemCallError => e
    ProfanityLog.write('launch_url', "could not open #{url}: #{e.message}")
  end
end
