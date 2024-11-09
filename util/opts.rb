class Opts
  FLAG_PREFIX = "--"
  attr_reader :port, :char, :host, :default_color_id, :default_background_color_id, :template

  def initialize(command_line_args)
    config = parse_config(command_line_args)
  
    @port = config.fetch('port', 8000).to_i
    @char = config['char']
    @host = config.fetch('host', '127.0.0.1')
    @default_color_id = config.fetch('default-color-id', 7).to_i
    @default_background_color_id = config.fetch('default-background-color-id', 0).to_i
    @template = config['template']
  end

  def parse_config(command_line_args)
    command_line_args.each_with_object({}) do |arg, config|
      key, value = arg.split('=', 2) # Use split with limit to avoid extra splits
      config[key.gsub(/[-–—]/, '')] = value
    end
  end

  def links
    nil
  end

  def self.parse_command(h, c)
    h[c.to_sym] = true
  end

  def self.parse_flag(h, f)
    (name, val) = f[2..-1].split("=")
    if val.nil?
      h[name.to_sym] = true
    else
      val = val.split(",")

      h[name.to_sym] = val.size == 1 ? val.first : val
    end
  end
end
