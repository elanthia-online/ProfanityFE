#!/usr/bin/env ruby
# encoding: US-ASCII

# vim: set sts=2 noet ts=2:
=begin

  ProfanityFE
  Copyright (C) 2013  Matthew Lowe

  This program is free software; you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation; either version 2 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License along
  with this program; if not, write to the Free Software Foundation, Inc.,
  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

  matt@lichproject.org

=end

require 'json'
require 'benchmark'
require 'socket'
require 'rexml/document'
require 'curses'
require 'fileutils'
require 'ostruct'
include Curses

require_relative "./ext/string.rb"

require_relative "./util/opts.rb"
require_relative "./ui/countdown.rb"
require_relative "./ui/indicator.rb"
require_relative "./ui/progress.rb"
require_relative "./ui/text.rb"

require_relative "./plugin/autocomplete.rb"
require_relative "./settings/settings.rb"
require_relative "./hilite/hilite.rb"

module Profanity
  LOG_FILE = Settings.file("debug.log")

  def self.log_file
    return File.open(LOG_FILE, 'a') { |file| yield file } if block_given?
  end

  @title  = nil
  @status = nil
  @char   = Opts.char.capitalize
  @state  = {}

  def self.fetch(key, default = nil)
    @state.fetch(key, default)
  end

  def self.put(**args)
    @state.merge!(args)
  end

  def self.set_terminal_title(title)
    return if @title.eql?(title) # noop
    @title = title
    system("printf \"\033]0;#{title}\007\"")
    Process.setproctitle(title)
  end

  def self.app_title(*parts)
    return if @status == parts.join("")
    @status = parts.join("")
    return set_terminal_title(@char) if @status.empty?
    set_terminal_title([@char, "[#{parts.reject(&:empty?).join(":")}]"].join(" ").gsub(">", ""))
  end

  def self.update_process_title()
    return if Opts["no-status"]
    app_title(Profanity.fetch(:prompt, ""), Profanity.fetch(:room, ""))
  end

  def self.log(str)
    log_file { |f| f.puts str }
  end

  def self.help_menu()
    puts <<~HELP

      Profanity FrontEnd
      #{'  '}
        --port=<port>
        --default-color-id=<id>
        --default-background-color-id=<id>
        --custom-colors=<on|off>
        --settings-file=<filename>
        --char=<character>
        --no-status                           do not redraw the process title with status updates
        --links                               enable links to be shown by default, otherwise can enable via .links command
        --speech-ts                           display timestamps on speech, familiar and thought window
        --remote-url                          display LaunchURLs on screen, used for remote environments
        --template=<filename.xml>             filename of template to use in templates subdirectory
    HELP
    exit
  end
end

Curses.init_screen
Curses.start_color
Curses.cbreak
Curses.noecho

server = nil
command_buffer        = String.new
command_buffer_pos    = 0
command_buffer_offset = 0
command_history       = Array.new
command_history_pos   = 0
min_cmd_length_for_history = 4
$server_time_offset     = 0
skip_server_time_offset = false
key_binding = Hash.new
key_action = Hash.new
need_prompt = false
prompt_text = ">"
stream_handler = Hash.new
indicator_handler = Hash.new
progress_handler = Hash.new
countdown_handler = Hash.new
command_window = nil
command_window_layout = nil
blue_links = (Opts["links"] ? true : false)
# We need a mutex for the settings because highlights can be accessed during a
# reload.  For now, it is just used to protect access to HIGHLIGHT, but if we
# ever support reloading other settings in the future it will have to protect
# those.
SETTINGS_LOCK               = Mutex.new
# TODO: fix this dirty, dirty, scumbag hack
HIGHLIGHT                   = Hilite.pointer()
PRESET                      = Hash.new
LAYOUT                      = Hash.new
WINDOWS                     = Hash.new
SCROLL_WINDOW               = Array.new
PORT                        = (Opts.port                || 8000).to_i
HOST                        = (Opts.host                || "127.0.0.1")
DEFAULT_COLOR_ID            = (Opts.color_id            || 7).to_i
DEFAULT_BACKGROUND_COLOR_ID = (Opts.background_color_id || 0).to_i
if Opts.char
  if Opts.template
    if File.exist?(File.join(File.expand_path(File.dirname(__FILE__)), 'templates', Opts.template.downcase))
      SETTINGS_FILENAME = File.join(File.expand_path(File.dirname(__FILE__)), 'templates', Opts.template.downcase)
    else
      raise StandardError, <<~ERROR
        You specified --template=#{Opts.template} but it doesn't exist.
        Please try again!
      ERROR
    end
  else
    if File.exist?(Settings.file(Opts.char.downcase + ".xml"))
      SETTINGS_FILENAME = Settings.file(Opts.char.downcase + ".xml")
    elsif File.exist?(File.join(File.expand_path(File.dirname(__FILE__)), 'templates', Opts.char.downcase + ".xml"))
      SETTINGS_FILENAME = File.join(File.expand_path(File.dirname(__FILE__)), 'templates', Opts.char.downcase + ".xml")
    else
      SETTINGS_FILENAME = File.join(File.expand_path(File.dirname(__FILE__)), 'templates', 'default.xml')
    end
  end
end

def add_prompt(window, prompt_text, cmd = "")
  window.add_string("#{prompt_text}#{cmd}", [{ :start => 0, :end => (prompt_text.length + cmd.length), :fg => '555555' }])
end

unless defined?(SETTINGS_FILENAME)
  raise StandardError, <<~ERROR
    you must pass --char=<character> or --template=<filename.xml>
    #{Opts.parse()}
  ERROR
end

Profanity.set_terminal_title(Opts.char.capitalize)

unless defined?(CUSTOM_COLORS)
  CUSTOM_COLORS = Curses.can_change_color?
end

DEFAULT_COLOR_CODE = Curses.color_content(DEFAULT_COLOR_ID).collect { |num| ((num / 1000.0) * 255).round.to_s(16) }.join('').rjust(6, '0')
DEFAULT_BACKGROUND_COLOR_CODE = Curses.color_content(DEFAULT_BACKGROUND_COLOR_ID).collect { |num| ((num / 1000.0) * 255).round.to_s(16) }.join('').rjust(6, '0')

xml_escape_list = {
  '&lt;'   => '<',
  '&gt;'   => '>',
  '&quot;' => '"',
  '&apos;' => "'",
  '&amp;'  => '&',
  #  '&#xA'   => "\n",
}

key_name = {
  'ctrl+a'        => 1,
  'ctrl+b'        => 2,
  #  'ctrl+c'    => 3,
  'ctrl+d'        => 4,
  'ctrl+e'        => 5,
  'ctrl+f'        => 6,
  'ctrl+g'        => 7,
  'ctrl+h'        => 8,
  'win_backspace' => 8,
  'ctrl+i'        => 9,
  'tab'           => 9,
  'ctrl+j'        => 10,
  'enter'         => 10,
  'ctrl+k'        => 11,
  'ctrl+l'        => 12,
  'return'        => 13,
  'ctrl+m'        => 13,
  'ctrl+n'        => 14,
  'ctrl+o'        => 15,
  'ctrl+p'        => 16,
  #  'ctrl+q'    => 17,
  'ctrl+r'        => 18,
  #  'ctrl+s'    => 19,
  'ctrl+t'        => 20,
  'ctrl+u'        => 21,
  'ctrl+v'        => 22,
  'ctrl+w'        => 23,
  'ctrl+x'        => 24,
  'ctrl+y'        => 25,
  'ctrl+z'        => 26,
  'alt'           => 27,
  'escape'        => 27,
  'ctrl+?'        => 127,
  'down'          => 258,
  'up'            => 259,
  'left'          => 260,
  'right'         => 261,
  'home'          => 262,
  'backspace'     => 263,
  'f1'            => 265,
  'f2'            => 266,
  'f3'            => 267,
  'f4'            => 268,
  'f5'            => 269,
  'f6'            => 270,
  'f7'            => 271,
  'f8'            => 272,
  'f9'            => 273,
  'f10'           => 274,
  'f11'           => 275,
  'f12'           => 276,
  'delete'        => 330,
  'insert'        => 331,
  'page_down'     => 338,
  'page_up'       => 339,
  'end'           => 360,
  'resize'        => 410,
  'ctrl+delete'   => 513,
  'alt+down'      => 517,
  'ctrl+down'     => 519,
  'alt+left'      => 537,
  'ctrl+left'     => 539,
  'alt+page_down' => 542,
  'alt+page_up'   => 547,
  'alt+right'     => 552,
  'ctrl+right'    => 554,
  'alt+up'        => 558,
  'ctrl+up'       => 560,
}

if CUSTOM_COLORS
  COLOR_ID_LOOKUP = Hash.new
  COLOR_ID_LOOKUP[DEFAULT_COLOR_CODE] = DEFAULT_COLOR_ID
  COLOR_ID_LOOKUP[DEFAULT_BACKGROUND_COLOR_CODE] = DEFAULT_BACKGROUND_COLOR_ID
  COLOR_ID_HISTORY = Array.new
  for num in 0...Curses.colors
    unless (num == DEFAULT_COLOR_ID) or (num == DEFAULT_BACKGROUND_COLOR_ID)
      COLOR_ID_HISTORY.push(num)
    end
  end

  def get_color_id(code)
    if (color_id = COLOR_ID_LOOKUP[code])
      color_id
    else
      color_id = COLOR_ID_HISTORY.shift
      COLOR_ID_LOOKUP.delete_if { |_k, v| v == color_id }
      sleep 0.01 # somehow this keeps Curses.init_color from failing sometimes
      Curses.init_color(color_id, ((code[0..1].to_s.hex / 255.0) * 1000).round, ((code[2..3].to_s.hex / 255.0) * 1000).round, ((code[4..5].to_s.hex / 255.0) * 1000).round)
      COLOR_ID_LOOKUP[code] = color_id
      COLOR_ID_HISTORY.push(color_id)
      color_id
    end
  end
