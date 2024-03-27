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
        fg = color_list.map { |h| h[:fg] }.find { |foreground| !foreground.nil? }
        bg = color_list.map { |h| h[:bg] }.find { |background| !background.nil? }
        ul = color_list.map { |h| h[:ul] == 'true' }.find { |underline| underline }
        attron(color_pair(get_color_pair_id(fg, bg)) | (ul ? Curses::A_UNDERLINE : Curses::A_NORMAL)) do
          addstr str + "\n" unless str.chomp.empty?
          noutrefresh
        end
      end
      noutrefresh
    end
  end

  def add_string(string, string_colors = [])
    while (line = string.slice!(/^.{2,#{maxx - 1}}(?=\s|$)/)) or (line = string.slice!(0, (maxx - 1)))
      line_colors = []
      for h in string_colors
        line_colors.push(h.dup) if h[:start] < line.length
        h[:end] -= line.length
        h[:start] = [(h[:start] - line.length), 0].max
      end
      string_colors.delete_if { |highlight| highlight[:end] < 0 }
      line_colors.each { |highlight| highlight[:end] = [highlight[:end], line.length].min }
      @buffer.unshift([line, line_colors])
      @buffer.pop if @buffer.length > @max_buffer_size
      if @buffer_pos == 0
        add_line(line, line_colors)
        # addstr "\n"
      else
        @buffer_pos += 1
        scroll(1) if @buffer_pos > (@max_buffer_size - maxy)
        update_scrollbar
      end
      break if string.chomp.empty?

      if @indent_word_wrap
        if string[0, 1] == ' '
          string = " #{string}"
          string_colors.each do |highlight|
            highlight[:end] += 1
            # Never let the highlighting hang off the edge -- it looks weird
            highlight[:start] += highlight[:start] == 0 ? 2 : 1
          end
        else
          string = "#{string}"
          string_colors.each do |highlight|
            highlight[:end] += 2
            highlight[:start] += 2
          end
        end
      elsif string[0, 1] == ' '
        string = string[1, string.length]
        string_colors.each do |highlight|
          highlight[:end] -= 1
          highlight[:start] -= 1
        end
      end
    end
  end

  def redraw
    clear
    setpos(0, 0)
    noutrefresh
  end

  def clear_window
    clear
    setpos(0, 0)
    noutrefresh
  end
end
