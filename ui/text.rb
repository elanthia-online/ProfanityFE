require "curses"

class TextWindow < Curses::Window
  attr_reader :color_stack, :buffer
  attr_accessor :scrollbar, :indent_word_wrap, :layout, :time_stamp

  @@list = Array.new

  def TextWindow.list
    @@list
  end

  def initialize(*args)
    @buffer = Array.new
    @buffer_pos = 0
    @max_buffer_size = 250
    @indent_word_wrap = true
    @@list.push(self)
    super(*args)
  end

  def max_buffer_size
    @max_buffer_size
  end

  def max_buffer_size=(val)
    # fixme: minimum size?  Curses.lines?
    @max_buffer_size = val.to_i
  end

  def add_line(line, line_colors = [])
    fg = nil
    bg = nil
    parts = [0, line.length]
    line_colors.each { |h| parts.push(h[:start], h[:end]) if h[:start] && h[:end] }
    parts.uniq!
    parts.sort!

    parts.each_cons(2) do |start_idx, end_idx|
      str = line[start_idx...end_idx]
      # Any color values that span the segment
      relevant_colors = line_colors.select { |h| h[:start] && h[:end] && h[:start] <= start_idx && h[:end] >= end_idx }

      if relevant_colors.empty?
        addstr str
      else
        # If there are values specific to this segment, use the highest priority ones
        specific_colors = relevant_colors.select { |h| h[:start] && h[:end] && h[:start] == start_idx && h[:end] == end_idx }
        sorted_colors = specific_colors.sort_by { |h| -(h[:priority] || Float::INFINITY) }
        fg = sorted_colors.find { |h| h[:fg] }&.[](:fg)
        bg = sorted_colors.find { |h| h[:bg] }&.[](:bg)

        # If there are no values specific to this segment, use the highest priority non-specific spanning color
        if fg == nil || bg == nil then
          sorted_colors = relevant_colors.sort_by { |h| -(h[:priority] || Float::INFINITY) }
          fg = sorted_colors.find { |h| h[:fg] }&.[](:fg) if fg == nil
          bg = sorted_colors.find { |h| h[:bg] }&.[](:bg) if bg == nil
        end

        ul = sorted_colors.any? { |h| h[:ul] == "true" }
        attron(color_pair(get_color_pair_id(fg, bg)) | (ul ? Curses::A_UNDERLINE : Curses::A_NORMAL)) do
          addstr str
        end
      end
    end
  end

  def add_string(string, string_colors = Array.new)
    #
    # word wrap string, split highlights if needed so each wrapped line is independent, update buffer, update window if needed
    #
    string += " [#{Time.now.hour.to_s.rjust(2, '0')}:#{Time.now.min.to_s.rjust(2, '0')}]" if @time_stamp && string && !string.chomp.empty?
    while (line = string.slice!(/^.{2,#{maxx - 1}}(?=\s|$)/)) or (line = string.slice!(0, (maxx - 1)))
      line_colors = Array.new
      for h in string_colors
        line_colors.push(h.dup) if (h[:start] < line.length)
        h[:end] -= line.length
        h[:start] = [(h[:start] - line.length), 0].max
      end
      string_colors.delete_if { |hl| hl[:end] < 0 }
      line_colors.each { |hl| hl[:end] = [hl[:end], line.length].min }
      @buffer.unshift([line, line_colors])
      @buffer.pop if @buffer.length > @max_buffer_size
      if @buffer_pos == 0
        addstr "\n" unless cury == 0 && curx == 0
        add_line(line, line_colors)
      else
        @buffer_pos += 1
        scroll(1) if @buffer_pos > (@max_buffer_size - maxy)
        update_scrollbar
      end
      break if string.chomp.empty?
      if @indent_word_wrap
        if string[0, 1] == ' '
          string = " #{string}"
          string_colors.each { |hl|
            hl[:end] += 1;
            # Never let the highlighting hang off the edge -- it looks weird
            hl[:start] += hl[:start] == 0 ? 2 : 1
          }
        else
          string = "  #{string}"
          string_colors.each { |hl| hl[:end] += 2; hl[:start] += 2 }
        end
      else
        if string[0, 1] == ' '
          string = string[1, string.length]
          string_colors.each { |hl| hl[:end] -= 1; hl[:start] -= 1 }
        end
      end
    end
    if @buffer_pos == 0
      noutrefresh
    end
  end

  def scroll(scroll_num)
    if scroll_num < 0
      if (@buffer_pos + maxy + scroll_num.abs) >= @buffer.length
        scroll_num = 0 - (@buffer.length - @buffer_pos - maxy)
      end
      if scroll_num < 0
        @buffer_pos += scroll_num.abs
        scrl(scroll_num)
        setpos(0, 0)
        pos = @buffer_pos + maxy - 1
        scroll_num.abs.times {
          add_line(@buffer[pos][0], @buffer[pos][1])
          addstr "\n"
          pos -= 1
        }
        noutrefresh
      end
      update_scrollbar
    elsif scroll_num > 0
      if @buffer_pos == 0
        nil
      else
        if (@buffer_pos - scroll_num) < 0
          scroll_num = @buffer_pos
        end
        @buffer_pos -= scroll_num
        scrl(scroll_num)
        setpos(maxy - scroll_num, 0)
        pos = @buffer_pos + scroll_num - 1
        (scroll_num - 1).times {
          add_line(@buffer[pos][0], @buffer[pos][1])
          addstr "\n"
          pos -= 1
        }
        add_line(@buffer[pos][0], @buffer[pos][1])
        noutrefresh
      end
    end
    update_scrollbar
  end

  def update_scrollbar
    if @scrollbar
      last_scrollbar_pos = @scrollbar_pos
      @scrollbar_pos = maxy - ((@buffer_pos / [(@buffer.length - maxy), 1].max.to_f) * (maxy - 1)).round - 1
      if last_scrollbar_pos
        unless last_scrollbar_pos == @scrollbar_pos
          @scrollbar.setpos(last_scrollbar_pos, 0)
          @scrollbar.addch '|'
          @scrollbar.setpos(@scrollbar_pos, 0)
          @scrollbar.attron(Curses::A_REVERSE) {
            @scrollbar.addch ' '
          }
          @scrollbar.noutrefresh
        end
      else
        for num in 0...maxy
          @scrollbar.setpos(num, 0)
          if num == @scrollbar_pos
            @scrollbar.attron(Curses::A_REVERSE) {
              @scrollbar.addch ' '
            }
          else
            @scrollbar.addch '|'
          end
        end
        @scrollbar.noutrefresh
      end
    end
  end

  def clear_scrollbar
    @scrollbar_pos = nil
    @scrollbar.erase
    @scrollbar.noutrefresh
  end

  def clear_window
    erase
    @buffer = Array.new
    @buffer_pos = 0
  end

  def resize_buffer
    # fixme
  end
end
