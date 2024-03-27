class Skill
  def initialize(name, ranks, percent, mindstate)
    @name = name
    @ranks = ranks
    @percent = percent
    @mindstate = mindstate
  end

  def to_s
    format('%8s:%5d %2s%% [%2s/34]', @name, @ranks, @percent, @mindstate)
  end

  def to_str
    format('%8s:%5d %2s%% [%2s/34]', @name, @ranks, @percent, @mindstate)
  end
end

class ExpWindow < Curses::Window
  attr_reader :color_stack, :buffer
  attr_accessor :scrollbar, :indent_word_wrap, :layout, :time_stamp

  @@list = []

  def self.list
    @@list
  end

  def initialize(*args)
    @skills = {}
    @open = false
    @@list.push(self)
    super(*args)
  end

  def delete_skill
    return unless @current_skill

    @skills.delete(@current_skill)
    redraw
    @current_skill = ''
  end

  def set_current(skill)
    @current_skill = skill
  end

  def add_string(text, _line_colors)
    return unless text =~ %r{(.+):\s*(\d+) (\d+)%  \[\s*(\d+)/34\]}

    # if text =~ /(\w+(\s\w+)?)<\/d>:\s+(\d+)(?:\s+)(\d{1,2}|100)%\s+\[\s?(\d+)\/34\]/
    name = ::Regexp.last_match(1).strip
    ranks = ::Regexp.last_match(2)
    percent = ::Regexp.last_match(3)
    mindstate = ::Regexp.last_match(4)

    skill = Skill.new(name, ranks, percent, mindstate)
    @skills[@current_skill] = skill
    redraw
    @current_skill = ''
  end

  def skill_group_color(skill)
    armor = ['Shield', 'Lt Armor', 'Chain', 'Brig', 'Plate', 'Defend', 'Convict']

    weapon = %w[Parry SE LE 2HE SB LB 2HB Slings Bows Crossbow Staves Polearms LT HT Brawling Offhand Melee Missile
                Expert]

    magic = %w[Magic IF IM Attune Arcana TM Aug Debil Util Warding Sorcery Astro Summon Theurgy]

    survival = %w[Evasion Athletic Perc Stealth Locks Thievery FA Outdoors Skinning BS Scouting Than Backstab]

    lore = %w[Forging Eng Outfit Alchemy Enchant Scholar Mech Appraise Perform Tactics BardLore Empathy Trading]

    if armor.include? skill
      '00FF00' # green
    elsif weapon.include? skill
      '00FFFF' # cyan
    elsif magic.include? skill
      'FF0000' # red
    elsif survival.include? skill
      'FF00FF' # magenta
    elsif lore.include? skill
      'FFFF00' # yellow
    end
  end

  def mindstate_color(mindstate)
    if mindstate == 0
      'FFFFFF' # white
    elsif (1..10).member?(mindstate)
      '00FFFF' # cyan
    elsif (11..20).member?(mindstate)
      '00FF00' # green
    elsif (21..30).member?(mindstate)
      'FFFF00' # yellow
    elsif (31..34).member?(mindstate)
      'FF0000' # red
    end
  end

  def add_skill(skill, skill_colors = [])

    SETTINGS_LOCK.synchronize do
      HIGHLIGHT.each_pair do |regex, colors|
        pos = 0
        while (match_data = skill.match(regex, pos))
          h = {
            start: match_data.begin(0),
            end: match_data.end(0),
            fg: colors[0],
            bg: colors[1],
            ul: colors[2]
          }
          skill_colors.push(h)
          pos = match_data.end(0)
        end
      end
    end

    # addstr skill
    part = [0, skill.length]
    skill_colors.each do |h|
      part.push(h[:start])
      part.push(h[:end])
    end
    part.uniq!
    part.sort!
    for i in 0...(part.length - 1)
      str = skill[part[i]...part[i + 1]]
      color_list = skill_colors.find_all { |h| (h[:start] <= part[i]) and (h[:end] >= part[i + 1]) }
      if color_list.empty?
        addstr str
        noutrefresh
      else
        color_list = color_list.sort_by { |h| h[:end] - h[:start] }
        fg = color_list.map { |h| h[:fg] }.find { |fg| !fg.nil? }
        bg = color_list.map { |h| h[:bg] }.find { |bg| !bg.nil? }
        ul = color_list.map { |h| h[:ul] == 'true' }.find { |ul| ul }
        attron(color_pair(get_color_pair_id(fg, bg)) | (ul ? Curses::A_UNDERLINE : Curses::A_NORMAL)) do
          addstr str
          noutrefresh
        end
      end
    end
  end

  def redraw
    clear
    setpos(0, 0)

    @skills.sort.each do |_name, skill|
      # addstr skill.to_s + "\n"
      add_skill(skill.to_s)
      # addstr(skill)
      addstr("\n")
      noutrefresh
    end
    noutrefresh
  end
end
