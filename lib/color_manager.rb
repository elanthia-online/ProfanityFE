# frozen_string_literal: true

# color_manager.rb: Curses color and color pair management for ProfanityFE.

# Manages curses color allocation and color pair caching.
# Supports both custom colors (terminal reprogramming via init_color) and
# fixed palette mode (nearest-match in the standard 256-color table).
#
# Call {.configure} after CLI parsing to initialize color state.
#
# @example
#   ColorManager.configure(default_color_id: 7, default_background_color_id: 0, custom_colors: true)
#   pair_id = ColorManager.get_color_pair_id('ff0000', '000000')
module ColorManager
  # Highest pair count the renderer can address. Rendering goes through
  # +Curses.color_pair(n)+ + +attron+/+attrset+, which packs the pair number
  # into the 8-bit A_COLOR field of a chtype attribute. Pair 256 overflows
  # into A_STANDOUT, 512 into A_UNDERLINE, etc., even when the terminal
  # reports far more pairs (xterm-256color reports 32767).
  MAX_RENDERABLE_COLOR_PAIRS = 256

  @default_color_id = 7
  @default_background_color_id = 0
  @default_color_code = nil
  @default_background_color_code = nil
  @custom_colors = false
  @color_id_lookup = {}
  @color_id_history = []
  @color_pair_id_lookup = {}
  @color_pair_history = []
  @color_code = nil
  @color_mutex = Mutex.new

  class << self
    attr_accessor :default_color_id, :default_background_color_id,
                  :default_color_code, :default_background_color_code,
                  :custom_colors

    # Initialize the color system. Must be called after Curses.init_screen and CLI parsing.
    # Resets all color and pair caches. The pair pool holds pairs
    # 1...min(Curses.color_pairs, {MAX_RENDERABLE_COLOR_PAIRS}).
    #
    # @param default_color_id [Integer] curses color ID for default foreground
    # @param default_background_color_id [Integer] curses color ID for default background
    # @param custom_colors [Boolean] whether to use init_color for custom RGB colors
    # @return [void]
    def configure(default_color_id:, default_background_color_id:, custom_colors:)
      @default_color_id = default_color_id
      @default_background_color_id = default_background_color_id
      @custom_colors = custom_colors

      # Calculate color codes from curses
      @default_color_code = curses_rgb_to_hex(Curses.color_content(@default_color_id))
      @default_background_color_code = curses_rgb_to_hex(Curses.color_content(@default_background_color_id))

      # Initialize color ID lookup
      @color_id_lookup = {}
      @color_id_history = []

      if @custom_colors
        @color_id_lookup[@default_color_code] = @default_color_id
        @color_id_lookup[@default_background_color_code] = @default_background_color_id
        (0...Curses.colors).each do |num|
          @color_id_history.push(num) unless (num == @default_color_id) || (num == @default_background_color_id)
        end
      else
        @color_code = %w[000000 800000 008000 808000 000080 800080 008080 c0c0c0 808080 ff0000
                         00ff00 ffff00 0000ff ff00ff 00ffff ffffff 000000 00005f 000087 0000af 0000d7 0000ff 005f00 005f5f 005f87 005faf 005fd7 005fff 008700 00875f 008787 0087af 0087d7 0087ff 00af00 00af5f 00af87 00afaf 00afd7 00afff 00d700 00d75f 00d787 00d7af 00d7d7 00d7ff 00ff00 00ff5f 00ff87 00ffaf 00ffd7 00ffff 5f0000 5f005f 5f0087 5f00af 5f00d7 5f00ff 5f5f00 5f5f5f 5f5f87 5f5faf 5f5fd7 5f5fff 5f8700 5f875f 5f8787 5f87af 5f87d7 5f87ff 5faf00 5faf5f 5faf87 5fafaf 5fafd7 5fafff 5fd700 5fd75f 5fd787 5fd7af 5fd7d7 5fd7ff 5fff00 5fff5f 5fff87 5fffaf 5fffd7 5fffff 870000 87005f 870087 8700af 8700d7 8700ff 875f00 875f5f 875f87 875faf 875fd7 875fff 878700 87875f 878787 8787af 8787d7 8787ff 87af00 87af5f 87af87 87afaf 87afd7 87afff 87d700 87d75f 87d787 87d7af 87d7d7 87d7ff 87ff00 87ff5f 87ff87 87ffaf 87ffd7 87ffff af0000 af005f af0087 af00af af00d7 af00ff af5f00 af5f5f af5f87 af5faf af5fd7 af5fff af8700 af875f af8787 af87af af87d7 af87ff afaf00 afaf5f afaf87 afafaf afafd7 afafff afd700 afd75f afd787 afd7af afd7d7 afd7ff afff00 afff5f afff87 afffaf afffd7 afffff d70000 d7005f d70087 d700af d700d7 d700ff d75f00 d75f5f d75f87 d75faf d75fd7 d75fff d78700 d7875f d78787 d787af d787d7 d787ff d7af00 d7af5f d7af87 d7afaf d7afd7 d7afff d7d700 d7d75f d7d787 d7d7af d7d7d7 d7d7ff d7ff00 d7ff5f d7ff87 d7ffaf d7ffd7 d7ffff ff0000 ff005f ff0087 ff00af ff00d7 ff00ff ff5f00 ff5f5f ff5f87 ff5faf ff5fd7 ff5fff ff8700 ff875f ff8787 ff87af ff87d7 ff87ff ffaf00 ffaf5f ffaf87 ffafaf ffafd7 ffafff ffd700 ffd75f ffd787 ffd7af ffd7d7 ffd7ff ffff00 ffff5f ffff87 ffffaf ffffd7 ffffff 080808 121212 1c1c1c 262626 303030 3a3a3a 444444 4e4e4e 585858 626262 6c6c6c 767676 808080 8a8a8a 949494 9e9e9e a8a8a8 b2b2b2 bcbcbc c6c6c6 d0d0d0 dadada e4e4e4 eeeeee][0...Curses.colors]
      end

      # Initialize color pair lookup. Pair 0 is reserved by curses; the pool
      # is capped so no pair number overflows the attribute's color field
      # (see MAX_RENDERABLE_COLOR_PAIRS). Once exhausted, pairs are recycled
      # FIFO by {.get_color_pair_id}.
      @color_pair_id_lookup = {}
      @color_pair_history = (1...[Curses.color_pairs, MAX_RENDERABLE_COLOR_PAIRS].min).to_a
    end

    # Re-initialize all custom colors from the lookup table.
    # Called by the .fixcolor command to repair corrupted terminal colors.
    #
    # @return [void]
    def reinitialize_colors
      return unless @custom_colors

      @color_id_lookup.each do |code, id|
        Curses.init_color(id, *hex_to_curses_rgb(code))
      end
    end

    # Get or allocate a curses color ID for a hex color code.
    # In custom mode, reprograms a color slot via Curses.init_color.
    # In fixed mode, finds the nearest match in the 256-color palette.
    #
    # @param code [String] 6-digit hex color code (e.g., "ff0000"); callers must
    #   pass a valid code (see {.get_color_pair_id}, which normalizes input)
    # @return [Integer] curses color ID
    def get_color_id(code)
      if (color_id = @color_id_lookup[code])
        color_id
      elsif @custom_colors
        @color_mutex.synchronize do
          color_id = @color_id_history.shift
          @color_id_lookup.delete_if { |_k, v| v == color_id }
          @color_id_lookup[code] = color_id
          @color_id_history.push(color_id)
        end
        # ncurses needs a small delay between init_color/init_pair calls
        # on some terminal emulators to properly apply color changes.
        sleep 0.01
        Curses.init_color(color_id, *hex_to_curses_rgb(code))
        color_id
      else
        # Find closest match in fixed color palette
        least_error = nil
        least_error_id = nil
        @color_code.each_index do |color_id|
          error = ((@color_code[color_id][0..1].hex - code[0..1].hex)**2) +
                  ((@color_code[color_id][2..3].hex - code[2..3].hex)**2) +
                  ((@color_code[color_id][4..6].hex - code[4..6].hex)**2)
          if least_error.nil? || (error < least_error)
            least_error = error
            least_error_id = color_id
          end
        end
        @color_id_lookup[code] = least_error_id
        least_error_id
      end
    end

    # Get or allocate a curses color pair ID for a foreground/background combination.
    # Caches pair IDs to avoid redundant Curses.init_pair calls. When every pair
    # in the pool is in use, the least recently allocated pair is recycled
    # (its old fg/bg mapping is evicted and it is re-initialized).
    #
    # Codes come from user settings XML and server/script +<color>+ tags, so
    # they are normalized first: a leading "#" is stripped, and anything that
    # is not 6 hex digits (e.g. "", "f00") falls back to the default color.
    #
    # @param fg_code [String, nil] foreground hex color code, or nil for default
    # @param bg_code [String, nil] background hex color code, or nil for default
    # @return [Integer] curses color pair ID, always below {MAX_RENDERABLE_COLOR_PAIRS}
    def get_color_pair_id(fg_code, bg_code)
      fg_code = normalize_color_code(fg_code)
      bg_code = normalize_color_code(bg_code)
      fg_id = fg_code.nil? ? @default_color_id : get_color_id(fg_code)
      bg_id = bg_code.nil? ? @default_background_color_id : get_color_id(bg_code)

      if @color_pair_id_lookup[fg_id] && (color_pair_id = @color_pair_id_lookup[fg_id][bg_id])
        color_pair_id
      else
        @color_mutex.synchronize do
          color_pair_id = @color_pair_history.shift
          @color_pair_id_lookup.each { |_w, x| x.delete_if { |_y, z| z == color_pair_id } }
          @color_pair_id_lookup[fg_id] ||= {}
          @color_pair_id_lookup[fg_id][bg_id] = color_pair_id
          @color_pair_history.push(color_pair_id)
        end
        sleep 0.01
        Curses.init_pair(color_pair_id, fg_id, bg_id)
        color_pair_id
      end
    end

    private

    # Normalize a color code to 6 hex digits.
    #
    # @param code [String, nil] color code, optionally prefixed with "#"
    # @return [String, nil] the 6-digit hex code, or nil (default color) if
    #   +code+ is nil or not a 6-digit hex color
    def normalize_color_code(code)
      return nil if code.nil?
      return code if code.match?(/\A\h{6}\z/)

      code[/\A#(\h{6})\z/, 1]
    end

    # Convert curses RGB values (0-1000 range) to a 6-digit hex color code.
    # Each channel is zero-padded to two digits, so [1000, 0, 0] is "ff0000".
    #
    # @param rgb [Array<Integer>] [r, g, b] each in 0..1000
    # @return [String] 6-digit lowercase hex color code
    def curses_rgb_to_hex(rgb)
      format('%02x%02x%02x', *rgb.map { |num| ((num / 1000.0) * 255).round })
    end

    # Convert a 6-digit hex color code to curses RGB values (0-1000 range).
    #
    # @param code [String] 6-digit hex color code (e.g., "ff0000")
    # @return [Array<Integer>] [r, g, b] each in 0..1000
    def hex_to_curses_rgb(code)
      [code[0..1], code[2..3], code[4..5]].map { |c| ((c.hex / 255.0) * 1000).round }
    end
  end
end

# Global convenience method for compatibility with existing code.
#
# @param fg_code [String, nil] foreground hex color code, or nil for default
# @param bg_code [String, nil] background hex color code, or nil for default
# @return [Integer] curses color pair ID
def get_color_pair_id(fg_code, bg_code)
  ColorManager.get_color_pair_id(fg_code, bg_code)
end
