require_relative "../settings/settings.rb"
require_relative "../util/kvstore.rb"
require_relative "../util/loader.rb"

module Hilite
  extend KVStore
  extend Loader

  def self.load(file:, flush: true)
    Hilite.fetch(file: file, flush: flush) do |xml|
      store.clear() if flush
     
      xml.elements
        .select do |ele| ele.name.eql?("highlight") end
        .each do |highlight| Hilite.parse(highlight: highlight, parent: file) end
        
      return xml
    end
  end

  def self.parse(highlight:, parent:)
    return Hilite.inherit(file: highlight.attributes["inherit"], parent: parent) if highlight.attributes["inherit"]
    return Hilite.add_highlight(highlight)
  end

  def self.inherit(file:, parent:)
    Profanity.log("[Settings] inheriting #{file} from #{parent}") if Opts.debug
    Hilite.load(
      file:  File.join(File.dirname(parent), file),
      flush: false)
  end

  def self.add_highlight(highlight)
    begin
      pattern = %r{#{highlight.text.strip}}
      Hilite.put(pattern, [ 
        highlight.attributes["fg"], 
        highlight.attributes["bg"], 
        highlight.attributes["ul"]])
    rescue => exception
      # todo: write useful error/backtrace to UI
      Profanity.log(highlight.text)
      Profanity.log(exception.message)
      Profanity.log(exception.backtrace)
    end
  end
end