else
  COLOR_CODE = ['000000', '800000', '008000', '808000', '000080', '800080', '008080', 'c0c0c0', '808080', 'ff0000', '00ff00', 'ffff00', '0000ff', 'ff00ff', '00ffff', 'ffffff', '000000', '00005f', '000087', '0000af', '0000d7', '0000ff', '005f00', '005f5f', '005f87', '005faf', '005fd7', '005fff', '008700', '00875f', '008787', '0087af', '0087d7', '0087ff', '00af00', '00af5f', '00af87', '00afaf', '00afd7', '00afff', '00d700', '00d75f', '00d787', '00d7af', '00d7d7', '00d7ff', '00ff00', '00ff5f', '00ff87', '00ffaf', '00ffd7', '00ffff', '5f0000', '5f005f', '5f0087', '5f00af', '5f00d7', '5f00ff', '5f5f00', '5f5f5f', '5f5f87', '5f5faf', '5f5fd7', '5f5fff', '5f8700', '5f875f', '5f8787', '5f87af', '5f87d7', '5f87ff', '5faf00', '5faf5f', '5faf87', '5fafaf', '5fafd7', '5fafff', '5fd700', '5fd75f', '5fd787', '5fd7af', '5fd7d7', '5fd7ff', '5fff00', '5fff5f', '5fff87', '5fffaf', '5fffd7', '5fffff', '870000', '87005f', '870087', '8700af', '8700d7', '8700ff', '875f00', '875f5f', '875f87', '875faf', '875fd7', '875fff', '878700', '87875f', '878787', '8787af', '8787d7', '8787ff', '87af00', '87af5f', '87af87', '87afaf', '87afd7', '87afff', '87d700', '87d75f', '87d787', '87d7af', '87d7d7', '87d7ff', '87ff00', '87ff5f', '87ff87', '87ffaf', '87ffd7', '87ffff', 'af0000', 'af005f', 'af0087', 'af00af', 'af00d7', 'af00ff', 'af5f00', 'af5f5f', 'af5f87', 'af5faf', 'af5fd7', 'af5fff', 'af8700', 'af875f', 'af8787', 'af87af', 'af87d7', 'af87ff', 'afaf00', 'afaf5f', 'afaf87', 'afafaf', 'afafd7', 'afafff', 'afd700', 'afd75f', 'afd787', 'afd7af', 'afd7d7', 'afd7ff', 'afff00', 'afff5f', 'afff87', 'afffaf', 'afffd7', 'afffff', 'd70000', 'd7005f', 'd70087', 'd700af', 'd700d7', 'd700ff', 'd75f00', 'd75f5f', 'd75f87', 'd75faf', 'd75fd7', 'd75fff', 'd78700', 'd7875f', 'd78787', 'd787af', 'd787d7', 'd787ff', 'd7af00', 'd7af5f', 'd7af87', 'd7afaf', 'd7afd7', 'd7afff', 'd7d700', 'd7d75f', 'd7d787', 'd7d7af', 'd7d7d7', 'd7d7ff', 'd7ff00', 'd7ff5f', 'd7ff87', 'd7ffaf', 'd7ffd7', 'd7ffff', 'ff0000', 'ff005f', 'ff0087', 'ff00af', 'ff00d7', 'ff00ff', 'ff5f00', 'ff5f5f', 'ff5f87', 'ff5faf', 'ff5fd7', 'ff5fff', 'ff8700', 'ff875f', 'ff8787', 'ff87af', 'ff87d7', 'ff87ff', 'ffaf00', 'ffaf5f', 'ffaf87', 'ffafaf', 'ffafd7', 'ffafff', 'ffd700', 'ffd75f', 'ffd787', 'ffd7af', 'ffd7d7', 'ffd7ff', 'ffff00', 'ffff5f', 'ffff87', 'ffffaf', 'ffffd7', 'ffffff', '080808', '121212', '1c1c1c', '262626', '303030', '3a3a3a', '444444', '4e4e4e', '585858', '626262', '6c6c6c', '767676', '808080', '8a8a8a', '949494', '9e9e9e', 'a8a8a8', 'b2b2b2', 'bcbcbc', 'c6c6c6', 'd0d0d0', 'dadada', 'e4e4e4', 'eeeeee'][0...Curses.colors]
  COLOR_ID_LOOKUP = Hash.new

  def get_color_id(code)
    if (color_id = COLOR_ID_LOOKUP[code])
      color_id
    else
      least_error = nil
      least_error_id = nil
      COLOR_CODE.each_index { |color_id|
        error = ((COLOR_CODE[color_id][0..1].hex - code[0..1].hex)**2) + ((COLOR_CODE[color_id][2..3].hex - code[2..3].hex)**2) + ((COLOR_CODE[color_id][4..6].hex - code[4..6].hex)**2)
        if least_error.nil? or (error < least_error)
          least_error = error
          least_error_id = color_id
        end
      }
      COLOR_ID_LOOKUP[code] = least_error_id
      least_error_id
    end
  end
end

# COLOR_PAIR_LIST = Array.new
# for num in 1...Curses::color_pairs
#  COLOR_PAIR_LIST.push h={ :color_id => nil, :background_id => nil, :id => num }
# end

# 157+12+1 = 180
# 38+1+6 = 45
# 32767

COLOR_PAIR_ID_LOOKUP = Hash.new
COLOR_PAIR_HISTORY = Array.new

# fixme: high color pair id's change text?
# A_NORMAL = 0
# A_STANDOUT = 65536
# A_UNDERLINE = 131072
# 15000 = black background, dark blue-green text
# 10000 = dark yellow background, black text
#  5000 = black
#  2000 = black
#  1000 = highlights show up black
#   100 = normal
#   500 = black and some underline

for num in 1...Curses::color_pairs # fixme: things go to hell at about pair 256
  # for num in 1...([Curses::color_pairs, 256].min)
  COLOR_PAIR_HISTORY.push(num)
end

def get_color_pair_id(fg_code, bg_code)
  if fg_code.nil?
    fg_id = DEFAULT_COLOR_ID
  else
    fg_id = get_color_id(fg_code)
  end
  if bg_code.nil?
    bg_id = DEFAULT_BACKGROUND_COLOR_ID
  else
    bg_id = get_color_id(bg_code)
  end
  if (COLOR_PAIR_ID_LOOKUP[fg_id]) and (color_pair_id = COLOR_PAIR_ID_LOOKUP[fg_id][bg_id])
    color_pair_id
  else
    color_pair_id = COLOR_PAIR_HISTORY.shift
    COLOR_PAIR_ID_LOOKUP.each { |_w, x| x.delete_if { |_y, z| z == color_pair_id } }
    sleep 0.01
    Curses.init_pair(color_pair_id, fg_id, bg_id)
    COLOR_PAIR_ID_LOOKUP[fg_id] ||= Hash.new
    COLOR_PAIR_ID_LOOKUP[fg_id][bg_id] = color_pair_id
    COLOR_PAIR_HISTORY.push(color_pair_id)
    color_pair_id
  end
end

# Implement support for basic readline-style kill and yank (cut and paste)
# commands.  Successive calls to delete_word, backspace_word, kill_forward, and
# kill_line will accumulate text into the kill_buffer as long as no other
# commands have changed the command buffer.  These commands call kill_before to
# reset the kill_buffer if the command buffer has changed, add the newly
# deleted text to the kill_buffer, and finally call kill_after to remember the
# state of the command buffer for next time.
kill_buffer   = ''
kill_original = ''
kill_last     = ''
kill_last_pos = 0
kill_before = proc {
  if kill_last != command_buffer || kill_last_pos != command_buffer_pos
    kill_buffer = ''
    kill_original = command_buffer
  end
}
kill_after = proc {
  kill_last = command_buffer.dup
  kill_last_pos = command_buffer_pos
}

fix_layout_number = proc { |str|
  str = str.gsub('lines', Curses.lines.to_s).gsub('cols', Curses.cols.to_s)
  begin
    proc { eval(str) }.call.to_i
  rescue
    $stderr.puts $!
    $stderr.puts $!.backtrace[0..1]
    0
  end
}

