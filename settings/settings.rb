module Settings
  @lock = Mutex.new

  APP_DIR = File.expand_path(File.dirname($0))
	##
	## setup app dir
	##
	FileUtils.mkdir_p APP_DIR + "/debug"

	def self.file(path)
		APP_DIR + "/debug/" + path
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
  
  def self.profile(char)
    path = APP_DIR + "/templates"
    orig = path + "/default.xml"
    dest = path + "/" + char

    File.write(dest, File.read(orig)) if !File.file?(dest)
       
    dest
      
  end
  

end