class PercWindow < Curses::Window
  attr_reader :color_stack, :buffer
  attr_accessor :scrollbar, :indent_word_wrap, :layout, :time_stamp

  @@list = []

  def ExpWindow.list
    @@list
  end

  def initialize(*args)
    @buffer = []
    @buffer_pos = 0
    @max_buffer_size = 250
    @indent_word_wrap = true
    @@list.push(self)
    super(*args)
  end

  def add_line(line, line_colors = [])
    part = [0, line.length]
    line_colors.each do |h|
      part.push(h[:start])
      part.push(h[:end])
    end
    part.uniq!
    part.sort!
    for i in 0...(part.length - 1)
      str = line[part[i]...part[i + 1]]
      color_list = line_colors.find_all { |h| (h[:start] <= part[i]) and (h[:end] >= part[i + 1]) }
      if color_list.empty?
        addstr str + "\n" unless str.chomp.empty?
        noutrefresh
      else
        # shortest length highlight takes precedence when multiple highlights cover the same substring
        # fixme: allow multiple highlights on a substring when one specifies fg and the other specifies bg
        color_list = color_list.sort_by { |h| h[:end] - h[:start] }
        fg = color_list.map { |h| h[:fg] }.find { |fg| !fg.nil? }
        bg = color_list.map { |h| h[:bg] }.find { |bg| !bg.nil? }
        ul = color_list.map { |h| h[:ul] == 'true' }.find { |ul| ul }
        attron(color_pair(get_color_pair_id(fg, bg)) | (ul ? Curses::A_UNDERLINE : Curses::A_NORMAL)) do
          addstr str + "\n" unless str.chomp.empty?
          noutrefresh
        end
      end
      noutrefresh
    end
  end
end