load_layout = proc { |layout_id|
  if (xml = LAYOUT[layout_id])
    old_windows = IndicatorWindow.list | TextWindow.list | CountdownWindow.list | ProgressWindow.list

    previous_indicator_handler = indicator_handler
    indicator_handler = Hash.new

    previous_stream_handler = stream_handler
    stream_handler = Hash.new

    previous_progress_handler = progress_handler
    progress_handler = Hash.new

    previous_countdown_handler = countdown_handler
    progress_handler = Hash.new

    xml.elements.each { |e|
      if e.name == 'window'
        height, width, top, left = fix_layout_number.call(
          e.attributes['height']
        ),
          fix_layout_number.call(e.attributes['width']),
          fix_layout_number.call(e.attributes['top']),
          fix_layout_number.call(e.attributes['left'])

        if (height > 0) and (width > 0) and (top >= 0) and (left >= 0) and (top < Curses.lines) and (left < Curses.cols)
          if e.attributes['class'] == 'indicator'
            if e.attributes['value'] and (window = previous_indicator_handler[e.attributes['value']])
              previous_indicator_handler[e.attributes['value']] = nil
              old_windows.delete(window)
            else
              window = IndicatorWindow.new(height, width, top, left)
            end
            window.layout = [e.attributes['height'], e.attributes['width'], e.attributes['top'], e.attributes['left']]
            window.scrollok(false)
            window.label = e.attributes['label'] if e.attributes['label']
            window.fg = e.attributes['fg'].split(',')
                         .collect { |val| if val == 'nil'; nil; else; val; end  } if e.attributes['fg']
            window.bg = e.attributes['bg'].split(',')
                         .collect { |val| if val == 'nil'; nil; else; val; end  } if e.attributes['bg']
            if e.attributes['value']
              indicator_handler[e.attributes['value']] = window
            end
            window.redraw
          elsif e.attributes['class'] == 'text'
            if width > 1
              if e.attributes['value'] and (window = previous_stream_handler[previous_stream_handler.keys.find { |key| e.attributes['value'].split(',').include?(key) }])
                previous_stream_handler[e.attributes['value']] = nil
                old_windows.delete(window)
              else
                window = TextWindow.new(height, width - 1, top, left)
                window.scrollbar = Curses::Window.new(window.maxy, 1, window.begy, window.begx + window.maxx)
              end
              window.layout = [e.attributes['height'], e.attributes['width'], e.attributes['top'], e.attributes['left']]
              window.scrollok(true)
              window.max_buffer_size = e.attributes['buffer-size'] || 1000
              e.attributes['value'].split(',').each { |str|
                stream_handler[str] = window
              }
            end
          elsif e.attributes['class'] == 'countdown'
            if e.attributes['value'] and (window = previous_countdown_handler[e.attributes['value']])
              previous_countdown_handler[e.attributes['value']] = nil
              old_windows.delete(window)
            else
              window = CountdownWindow.new(height, width, top, left)
            end
            window.layout = [e.attributes['height'], e.attributes['width'], e.attributes['top'], e.attributes['left']]
            window.scrollok(false)
            window.label = e.attributes['label'] if e.attributes['label']
            window.fg = e.attributes['fg'].split(',').collect { |val| if val == 'nil'; nil; else; val; end  } if e.attributes['fg']
            window.bg = e.attributes['bg'].split(',').collect { |val| if val == 'nil'; nil; else; val; end  } if e.attributes['bg']
            if e.attributes['value']
              countdown_handler[e.attributes['value']] = window
            end
            window.update
          elsif e.attributes['class'] == 'progress'
            if e.attributes['value'] and (window = previous_progress_handler[e.attributes['value']])
              previous_progress_handler[e.attributes['value']] = nil
              old_windows.delete(window)
            else
              window = ProgressWindow.new(height, width, top, left)
            end
            window.layout = [e.attributes['height'], e.attributes['width'], e.attributes['top'], e.attributes['left']]
            window.scrollok(false)
            window.label = e.attributes['label'] if e.attributes['label']
            window.fg = e.attributes['fg'].split(',').collect { |val| if val == 'nil'; nil; else; val; end  } if e.attributes['fg']
            window.bg = e.attributes['bg'].split(',').collect { |val| if val == 'nil'; nil; else; val; end  } if e.attributes['bg']
            if e.attributes['value']
              progress_handler[e.attributes['value']] = window
            end
            window.redraw
          elsif e.attributes['class'] == 'command'
            unless command_window
              command_window = Curses::Window.new(height, width, top, left)
            end
            command_window_layout = [e.attributes['height'], e.attributes['width'], e.attributes['top'], e.attributes['left']]
            command_window.scrollok(false)
            command_window.keypad(true)
          end
        end
      end
    }
    if (current_scroll_window = TextWindow.list[0])
      current_scroll_window.update_scrollbar
    end
    for window in old_windows
      IndicatorWindow.list.delete(window)
      TextWindow.list.delete(window)
      CountdownWindow.list.delete(window)
      ProgressWindow.list.delete(window)
      if window.class == TextWindow
        window.scrollbar.close
      end
      window.close
    end
    Curses.doupdate
  end
}

do_macro = nil

setup_key = proc { |xml, binding|
  if (key = xml.attributes['id'])
    if key =~ /^[0-9]+$/
      key = key.to_i
    elsif (key.class) == String and (key.length == 1)
      nil
    else
      key = key_name[key]
    end
    if key
      if (macro = xml.attributes['macro'])
        binding[key] = proc { do_macro.call(macro) }
      elsif xml.attributes['action'] and (action = key_action[xml.attributes['action']])
        binding[key] = action
      else
        binding[key] ||= Hash.new
        xml.elements.each { |e|
          setup_key.call(e, binding[key])
        }
      end
    end
  end
}

load_settings_file = proc { |reload|
  SETTINGS_LOCK.synchronize {
    begin
      xml = Hilite.load(file: SETTINGS_FILENAME, flush: reload)
      unless reload
        xml.elements.each { |e|
          # These are things that we ignore if we're doing a reload of the settings file
          if e.name == 'preset'
            PRESET[e.attributes['id']] = [e.attributes['fg'], e.attributes['bg']]
          elsif (e.name == 'layout') and (layout_id = e.attributes['id'])
            LAYOUT[layout_id] = e
          elsif e.name == 'key'
            setup_key.call(e, key_binding)
          end
        }
      end
    rescue
      Profanity.log $!
      Profanity.log $!.backtrace[0..1]
    end
  }
}

command_window_put_ch = proc { |ch|
  if (command_buffer_pos - command_buffer_offset + 1) >= command_window.maxx
    command_window.setpos(0, 0)
    command_window.delch
    command_buffer_offset += 1
    command_window.setpos(0, command_buffer_pos - command_buffer_offset)
  end
  command_buffer.insert(command_buffer_pos, ch)
  command_buffer_pos += 1
  command_window.insch(ch)
  command_window.setpos(0, command_buffer_pos - command_buffer_offset)
}

do_macro = proc { |macro|
  # fixme: gsub %whatever
  backslash = false
  at_pos = nil
  backfill = nil
  macro.split('').each_with_index { |ch, i|
    if backslash
      if ch == '\\'
        command_window_put_ch.call('\\')
      elsif ch == 'x'
        command_buffer.clear
        command_buffer_pos = 0
        command_buffer_offset = 0
        command_window.deleteln
        command_window.setpos(0, 0)
      elsif ch == 'r'
        at_pos = nil
        key_action['send_command'].call
      elsif ch == '@'
        command_window_put_ch.call('@')
      elsif ch == '?'
        backfill = i - 3
      else
        nil
      end
      backslash = false
    else
      if ch == '\\'
        backslash = true
      elsif ch == '@'
        at_pos = command_buffer_pos
      else
        command_window_put_ch.call(ch)
      end
    end
  }
  if at_pos
    while at_pos < command_buffer_pos
      key_action['cursor_left'].call
    end
    while at_pos > command_buffer_pos
      key_action['cursor_right'].call
    end
  end
  command_window.noutrefresh
  if backfill then
    command_window.setpos(0, backfill)
    command_buffer_pos = backfill
    backfill = nil
  end
  Curses.doupdate
}

key_action['resize'] = proc {
  # fixme: re-word-wrap
  window = Window.new(0, 0, 0, 0)
  window.refresh
  window.close
  first_text_window = true
  for window in TextWindow.list.to_a
    window.resize(fix_layout_number.call(window.layout[0]), fix_layout_number.call(window.layout[1]) - 1)
    window.move(fix_layout_number.call(window.layout[2]), fix_layout_number.call(window.layout[3]))
    window.scrollbar.resize(window.maxy, 1)
    window.scrollbar.move(window.begy, window.begx + window.maxx)
    window.scroll(-window.maxy)
    window.scroll(window.maxy)
    window.clear_scrollbar
    if first_text_window
      window.update_scrollbar
      first_text_window = false
    end
    window.noutrefresh
  end
  for window in [IndicatorWindow.list.to_a, ProgressWindow.list.to_a, CountdownWindow.list.to_a].flatten
    window.resize(fix_layout_number.call(window.layout[0]), fix_layout_number.call(window.layout[1]))
    window.move(fix_layout_number.call(window.layout[2]), fix_layout_number.call(window.layout[3]))
    window.noutrefresh
  end
  if command_window
    command_window.resize(fix_layout_number.call(command_window_layout[0]), fix_layout_number.call(command_window_layout[1]))
    command_window.move(fix_layout_number.call(command_window_layout[2]), fix_layout_number.call(command_window_layout[3]))
    command_window.noutrefresh
  end
  Curses.doupdate
}

key_action['cursor_left'] = proc {
  if (command_buffer_offset > 0) and (command_buffer_pos - command_buffer_offset == 0)
    command_buffer_pos -= 1
    command_buffer_offset -= 1
    command_window.insch(command_buffer[command_buffer_pos])
  else
    command_buffer_pos = [command_buffer_pos - 1, 0].max
  end
  command_window.setpos(0, command_buffer_pos - command_buffer_offset)
  command_window.noutrefresh
  Curses.doupdate
}

