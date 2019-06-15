module Settings
  @lock = Mutex.new

  APP_DIR = Dir.home + "/.profanity"
	##
	## setup app dir
	##
	FileUtils.mkdir_p APP_DIR

	def self.file(path)
		APP_DIR + "/" + path
	end

  def self.read(file)
    @lock.synchronize do
      return File.read(file)
    end
  end

  def self.from_xml(file)
    bin = Settings.read(file)
    REXML::Document.new(bin).root
  end
end