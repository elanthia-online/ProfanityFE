require_relative "../settings/settings.rb"

module Loader
  def loaded
    @_loaded ||= []
  end

  def fetch(file:, flush: true)
    Profanity.log("[Loader.load] >> #{file}") if Opts.debug
    # prevent cyclical references
    return if loaded.include?(file) and not flush
    # reset on load
    loaded.clear() if flush
    # track for future references
    loaded.push(file)
    # do the dew
    begin
      Profanity.log("[Loader.load] >> #{file}") if Opts.debug
      yield Settings.from_xml(file)
    rescue => exception
      # todo: write useful trace to UI
      Profanity.log("Error(#{file})")
      Profanity.log(exception.message)
      Profanity.log(exception.backtrace)
    end
  end
end