key_action['cursor_right'] = proc {
  if ((command_buffer.length - command_buffer_offset) >= (command_window.maxx - 1)) and (command_buffer_pos - command_buffer_offset + 1) >= command_window.maxx
    if command_buffer_pos < command_buffer.length
      command_window.setpos(0, 0)
      command_window.delch
      command_buffer_offset += 1
      command_buffer_pos += 1
      command_window.setpos(0, command_buffer_pos - command_buffer_offset)
      unless command_buffer_pos >= command_buffer.length
        command_window.insch(command_buffer[command_buffer_pos])
      end
    end
  else
    command_buffer_pos = [command_buffer_pos + 1, command_buffer.length].min
    command_window.setpos(0, command_buffer_pos - command_buffer_offset)
  end
  command_window.noutrefresh
  Curses.doupdate
}

key_action['cursor_word_left'] = proc {
  if command_buffer_pos > 0
    if (m = command_buffer[0...(command_buffer_pos - 1)].match(/.*(\w[^\w\s]|\W\w|\s\S)/))
      new_pos = m.begin(1) + 1
    else
      new_pos = 0
    end
    if (command_buffer_offset > new_pos)
      command_window.setpos(0, 0)
      command_buffer[new_pos, (command_buffer_offset - new_pos)].split('').reverse.each { |ch| command_window.insch(ch) }
      command_buffer_pos = new_pos
      command_buffer_offset = new_pos
    else
      command_buffer_pos = new_pos
    end
    command_window.setpos(0, command_buffer_pos - command_buffer_offset)
    command_window.noutrefresh
    Curses.doupdate
  end
}

key_action['cursor_word_right'] = proc {
  if command_buffer_pos < command_buffer.length
    if (m = command_buffer[command_buffer_pos..-1].match(/\w[^\w\s]|\W\w|\s\S/))
      new_pos = command_buffer_pos + m.begin(0) + 1
    else
      new_pos = command_buffer.length
    end
    overflow = new_pos - command_window.maxx - command_buffer_offset + 1
    if overflow > 0
      command_window.setpos(0, 0)
      overflow.times {
        command_window.delch
        command_buffer_offset += 1
      }
      command_window.setpos(0, command_window.maxx - overflow)
      command_window.addstr command_buffer[(command_window.maxx - overflow + command_buffer_offset), overflow]
    end
    command_buffer_pos = new_pos
    command_window.setpos(0, command_buffer_pos - command_buffer_offset)
    command_window.noutrefresh
    Curses.doupdate
  end
}

key_action['cursor_home'] = proc {
  command_buffer_pos = 0
  command_window.setpos(0, 0)
  for num in 1..command_buffer_offset
    begin
      command_window.insch(command_buffer[command_buffer_offset - num])
    rescue
      Profanity.log_file { |f|
        f.puts "command_buffer: #{command_buffer.inspect}";
        f.puts "command_buffer_offset: #{command_buffer_offset.inspect}";
        f.puts "num: #{num.inspect}";
        f.puts $!;
        f.puts $!.backtrace[0...4]
      }
      exit
    end
  end
  command_buffer_offset = 0
  command_window.noutrefresh
  Curses.doupdate
}

key_action['cursor_end'] = proc {
  if command_buffer.length < (command_window.maxx - 1)
    command_buffer_pos = command_buffer.length
    command_window.setpos(0, command_buffer_pos)
  else
    scroll_left_num = command_buffer.length - command_window.maxx + 1 - command_buffer_offset
    command_window.setpos(0, 0)
    scroll_left_num.times {
      command_window.delch
      command_buffer_offset += 1
    }
    command_buffer_pos = command_buffer_offset + command_window.maxx - 1 - scroll_left_num
    command_window.setpos(0, command_buffer_pos - command_buffer_offset)
    scroll_left_num.times {
      command_window.addch(command_buffer[command_buffer_pos])
      command_buffer_pos += 1
    }
  end
  command_window.noutrefresh
  Curses.doupdate
}

key_action['cursor_backspace'] = proc {
  if command_buffer_pos > 0
    command_buffer_pos -= 1
    if command_buffer_pos == 0
      command_buffer = command_buffer[(command_buffer_pos + 1)..-1]
    else
      command_buffer = command_buffer[0..(command_buffer_pos - 1)] + command_buffer[(command_buffer_pos + 1)..-1]
    end
    command_window.setpos(0, command_buffer_pos - command_buffer_offset)
    command_window.delch
    if (command_buffer.length - command_buffer_offset + 1) > command_window.maxx
      command_window.setpos(0, command_window.maxx - 1)
      command_window.addch command_buffer[command_window.maxx - command_buffer_offset - 1]
      command_window.setpos(0, command_buffer_pos - command_buffer_offset)
    end
    command_window.noutrefresh
    Curses.doupdate
  end
}

key_action['cursor_delete'] = proc {
  if (command_buffer.length > 0) and (command_buffer_pos < command_buffer.length)
    if command_buffer_pos == 0
      command_buffer = command_buffer[(command_buffer_pos + 1)..-1]
    elsif command_buffer_pos < command_buffer.length
      command_buffer = command_buffer[0..(command_buffer_pos - 1)] + command_buffer[(command_buffer_pos + 1)..-1]
    end
    command_window.delch
    if (command_buffer.length - command_buffer_offset + 1) > command_window.maxx
      command_window.setpos(0, command_window.maxx - 1)
      command_window.addch command_buffer[command_window.maxx - command_buffer_offset - 1]
      command_window.setpos(0, command_buffer_pos - command_buffer_offset)
    end
    command_window.noutrefresh
    Curses.doupdate
  end
}

key_action['cursor_backspace_word'] = proc {
  num_deleted = 0
  deleted_alnum = false
  deleted_nonspace = false
  while command_buffer_pos > 0 do
    next_char = command_buffer[command_buffer_pos - 1]
    if num_deleted == 0 || (!deleted_alnum && next_char.punct?) || (!deleted_nonspace && next_char.space?) || next_char.alnum?
      deleted_alnum = deleted_alnum || next_char.alnum?
      deleted_nonspace = !next_char.space?
      num_deleted += 1
      kill_before.call
      kill_buffer = next_char + kill_buffer
      key_action['cursor_backspace'].call
      kill_after.call
    else
      break
    end
  end
}

key_action['cursor_delete_word'] = proc {
  num_deleted = 0
  deleted_alnum = false
  deleted_nonspace = false
  while command_buffer_pos < command_buffer.length do
    next_char = command_buffer[command_buffer_pos]
    if num_deleted == 0 || (!deleted_alnum && next_char.punct?) || (!deleted_nonspace && next_char.space?) || next_char.alnum?
      deleted_alnum = deleted_alnum || next_char.alnum?
      deleted_nonspace = !next_char.space?
      num_deleted += 1
      kill_before.call
      kill_buffer = kill_buffer + next_char
      key_action['cursor_delete'].call
      kill_after.call
    else
      break
    end
  end
}

key_action['cursor_kill_forward'] = proc {
  if command_buffer_pos < command_buffer.length
    kill_before.call
    if command_buffer_pos == 0
      kill_buffer = kill_buffer + command_buffer
      command_buffer = ''
    else
      kill_buffer = kill_buffer + command_buffer[command_buffer_pos..-1]
      command_buffer = command_buffer[0..(command_buffer_pos - 1)]
    end
    kill_after.call
    command_window.clrtoeol
    command_window.noutrefresh
    Curses.doupdate
  end
}

key_action['cursor_kill_line'] = proc {
  if command_buffer.length != 0
    kill_before.call
    kill_buffer = kill_original
    command_buffer = ''
    command_buffer_pos = 0
    command_buffer_offset = 0
    kill_after.call
    command_window.setpos(0, 0)
    command_window.clrtoeol
    command_window.noutrefresh
    Curses.doupdate
  end
}

key_action['cursor_yank'] = proc {
  kill_buffer.each_char { |c| command_window_put_ch.call(c) }
}

key_action['switch_current_window'] = proc {
  if (current_scroll_window = TextWindow.list[0])
    current_scroll_window.clear_scrollbar
  end
  TextWindow.list.push(TextWindow.list.shift)
  if (current_scroll_window = TextWindow.list[0])
    current_scroll_window.update_scrollbar
  end
  command_window.noutrefresh
  Curses.doupdate
}

key_action['scroll_current_window_up_one'] = proc {
  if (current_scroll_window = TextWindow.list[0])
    current_scroll_window.scroll(-1)
  end
  command_window.noutrefresh
  Curses.doupdate
}

key_action['scroll_current_window_down_one'] = proc {
  if (current_scroll_window = TextWindow.list[0])
    current_scroll_window.scroll(1)
  end
  command_window.noutrefresh
  Curses.doupdate
}

key_action['scroll_current_window_up_page'] = proc {
  if (current_scroll_window = TextWindow.list[0])
    current_scroll_window.scroll(0 - current_scroll_window.maxy + 1)
  end
  command_window.noutrefresh
  Curses.doupdate
}

key_action['scroll_current_window_down_page'] = proc {
  if (current_scroll_window = TextWindow.list[0])
    current_scroll_window.scroll(current_scroll_window.maxy - 1)
  end
  command_window.noutrefresh
  Curses.doupdate
}

