require_relative "../settings/settings.rb"

module Hilite
  @map     = Hash.new
  @loaded  = Array.new

  def self.pointer()
    @map
  end

  def self.load(file:, flush: true)
    # prevent cyclical references
    return if @loaded.include?(file) and not flush
    # reset on load
    if flush
      @loaded.clear()
      @map.clear()
    end
    # track for future references
    @loaded.push(file)
    # do the dew
    begin
      Profanity.log("[Settings] loading #{file}") if Opts.debug
      xml = Settings.from_xml(file)
  
      xml.elements
        .select do |ele| ele.name.eql?("highlight") end
        .each do |highlight| Hilite.parse(highlight: highlight, parent: file) end
      
      return xml
    rescue => exception
      # todo: write useful trace to UI
      Profanity.log("Error(#{file})")
      Profanity.log(exception.message)
      Profanity.log(exception.backtrace)
    end
  end

  def self.parse(highlight:, parent:)
    return Hilite.inherit(file: highlight.attributes["inherit"], parent: parent) if highlight.attributes["inherit"]
    return Hilite.put(highlight)
  end

  def self.inherit(file:, parent:)
    Profanity.log("[Settings] inheriting #{file} from #{parent}") if Opts.debug
    Hilite.load(
      file:  File.join(File.dirname(parent), file),
      flush: false)
  end

  def self.put(highlight)
    begin
      pattern = %r{#{highlight.text.strip}}
      @map[pattern] = [ 
        highlight.attributes["fg"], 
        highlight.attributes["bg"], 
        highlight.attributes["ul"]]  
    rescue => exception
      # todo: write useful error/backtrace to UI
      Profanity.log(highlight.text)
      Profanity.log(exception.message)
      Profanity.log(exception.backtrace)
    end
  end

  def self.respond_to_missing?(method)
    return true if @map.respond_to?(method)
    super
  end

  def self.method_missing(method, *args, &block)
    return @map.send(method, *args, &block) if @map.respond_to?(method)
    super
  end
end