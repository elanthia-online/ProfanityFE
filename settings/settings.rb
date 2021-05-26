module Settings
  @lock = Mutex.new

  APP_DIR = File.expand_path(File.dirname($0))
	##
	## setup app dir
	##
	FileUtils.mkdir_p APP_DIR + "/debug"
	FileUtils.mkdir_p APP_DIR + "/profiles"
	
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
    orig = APP_DIR + "/templates/default.xml"
    dest = APP_DIR + "/profiles/" + char

    File.write(dest, File.read(orig)) if !File.file?(dest)
       
    dest
      
  end
  

end