key_action['scroll_current_window_bottom'] = proc {
  if (current_scroll_window = TextWindow.list[0])
    current_scroll_window.scroll(current_scroll_window.max_buffer_size)
  end
  command_window.noutrefresh
  Curses.doupdate
}

write_to_client = proc { |str, color|
  stream_handler["main"].add_string str, [{ :fg => color, :start => 0, :end => str.size }]
  command_window.noutrefresh
  Curses.doupdate
}

key_action['autocomplete'] = proc { |idx|
  Autocomplete.wrap do
    current = command_buffer.dup
    history = command_history.map(&:strip).reject(&:empty?).compact.uniq

    # collection of possibilities
    possibilities = []

    unless current.strip.empty?
      history.each do |historical|
        possibilities.push(historical) if Autocomplete.compare(current, historical)
      end
    end

    if possibilities.size == 0
      write_to_client.call "[autocomplete] no suggestions", Autocomplete::HIGHLIGHT
    end

    if possibilities.size > 1
      # we should autoprogress the command input until there
      # is a divergence in the possible commands
      divergence = Autocomplete.find_branch(possibilities)

      command_buffer = divergence
      command_buffer_offset = [(command_buffer.length - command_window.maxx + 1), 0].max
      command_buffer_pos = command_buffer.length
      command_window.addstr divergence[current.size..-1]
      command_window.setpos(0, divergence.size)

      write_to_client.call("[autocomplete:#{possibilities.size}]", Autocomplete::HIGHLIGHT)
      possibilities.each_with_index do |command, i|
        write_to_client.call("[#{i}] #{command}", Autocomplete::HIGHLIGHT)
      end
    end

    idx = 0 if possibilities.size == 1

    if idx && possibilities[idx]
      command_buffer = possibilities[idx]
      command_buffer_offset = [(command_buffer.length - command_window.maxx + 1), 0].max
      command_buffer_pos = command_buffer.length
      command_window.addstr possibilities.first[current.size..-1]
      command_window.setpos(0, possibilities.first.size)
      Curses.doupdate
    end
  end
}

key_action['previous_command'] = proc {
  if command_history_pos < (command_history.length - 1)
    command_history[command_history_pos] = command_buffer.dup
    command_history_pos += 1
    command_buffer = command_history[command_history_pos].dup
    command_buffer_offset = [(command_buffer.length - command_window.maxx + 1), 0].max
    command_buffer_pos = command_buffer.length
    command_window.setpos(0, 0)
    command_window.deleteln
    command_window.addstr command_buffer[command_buffer_offset, (command_buffer.length - command_buffer_offset)]
    command_window.setpos(0, command_buffer_pos - command_buffer_offset)
    command_window.noutrefresh
    Curses.doupdate
  end
}

key_action['next_command'] = proc {
  if command_history_pos == 0
    unless command_buffer.empty?
      command_history[command_history_pos] = command_buffer.dup
      command_history.unshift String.new
      command_buffer.clear
      command_window.deleteln
      command_buffer_pos = 0
      command_buffer_offset = 0
      command_window.setpos(0, 0)
      command_window.noutrefresh
      Curses.doupdate
    end
  else
    command_history[command_history_pos] = command_buffer.dup
    command_history_pos -= 1
    command_buffer = command_history[command_history_pos].dup
    command_buffer_offset = [(command_buffer.length - command_window.maxx + 1), 0].max
    command_buffer_pos = command_buffer.length
    command_window.setpos(0, 0)
    command_window.deleteln
    command_window.addstr command_buffer[command_buffer_offset, (command_buffer.length - command_buffer_offset)]
    command_window.setpos(0, command_buffer_pos - command_buffer_offset)
    command_window.noutrefresh
    Curses.doupdate
  end
}

key_action['switch_arrow_mode'] = proc {
  if key_binding[Curses::KEY_UP] == key_action['previous_command']
    key_binding[Curses::KEY_UP] = key_action['scroll_current_window_up_page']
    key_binding[Curses::KEY_DOWN] = key_action['scroll_current_window_down_page']
  else
    key_binding[Curses::KEY_UP] = key_action['previous_command']
    key_binding[Curses::KEY_DOWN] = key_action['next_command']
  end
}

key_action['send_command'] = proc {
  cmd = command_buffer.dup
  command_buffer.clear
  command_buffer_pos = 0
  command_buffer_offset = 0
  need_prompt = false
  if (window = stream_handler['main'])
    add_prompt(window, prompt_text, cmd)
  end
  command_window.deleteln
  command_window.setpos(0, 0)
  command_window.noutrefresh
  Curses.doupdate
  command_history_pos = 0
  # Remember all digit commands because they are likely spells for voodoo.lic
  if (cmd.length >= min_cmd_length_for_history || cmd.digits?) and (cmd != command_history[1])
    if command_history[0].nil? or command_history[0].empty?
      command_history[0] = cmd
    else
      command_history.unshift cmd
    end
    command_history.unshift String.new
  end
  if cmd =~ /^\.quit/
    exit
  elsif cmd =~ /^\.key/i
    window = stream_handler['main']
    window.add_string("* ")
    window.add_string("* Waiting for key press...")
    command_window.noutrefresh
    Curses.doupdate
    window.add_string("* Detected keycode: #{command_window.getch}")
    window.add_string("* ")
    Curses.doupdate
  elsif cmd =~ /^\.copy/
    # fixme
  elsif cmd =~ /^\.fixcolor/i
    if CUSTOM_COLORS
      COLOR_ID_LOOKUP.each { |code, id|
        Curses.init_color(id, ((code[0..1].to_s.hex / 255.0) * 1000).round, ((code[2..3].to_s.hex / 255.0) * 1000).round, ((code[4..5].to_s.hex / 255.0) * 1000).round)
      }
    end
  elsif cmd =~ /^\.resync/i
    skip_server_time_offset = false
  elsif cmd =~ /^\.reload/i
    load_settings_file.call(true)
  elsif cmd =~ /^\.layout\s+(.+)/
    load_layout.call($1)
    key_action['resize'].call
  elsif cmd =~ /^\.arrow/i
    key_action['switch_arrow_mode'].call
  elsif cmd =~ /^\.e (.*)/
    eval(cmd.sub(/^\.e /, ''))
  elsif cmd =~ /^\.links/i
    blue_links = !blue_links
  else
    server.puts cmd.sub(/^\./, ';')
  end
}

key_action['send_last_command'] = proc {
  if (cmd = command_history[1])
    if (window = stream_handler['main'])
      add_prompt(window, prompt_text, cmd)
      # window.add_string(">#{cmd}", [ h={ :start => 0, :end => (cmd.length + 1), :fg => '555555' } ])
      command_window.noutrefresh
      Curses.doupdate
    end
    if cmd =~ /^\.quit/i
      exit
    elsif cmd =~ /^\.fixcolor/i
      if CUSTOM_COLORS
        COLOR_ID_LOOKUP.each { |code, id|
          Curses.init_color(id, ((code[0..1].to_s.hex / 255.0) * 1000).round, ((code[2..3].to_s.hex / 255.0) * 1000).round, ((code[4..5].to_s.hex / 255.0) * 1000).round)
        }
      end
    elsif cmd =~ /^\.resync/i
      skip_server_time_offset = false
    elsif cmd =~ /^\.arrow/i
      key_action['switch_arrow_mode'].call
    elsif cmd =~ /^\.e (.*)/
      eval(cmd.sub(/^\.e /, ''))
    else
      server.puts cmd.sub(/^\./, ';')
    end
  end
}

key_action['send_second_last_command'] = proc {
  if (cmd = command_history[2])
    if (window = stream_handler['main'])
      add_prompt(window, prompt_text, cmd)
      # window.add_string(">#{cmd}", [ h={ :start => 0, :end => (cmd.length + 1), :fg => '555555' } ])
      command_window.noutrefresh
      Curses.doupdate
    end
    if cmd =~ /^\.quit/i
      exit
    elsif cmd =~ /^\.fixcolor/i
      if CUSTOM_COLORS
        COLOR_ID_LOOKUP.each { |code, id|
          Curses.init_color(id, ((code[0..1].to_s.hex / 255.0) * 1000).round, ((code[2..3].to_s.hex / 255.0) * 1000).round, ((code[4..5].to_s.hex / 255.0) * 1000).round)
        }
      end
    elsif cmd =~ /^\.resync/i
      skip_server_time_offset = false
    elsif cmd =~ /^\.arrow/i
      key_action['switch_arrow_mode'].call
    elsif cmd =~ /^\.e (.*)/
      eval(cmd.sub(/^\.e /, ''))
    else
      server.puts cmd.sub(/^\./, ';')
    end
  end
}

new_stun = proc { |seconds|
  if (window = countdown_handler['stunned'])
    temp_stun_end = Time.now.to_f - $server_time_offset.to_f + seconds.to_f
    window.end_time = temp_stun_end
    window.update
    Thread.new {
      while (countdown_handler['stunned'].end_time == temp_stun_end) and (countdown_handler['stunned'].value > 0)
        sleep 0.15
        if countdown_handler['stunned'].update
          command_window.noutrefresh
          Curses.doupdate
        end
      end
    }
  end
}

load_settings_file.call(false)
load_layout.call('default')

TextWindow.list.each { |w| w.maxy.times { w.add_string "\n" } }

server = TCPSocket.open(HOST, PORT)

Thread.new { sleep 15; skip_server_time_offset = false }

Thread.new {
  begin
    line = nil
    need_update = false
    line_colors = Array.new
    open_monsterbold = Array.new
    open_preset = Array.new
    open_style = nil
    open_color = Array.new
    open_link = Array.new
    current_stream = nil

    handle_game_text = proc { |text|
      for escapable in xml_escape_list.keys
        search_pos = 0
        while (pos = text.index(escapable, search_pos))
          text = text.sub(escapable, xml_escape_list[escapable])
          line_colors.each { |h|
            h[:start] -= (escapable.length - 1) if h[:start] > pos
            h[:end] -= (escapable.length - 1) if h[:end] > pos
          }
          if open_style and (open_style[:start] > pos)
            open_style[:start] -= (escapable.length - 1)
          end
        end
      end

      if text =~ /^\[.*?\]>/
        need_prompt = false
      elsif text =~ /^\s*You are stunned for ([0-9]+) rounds?/
        new_stun.call($1.to_i * 5)
      elsif text =~ /^Deep and resonating, you feel the chant that falls from your lips instill within you with the strength of your faith\.  You crouch beside [A-Z][a-z]+ and gently lift (?:he|she|him|her) into your arms, your muscles swelling with the power of your deity, and cradle (?:him|her) close to your chest\.  Strength and life momentarily seep from your limbs, causing them to feel laden and heavy, and you are overcome with a sudden weakness\.  With a sigh, you are able to lay [A-Z][a-z]+ back down\.$|^Moisture beads upon your skin and you feel your eyes cloud over with the darkness of a rising storm\.  Power builds upon the air and when you utter the last syllable of your spell thunder rumbles from your lips\.  The sound ripples upon the air, and colling with [A-Z][a-z&apos;]+ prone form and a brilliant flash transfers the spiritual energy between you\.$|^Lifting your finger, you begin to chant and draw a series of conjoined circles in the air\.  Each circle turns to mist and takes on a different hue - white, blue, black, red, and green\.  As the last ring is completed, you spread your fingers and gently allow your tips to touch each color before pushing the misty creation towards [A-Z][a-z]+\.  A shock of energy courses through your body as the mist seeps into [A-Z][a-z&apos;]+ chest and life is slowly returned to (?:his|her) body\.$|^Crouching beside the prone form of [A-Z][a-z]+, you softly issue the last syllable of your chant\.  Breathing deeply, you take in the scents around you and let the feel of your surroundings infuse you\.  With only your gaze, you track the area and recreate the circumstances of [A-Z][a-z&apos;]+ within your mind\.  Touching [A-Z][a-z]+, you follow the lines of the web that holds (?:his|her) soul in place and force it back into (?:his|her) body\.  Raw energy courses through you and you feel your sense of justice and vengeance filling [A-Z][a-z]+ with life\.$|^Murmuring softly, you call upon your connection with the Destroyer,? and feel your words twist into an alien, spidery chant\.  Dark shadows laced with crimson swirl before your eyes and at your forceful command sink into the chest of [A-Z][a-z]+\.  The transference of energy is swift and immediate as you bind [A-Z][a-z]+ back into (?:his|her) body\.$|^Rich and lively, the scent of wild flowers suddenly fills the air as you finish your chant, and you feel alive with the energy of spring\.  With renewal at your fingertips, you gently touch [A-Z][a-z]+ on the brow and revel in the sweet rush of energy that passes through you into (?:him|her|his)\.$|^Breathing slowly, you extend your senses towards the world around you and draw into you the very essence of nature\.  You shift your gaze towards [A-z][a-z]+ and carefully release the energy you&apos;ve drawn into yourself towards (?:him|her)\.  A rush of energy briefly flows between the two of you as you feel life slowly return to (?:him|her)\.$|^Your surroundings grow dim\.\.\.you lapse into a state of awareness only, unable to do anything\.\.\.$|^Murmuring softly, a mournful chant slips from your lips and you feel welts appear upon your wrists\.  Dipping them briefly, you smear the crimson liquid the leaks from these sudden wounds in a thin line down [A-Z][a-z&apos;]+ face\.  Tingling with each second that your skin touches (?:his|hers), you feel the transference of your raw energy pass into [A-Z][a-z]+ and momentarily reel with the pain of its release\.  Slowly, the wounds on your wrists heal, though a lingering throb remains\.$|^Emptying all breathe from your body, you slowly still yourself and close your eyes\.  You reach out with all of your senses and feel a film shift across your vision\.  Opening your eyes, you gaze through a white haze and find images of [A-Z][a-z]+ floating above his prone form\.  Acts of [A-Z][a-z]&apos;s? past, present, and future play out before your clouded vision\.  With conviction and faith, you pluck a future image of [A-Z][a-z]+ from the air and coax (?:he|she|his|her) back into (?:he|she|his|her) body\.  Slowly, the film slips from your eyes and images fade away\.$|^Thin at first, a fine layer of rime tickles your hands and fingertips\.  The hoarfrost smoothly glides between you and [A-Z][a-z]+, turning to a light powder as it traverses the space\.  The white substance clings to [A-Z][a-z]+&apos;s? eyelashes and cheeks for a moment before it becomes charged with spiritual power, then it slowly melts away\.$|^As you begin to chant,? you notice the scent of dry, dusty parchment and feel a cool mist cling to your skin somewhere near your feet\.  You sense the ethereal tendrils of the mist as they coil about your body and notice that the world turns to a yellowish hue as the mist settles about your head\.  Focusing on [A-Z][a-z]+, you feel the transfer of energy pass between you as you return (?:him|her) to life\.$|^Wrapped in an aura of chill, you close your eyes and softly begin to chant\.  As the cold air that surrounds you condenses you feel it slowly ripple outward in waves that turn the breath of those nearby into a fine mist\.  This mist swiftly moves to encompass you and you feel a pair of wings arc over your back\.  With the last words of your chant, you open your eyes and watch as foggy wings rise above you and gently brush against [A-Z][a-z]+\.  As they dissipate in a cold rush against [A-Z][a-z]+, you feel a surge of power spill forth from you and into (?:him|her)\.$|^As .*? begins to chant, your spirit is drawn closer to your body by the scent of dusty, dry parchment\.  Topaz tendrils coil about .*?, and you feel an ancient presence demand that you return to your body\.  All at once .*? focuses upon you and you feel a surge of energy bind you back into your now-living body\.$/
        # raise dead stun
        new_stun.call(30.6)
      elsif text =~ /^Just as you think the falling will never end, you crash through an ethereal barrier which bursts into a dazzling kaleidoscope of color!  Your sensation of falling turns to dizziness and you feel unusually heavy for a moment\.  Everything seems to stop for a prolonged second and then WHUMP!!!/
        # Shadow Valley exit stun
        new_stun.call(16.2)
      elsif text =~ /^You have.*?(?:case of uncontrollable convulsions|case of sporadic convulsions|strange case of muscle twitching)/
        # nsys wound will be correctly set by xml, dont set the scar using health verb output
        true
      else
        if (window = indicator_handler['nsys'])
          if text =~ /^You have.*? very difficult time with muscle control/
            if window.update(3)
              need_update = true
            end
          elsif text =~ /^You have.*? constant muscle spasms/
            if window.update(2)
              need_update = true
            end
          elsif text =~ /^You have.*? developed slurred speech/
            if window.update(1)
              need_update = true
            end
          end
        end
      end

      if open_style
        h = open_style.dup
        h[:end] = text.length
        line_colors.push(h)
        open_style[:start] = 0
      end
      for oc in open_color
        ocd = oc.dup
        ocd[:end] = text.length
        line_colors.push(ocd)
        oc[:start] = 0
      end

      if current_stream.nil? or stream_handler[current_stream] or (current_stream =~ /^(?:death|logons|thoughts|voln|familiar)$/)
        SETTINGS_LOCK.synchronize {
          HIGHLIGHT.each_pair { |regex, colors|
            pos = 0
            while (match_data = text.match(regex, pos))
              h = {
                :start    => match_data.begin(0),
                :end      => match_data.end(0),
                :fg       => colors[0],
                :bg       => colors[1],
                :ul       => colors[2],
                :priority => 1
              }
              line_colors.push(h)
              pos = match_data.end(0)
            end
          }
        }
      end

      unless text.empty?
        if current_stream
          if current_stream == 'thoughts'
            if text =~ /^\[.+?\]\-[A-z]+\:[A-Z][a-z]+\: "|^\[server\]\: /
              current_stream = 'lnet'
            end
          end
          if (window = stream_handler[current_stream])
            if current_stream == 'death'
              # fixme: has been vaporized!
              # fixme: ~ off to a rough start
              if text =~ /^\s\*\s(The death cry of )?([7A-Z][a-z]+)(?:['s]*) (just bit the dust!|life on land appears to be as rough as (?:his|her) life at sea\.|just got iced in the Hinterwilds!|is off to a rough start!  (?:He|She) just bit the dust!|echoes in your mind!|just got squashed!|has gone to feed the fishes!|just turned (?:his|her) last page!|is off to a rough start!  (?:He|She) was just put on ice!|was just put on ice!|just punched a one-way ticket!|is going home on (?:his|her) shield!|just took a long walk off of a short pier!|is dust in the wind!|is six hundred feet under!|just lost (?:his|her) way somewhere in the Settlement of Reim!|just gave up the ghost!|flame just burnt out in the Sea of Fire!|failed within the Bank at Bloodriven|was just defeated in Duskruin Arena!|was just defeated during round \d+ in (?:Endless )?Duskruin Arena!|failed to bring a shrubbery to the Night at the Academy!|just sank to the bottom of the (?:Great Western Sea|Tenebrous Cauldron)!|was just defeated in the Arena of the Abyss!)/
                front_count = 3
                if $1
                  front_part = $1
                  front_count += front_part.length
                end
                name = $2
                area = $3
                if area =~ /just bit the dust!/
                  area = "WL"
                elsif area =~ /echoes in your mind!/
                  area = "RIFT"
                elsif area =~ /just got squashed!/
                  area = "CY"
                elsif area =~ /has gone to feed the fishes!/
                  area = "RR"
                elsif area =~ /life on land appears to be as rough as (?:his|her) life at sea\./
                  area = "KF"
                elsif area =~ /just turned (?:his|her) last page!/
                  area = "TI"
                elsif area =~ /is off to a rough start!  (?:He|She) was just put on ice!|was just put on ice!/
                  area = "IMT"
                elsif area =~ /just sank to the bottom of the (?:Great Western Sea|Tenebrous Cauldron)!/
                  area = "OSA"
                elsif area =~ /just gave up the ghost!/
                  area = "TRAIL"
                elsif area =~ /just got iced in the Hinterwilds!/
                  area = "HW"
                elsif area =~ /just punched a one-way ticket!/
                  area = "KD"
                elsif area =~ /is going home on (?:his|her) shield!/
                  area = "TV"
                elsif area =~ /just took a long walk off of a short pier!/
                  area = "SOL"
                elsif area =~ /is dust in the wind!/
                  area = "FWI"
                elsif area =~ /is six hundred feet under!/
                  area = "ZUL"
                elsif area =~ /just lost (?:his|her) way somewhere in the Settlement of Reim!/
                  area = "REIM"
                elsif area =~ /may just be going home on (?:his|her) shield!/
                  area = "RED"
                elsif area =~ /flame just burnt out in the Sea of Fire!/
                  area = "SOS"
                elsif area =~ /failed within the Bank at Bloodriven/
                  area = "DR-B"
                elsif area =~ /was just defeated in Duskruin Arena!/
                  area = "DR-A"
                elsif area =~ /was just defeated during round \d+ in (?:Endless )?Duskruin Arena!/
                  area = "DR-A"
                elsif area =~ /was just defeated in the Arena of the Abyss!/
                  area = "EG-A"
                elsif area =~ /failed to bring a shrubbery to the Night at the Academy!/
                  area = "NATA"
                elsif area =~ /has just returned to Gosaena!/
                  area = "??"
                end
                text = "#{name} #{area} #{Time.now.strftime('%H:%M').sub(/^0/, '')}"
                line_colors.each { |hl|
                  hl[:start] -= front_count
                  hl[:end] = [hl[:end], name.length].min
                }
                line_colors.delete_if { |hl| hl[:start] >= hl[:end] }
                h = {
                  :start => (name.length + area.length + 2),
                  :end   => text.length,
                  :fg    => 'ff0000',
                }
                line_colors.push(h)
              elsif line =~ /^\s\*\s(The death cry of )?([7A-Z][a-z]+)(?:['s]*) (has been vaporized!|was just incinerated!)/
                text = ""
              end
            elsif current_stream == 'speech'
              text = "#{text} (#{Time.now.strftime('%H:%M:%S').sub(/^0/, '')})" if Opts["speech-ts"]
            elsif current_stream == 'logons'
              foo = { 'joins the adventure.' => PRESET['logons'][0], 'returns home from a hard day of adventuring.' => PRESET['logoffs'][0], 'has disconnected.' => PRESET['disconnects'][0] }
              joo = { 'joins the adventure.' => PRESET['logons'][1], 'returns home from a hard day of adventuring.' => PRESET['logoffs'][1], 'has disconnected.' => PRESET['disconnects'][1] }
              if text =~ /^\s\*\s([A-Z][a-z]+) (#{foo.keys.join('|')})/
                name = $1
                logon_type = $2
                text = "#{name} #{Time.now.strftime('%l:%M%P').sub(/^0/, '')}"
                line_colors.each { |hl|
                  hl[:start] -= 3
                  hl[:end] = [hl[:end], name.length].min
                }
                line_colors.delete_if { |hl| hl[:start] >= hl[:end] }
                h = {
                  :start => (name.length + 1),
                  :end   => text.length,
                  :fg    => foo[logon_type],
                  :bg    => joo[logon_type],
                }
                line_colors.push(h)
              end
            end
            unless text =~ /^\[server\]: "(?:kill|connect)/
              window.add_string(text, line_colors)
              need_update = true
            end
          elsif current_stream =~ /^(?:death|logons|thoughts|voln|familiar)$/
            if current_stream =~ /^(?:thoughts|familiar)$/
              text = "#{text} (#{Time.now.strftime('%H:%M:%S').sub(/^0/, '')})" if Opts["speech-ts"]
            end
            if (window = stream_handler['main'])
              if PRESET[current_stream]
                line_colors.push(:start => 0, :fg => PRESET[current_stream][0], :bg => PRESET[current_stream][1], :end => text.length)
              end
              unless text.empty?
                if need_prompt
                  need_prompt = false
                  add_prompt(window, prompt_text)
                end
                window.add_string(text, line_colors)
                need_update = true
              end
            end
          else
            # stream_handler['main'].add_string "#{current_stream}: #{text.inspect}"
          end
        else
          if (window = stream_handler['main'])
            if need_prompt
              need_prompt = false
              add_prompt(window, prompt_text)
            end
            window.add_string(text, line_colors)
            need_update = true
          end
        end
      end
      line_colors = Array.new
      open_monsterbold.clear
      open_preset.clear
      # open_color.clear
    }

    while (line = server.gets)
      line.chomp!
      if line.empty?
        if current_stream.nil?
          if need_prompt
            need_prompt = false
            add_prompt(stream_handler['main'], prompt_text)
          end
          stream_handler['main'].add_string String.new
          need_update = true
        end
      else
        while (start_pos = (line =~ /(<(prompt|spell|right|left|inv|style|compass).*?\2>|<.*?>)/))
          xml = $1
          line.slice!(start_pos, xml.length)
          if xml =~ /^<prompt time=('|")([0-9]+)\1.*?>(.*?)&gt;<\/prompt>$/
            Profanity.put(prompt: "#{$3.clone}".strip)
            Profanity.update_process_title()
            unless skip_server_time_offset
              $server_time_offset = Time.now.to_f - $2.to_f
              skip_server_time_offset = true
            end
            new_prompt_text = "#{$3}>"
            if prompt_text != new_prompt_text
              need_prompt = false
              prompt_text = new_prompt_text
              add_prompt(stream_handler['main'], new_prompt_text)
              if (prompt_window = indicator_handler["prompt"])
                init_prompt_height, init_prompt_width = fix_layout_number.call(prompt_window.layout[0]), fix_layout_number.call(prompt_window.layout[1])
                new_prompt_width = new_prompt_text.length
                prompt_window.resize(init_prompt_height, new_prompt_width)
                prompt_width_diff = new_prompt_width - init_prompt_width
                command_window.resize(fix_layout_number.call(command_window_layout[0]), fix_layout_number.call(command_window_layout[1]) - prompt_width_diff)
                ctop, cleft = fix_layout_number.call(command_window_layout[2]), fix_layout_number.call(command_window_layout[3]) + prompt_width_diff
                command_window.move(ctop, cleft)
                prompt_window.label = new_prompt_text
              end
            else
              need_prompt = true
            end
          elsif xml =~ /^<spell(?:>|\s.*?>)(.*?)<\/spell>$/
            if (window = indicator_handler['spell'])
              window.clear
              window.label = $1
              window.update($1 == 'None' ? 0 : 1)
              need_update = true
            end
          elsif xml =~ /^<streamWindow id='room' title='Room' subtitle=" \- (.*?)"/
            Profanity.put(room: $1)
            Profanity.update_process_title()
            if (window = indicator_handler["room"])
              window.clear
              window.label = $1
              window.update($1 ? 0 : 1)
              need_update = true
            end
          elsif xml =~ /^<(right|left)(?:>|\s.*?>)(.*?)<\/\1>/
            if (window = indicator_handler[$1])
              window.clear
              window.label = $2
              window.update($2 == 'Empty' ? 0 : 1)
              need_update = true
            end
          elsif xml =~ /^<roundTime value=('|")([0-9]+)\1/
            if (window = countdown_handler['roundtime'])
              temp_roundtime_end = $2.to_i
              window.end_time = temp_roundtime_end
              window.update
              need_update = true
              Thread.new {
                sleep 0.15
                while (countdown_handler['roundtime'].end_time == temp_roundtime_end) and (countdown_handler['roundtime'].value > 0)
                  sleep 0.15
                  if countdown_handler['roundtime'].update
                    command_window.noutrefresh
                    Curses.doupdate
                  end
                end
              }
            end
          elsif xml =~ /^<castTime value=('|")([0-9]+)\1/
            if (window = countdown_handler['roundtime'])
              temp_casttime_end = $2.to_i
              window.secondary_end_time = temp_casttime_end
              window.update
              need_update = true
              Thread.new {
                while (countdown_handler['roundtime'].secondary_end_time == temp_casttime_end) and (countdown_handler['roundtime'].secondary_value > 0)
                  sleep 0.15
                  if countdown_handler['roundtime'].update
                    command_window.noutrefresh
                    Curses.doupdate
                  end
                end
              }
            end
          elsif xml =~ /^<compass/
            current_dirs = xml.scan(/<dir value="(.*?)"/).flatten
            for dir in ['up', 'down', 'out', 'n', 'ne', 'e', 'se', 's', 'sw', 'w', 'nw']
              if (window = indicator_handler["compass:#{dir}"])
                if window.update(current_dirs.include?(dir))
                  need_update = true
                end
              end
            end
          elsif xml =~ /^<progressBar id='encumlevel' value='([0-9]+)' text='(.*?)'/
            if (window = progress_handler['encumbrance'])
              if $2 == 'Overloaded'
                value = 110
              else
                value = $1.to_i
              end
              if window.update(value, 110)
                need_update = true
              end
            end

          elsif xml =~ /^<progressBar id='pbarStance' value='([0-9]+)'/
            if (window = progress_handler['stance'])
              if window.update($1.to_i, 100)
                need_update = true
              end
            end
          elsif xml =~ /^<progressBar id='mindState' value='(.*?)' text='(.*?)'/
            if (window = progress_handler['mind'])
              if $2 == 'saturated'
                value = 110
              else
                value = $1.to_i
              end
              if window.update(value, 110)
                need_update = true
              end
            end
          elsif xml =~ /^<progressBar id='(.*?)' value='[0-9]+' text='.*?\s+(\-?[0-9]+)\/([0-9]+)'/
            if (window = progress_handler[$1])
              if window.update($2.to_i, $3.to_i)
                need_update = true
              end
            end
          # accepts (mostly) arbitrary progress bars with dynamic color codes, etc.
          # useful for user defined progress bars (i.e. spell active timer, item cooldowns, etc.)
          # example XML to trigger:
          #  <arbProgress id='spellactivel' max='250' current='160' label='WaterWalking' colors='1589FF,000000'</arbProgress>
          elsif xml =~ /^<arbProgress id='([a-zA-Z0-9]+)' max='(\d+)' current='(\d+)'(?: label='(.+?)')?(?: colors='(\S+?)')?/
            bar = $1
            max = $2.to_i
            current = $3.to_i
            current = max if current > max
            label = $4
            colors = $5
            bg, fg = colors.split(',') if colors
            if (window = progress_handler[bar])
              window.label = label if label
              window.bg = [bg] if bg
              window.fg = [fg] if fg
              if window.update(current, max, true)
                need_update = true
              end
            end
          elsif xml == '<pushBold/>' or xml == '<b>'
            h = { :start => start_pos }
            if PRESET['monsterbold']
              h[:fg] = PRESET['monsterbold'][0]
              h[:bg] = PRESET['monsterbold'][1]
              h[:priority] = 1
            end
            open_monsterbold.push(h)
          elsif xml == '<popBold/>' or xml == '</b>'
            if (h = open_monsterbold.pop)
              h[:end] = start_pos
              line_colors.push(h) if h[:fg] or h[:bg]
            end
          elsif xml =~ /^<preset id=('|")(.*?)\1>$/
            h = { :start => start_pos }
            if PRESET[$2]
              h[:fg] = PRESET[$2][0]
              h[:bg] = PRESET[$2][1]
              h[:priority] = 1
            end
            open_preset.push(h)
          elsif xml == '</preset>'
            if (h = open_preset.pop)
              h[:end] = start_pos
              line_colors.push(h) if h[:fg] or h[:bg]
            end
          elsif xml =~ /^<color/
            h = { :start => start_pos }
            if xml =~ /\sfg=('|")(.*?)\1[\s>]/
              h[:fg] = $2.downcase
            end
            if xml =~ /\sbg=('|")(.*?)\1[\s>]/
              h[:bg] = $2.downcase
            end
            if xml =~ /\sul=('|")(.*?)\1[\s>]/
              h[:ul] = $2.downcase
            end
            open_color.push(h)
          elsif xml == '</color>'
            if (h = open_color.pop)
              h[:end] = start_pos
              line_colors.push(h)
            end
          elsif xml =~ /^<style id=('|")(.*?)\1/
            if $2.empty?
              if open_style
                open_style[:end] = start_pos
                if (open_style[:start] < open_style[:end]) and (open_style[:fg] or open_style[:bg])
                  line_colors.push(open_style)
                end
                open_style = nil
              end
            else
              open_style = { :start => start_pos }
              if PRESET[$2]
                open_style[:fg] = PRESET[$2][0]
                open_style[:bg] = PRESET[$2][1]
              end
            end
          elsif xml =~ /^<(?:pushStream|component|compDef) id=("|')(.*?)\1[^>]*\/?>$/
            new_stream = $2
            game_text = line.slice!(0, start_pos)
            handle_game_text.call(game_text)
            current_stream = new_stream
          elsif xml =~ /^<clearStream id=['"](\w+)['"]\/>$/
            stream_handler[$1].clear_window if stream_handler[$1]
          elsif xml =~ /^<popStream/ or xml == '</component>'
            game_text = line.slice!(0, start_pos)
            handle_game_text.call(game_text)
            current_stream = nil
          elsif xml =~ /^<progressBar/
            nil
          elsif xml =~ /^<(?:dialogdata|d|\/d|\/?component|label|skin|output)/
            nil
          elsif xml =~ /^<indicator id=('|")Icon([A-Z]+)\1 visible=('|")([yn])\3/
            if (window = countdown_handler[$2.downcase])
              window.active = ($4 == 'y')
              if window.update
                need_update = true
              end
            end
            if (window = indicator_handler[$2.downcase])
              if window.update($4 == 'y')
                need_update = true
              end
            end
          elsif xml =~ /^<image id=('|")(back|leftHand|rightHand|head|rightArm|abdomen|leftEye|leftArm|chest|rightLeg|neck|leftLeg|nsys|rightEye)\1 name=('|")(.*?)\3/
            if Regexp.last_match(2) == 'nsys'
              if (window = indicator_handler['nsys'])
                if (rank = $4.slice(/[0-9]/))
                  if window.update(rank.to_i)
                    need_update = true
                  end
                else
                  if window.update(0)
                    need_update = true
                  end
                end
              end
            else
              fix_value = { 'Injury1' => 1, 'Injury2' => 2, 'Injury3' => 3, 'Scar1' => 4, 'Scar2' => 5, 'Scar3' => 6 }
              if (window = indicator_handler[Regexp.last_match(2)])
                if window.update(fix_value[Regexp.last_match(4)] || 0)
                  need_update = true
                end
              end
            end
          elsif xml =~ /^<LaunchURL src="([^"]+)"/
            url = "\"https://www.play.net#{$1}\""
            @url = url

            if Opts["remote-url"]
              stream_handler['main'].add_string ' *'
              stream_handler['main'].add_string " * LaunchURL: #{url.gsub("\"", "")}"
              stream_handler['main'].add_string ' *'
            else
              if RbConfig::CONFIG['host_os'] =~ /mswin|mingw|cygwin/
                system "start #{url} >/dev/null 2>&1 &"
              elsif RbConfig::CONFIG['host_os'] =~ /darwin/
                system "open #{url} >/dev/null 2>&1 &"
              elsif RbConfig::CONFIG['host_os'] =~ /linux|bsd/
                system "xdg-open #{url} >/dev/null 2>&1 &"
              end
            end
          elsif xml =~ /^<a/
            if blue_links
              h = { :start => start_pos }
              h[:fg] = PRESET['links'][0]
              h[:bg] = PRESET['links'][1]
              h[:priority] = 2
              open_link.push(h)
            end
          elsif xml == '</a>'
            if (h = open_link.pop)
              h[:end] = start_pos
              line_colors.push(h) if h[:fg] or h[:bg]
            end
          else
            nil
          end
        end
        handle_game_text.call(line)
      end
      #
      # delay screen update if there are more game lines waiting
      #
      if need_update and not IO.select([server], nil, nil, 0.01)
        need_update = false
        command_window.noutrefresh
        Curses.doupdate
      end
    end
    stream_handler['main'].add_string ' *'
    stream_handler['main'].add_string ' * Connection closed'
    stream_handler['main'].add_string ' *'
    command_window.noutrefresh
    Curses.doupdate
  rescue
    Profanity.log { |f| f.puts $!; f.puts $!.backtrace[0...4] }
    exit
  end
}

begin
  key_combo = nil
  loop {
    ch = command_window.getch
    Autocomplete.consume(ch)
    if key_combo
      if key_combo[ch].class == Proc
        key_combo[ch].call
        key_combo = nil
      elsif key_combo[ch].class == Hash
        key_combo = key_combo[ch]
      else
        key_combo = nil
      end
    elsif key_binding[ch].class == Proc
      key_binding[ch].call
    elsif key_binding[ch].class == Hash
      key_combo = key_binding[ch]
    elsif ch.class == String
      command_window_put_ch.call(ch)
      command_window.noutrefresh
      Curses.doupdate
    end
  }
rescue => exception
  Profanity.log(exception.message)
  Profanity.log(exception.backtrace)
  raise exception
ensure
  begin
    server.close
  rescue => exception
    Profanity.log(exception.message)
    Profanity.log(exception.backtrace)
  end
  Curses.close_screen
end
