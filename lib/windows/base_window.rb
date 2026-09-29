# frozen_string_literal: true

require_relative '../styled_text'
require_relative '../anchored_selection'
require_relative '../window_layout'

# Base class for all ProfanityFE window types.
# Provides shared rendering, the null mouse protocol, and the window registry.

# Base class for all ProfanityFE windows.
#
# Provides shared rendering ({#add_line}), the mouse protocol every window
# answers ({#selection_anchor_at}, {#clear_highlight}, {#link_cmd_at}; no-ops
# here), and a window class registry used for hit-testing
# ({.find_window_at}). Windows that take routed stream text include
# {StreamWindow}; windows that show a scrollable line buffer, with a
# scrollbar and selection, include {LineBuffered}.
class BaseWindow < Curses::Window
  # @return [WindowLayout, nil] where the layout file puts this window;
  #   set by {WindowManager#load_layout} and used to place the window
  #   again when the terminal is resized
  attr_accessor :layout

  # Create a new window and register it in the class instance list.
  #
  # @param args [Array] arguments forwarded to +Curses::Window.new+
  def initialize(*args)
    @layout = nil
    super(*args)
    self.class.register_instance(self)
  end

  # Render a single line with color regions via {HighlightProcessor}.
  #
  # @param line [String] the text to render
  # @param line_colors [Array<Hash>] color region descriptors
  # @param options [Hash] additional rendering options forwarded to the processor
  # @return [void]
  def add_line(line, line_colors = [], options = {})
    HighlightProcessor.render_colored_text(self, line, line_colors, options)
  end

  # Draw the window's contents again from what it holds (its buffer,
  # skills, spells, room, label or value). This is the repaint every
  # window class answers; call it rather than +redraw+ on a window of
  # unknown class. Most classes' +redraw+ means the same, but a text
  # window (or a countdown) has none of its own, so +redraw+ there is
  # +Curses::Window#redraw+: it only marks the window for a full
  # terminal refresh and repaints nothing from the buffer.
  #
  # Default: nothing, for a window drawn only as its state changes: a
  # countdown draws itself on every {CountdownWindow#tick} that changes
  # what it shows.
  #
  # @return [void]
  def repaint; end

  # All live instances of this window subclass.
  #
  # @return [Array<BaseWindow>]
  def self.list
    @list ||= []
  end

  # Register a window instance in this class's instance list.
  #
  # @param instance [BaseWindow] the window to register
  # @return [void]
  def self.register_instance(instance)
    list.push(instance)
  end

  # Remove a window instance from this class's instance list.
  #
  # @param instance [BaseWindow] the window to unregister
  # @return [void]
  def self.unregister_instance(instance)
    list.delete(instance)
  end

  # Format a timestamp string for the current time (HH:MM).
  #
  # @return [String] formatted timestamp like " [14:35]"
  # @api private
  def format_timestamp
    " [#{Time.now.hour.to_s.rjust(2, '0')}:#{Time.now.min.to_s.rjust(2, '0')}]"
  end

  # Text to store in a line buffer for an added string. A trailing newline
  # is dropped (the startup blank fill adds "\n"): drawing it would move
  # the cursor down a second row, and each buffer line owns exactly one
  # row. Blank text stays blank and gets no timestamp.
  #
  # @param string [String, nil] the text being added
  # @param time_stamp [Boolean] whether to append a timestamp
  # @return [String]
  # @api private
  def buffer_text(string, time_stamp)
    text = string.to_s.chomp
    time_stamp && !text.empty? ? text + format_timestamp : text
  end

  # --- Mouse protocol (called on whatever window is under the pointer) ---

  # Resolve window-relative coordinates to a stable selection anchor.
  # {BaseWindow.find_window_at} can return any window, and
  # {SelectionManager} asks it for an anchor on every press. Default: nil,
  # for window types that have nothing to select. A window that returns an
  # anchor must also take the rest of the selection calls
  # (+highlight_selection+, +extract_selection+, +drag_auto_scroll+,
  # +buffer_content+, +lines_appended+); {LineBuffered} does.
  #
  # @param _rel_y [Integer] row relative to window top
  # @param _rel_x [Integer] column relative to window left
  # @return [Array<Integer>, nil] [line_id, x] anchor, or nil
  def selection_anchor_at(_rel_y, _rel_x)
    nil
  end

  # Clear any selection highlight. {SelectionManager} calls this on the
  # last window pressed, whatever its type. Default: nothing to clear.
  #
  # @return [void]
  def clear_highlight; end

  # Find a clickable link command at the given window-relative coordinates.
  # Subclasses override this with buffer-aware implementations.
  #
  # @param _rel_y [Integer] row relative to window top
  # @param _rel_x [Integer] column relative to window left
  # @return [String, nil] the link command string, or nil if no link at that position
  def link_cmd_at(_rel_y, _rel_x)
    nil
  end

  # Render text at the current cursor position using indexed fg/bg color arrays.
  #
  # @param text [String] text to render
  # @param fg_code [String, nil] foreground hex color code
  # @param bg_code [String, nil] background hex color code
  # @return [void]
  protected def render_colored(text, fg_code, bg_code)
    attron(Curses.color_pair(get_color_pair_id(fg_code, bg_code)) | Curses::A_NORMAL) do
      addstr text
    end
  end

  # --- Window type registry (OCP: new types register themselves) ---

  # Registry mapping XML class names to window builder procs.
  # Each builder proc receives (height, width, top, left, element, window_manager)
  # and returns a configured window (or nil). {WindowManager#load_layout}
  # sets the +layout+ of a returned BaseWindow; builders need not.
  #
  # @return [Hash<String, Proc>]
  def self.type_registry
    @type_registry ||= {}
  end

  # Register a window type by its XML class name.
  #
  # @param xml_class [String] the value of class='...' in layout XML
  # @yield [height, width, top, left, element, wm] builder block
  # @yieldparam height [Integer] computed window height
  # @yieldparam width [Integer] computed window width
  # @yieldparam top [Integer] computed top position
  # @yieldparam left [Integer] computed left position
  # @yieldparam element [REXML::Element] the XML element for this window
  # @yieldparam wm [WindowManager] the window manager instance
  # @return [void]
  def self.register_type(xml_class, &builder)
    type_registry[xml_class] = builder
  end

  # Parse fg/bg color attributes from an XML layout element.
  # Splits a comma-separated attribute value into an array, converting
  # the string 'nil' to actual nil.
  #
  # @param element [REXML::Element] XML element containing the attribute
  # @param attr_name [String] attribute name to parse (e.g. 'fg', 'bg')
  # @return [Array<String, nil>, nil] parsed color values, or nil if attribute absent
  def self.parse_color_attrs(element, attr_name)
    return unless element.attributes[attr_name]

    element.attributes[attr_name].split(',').collect do |val|
      val == 'nil' ? nil : val
    end
  end

  # Attribute values that turn a layout flag off (compared case-insensitively,
  # ignoring surrounding whitespace).
  FALSE_FLAG_VALUES = %w[false no 0 off].freeze

  # Parse an on/off attribute from an XML layout element. An absent attribute
  # is off, and so are 'false', 'no', '0' and 'off' in any case. Any other
  # value is on, as every value was before the attribute was parsed.
  #
  # @param element [REXML::Element] XML element containing the attribute
  # @param attr_name [String] attribute name to parse (e.g. 'timestamp')
  # @return [Boolean]
  def self.parse_flag_attr(element, attr_name)
    value = element.attributes[attr_name]
    !value.nil? && !FALSE_FLAG_VALUES.include?(value.strip.downcase)
  end

  # --- Window class registry ---

  # All registered window subclasses.
  #
  # @return [Array<Class>]
  def self.window_classes
    @window_classes ||= []
  end

  # Register a window subclass in the global registry.
  #
  # @param klass [Class] the subclass to register
  # @return [void]
  def self.register_window_class(klass)
    window_classes << klass unless window_classes.include?(klass)
  end

  # Every live window of every registered window class.
  #
  # @return [Array<BaseWindow>] a new array, safe to iterate while windows
  #   are removed from their class lists
  def self.all_windows
    BaseWindow.window_classes.flat_map(&:list)
  end

  # Hook called when a subclass is defined, including subclasses of
  # subclasses. Initializes the subclass instance list and registers it in
  # the {BaseWindow.window_classes} registry.
  #
  # @param subclass [Class] the newly defined subclass
  # @return [void]
  def self.inherited(subclass)
    super
    subclass.instance_variable_set(:@list, [])
    BaseWindow.register_window_class(subclass)
  end

  # --- Resizing (driven by WindowManager#resize, per registered class) ---

  # Columns of the layout's width the window leaves unused at its right
  # edge, both when it is built and when it is resized. Default: none.
  #
  # @return [Integer]
  def self.right_margin
    0
  end

  # Where this class comes when {WindowManager#resize} goes through the
  # window classes: lower comes first, and classes with the same value go
  # in the order they were defined. Windows that overlap show the one
  # resized last. The built-in classes keep the order resize has always
  # used; a class that doesn't choose comes after them.
  #
  # @return [Integer]
  def self.resize_order
    100
  end

  # Every registered window class, in the order {WindowManager#resize}
  # resizes them (see {.resize_order}).
  #
  # @return [Array<Class>]
  def self.window_classes_in_resize_order
    window_classes.each_with_index.sort_by { |klass, index| [klass.resize_order, index] }.map(&:first)
  end

  # Fit every live window of this class to the current terminal size:
  # move each to its layout and, if it moved, redraw it.
  #
  # @return [void]
  def self.resize_all
    list.to_a.each do |window|
      window.redraw_after_resize if window.move_to_layout
    end
  end

  # Size and place the window where its layout puts it on the current
  # terminal, leaving the class's {.right_margin} unused.
  #
  # @return [Boolean] true if the window was moved, false if its layout
  #   puts it off the screen and it was left as it is
  # @api private
  def move_to_layout
    layout.place(self, right_margin: self.class.right_margin)
  end

  # Show the window again after {#move_to_layout} moved it. Default:
  # copy it to the screen as it is, without redrawing its contents.
  #
  # @return [void]
  # @api private
  def redraw_after_resize
    noutrefresh
  end

  # Find the window instance whose screen bounds contain the given coordinates.
  #
  # @param screen_y [Integer] absolute screen row
  # @param screen_x [Integer] absolute screen column
  # @return [BaseWindow, nil] the window at those coordinates, or nil
  def self.find_window_at(screen_y, screen_x)
    window_classes.each do |klass|
      next unless klass.respond_to?(:list)

      klass.list.each do |window|
        next unless window.respond_to?(:begy) && window.respond_to?(:maxy)

        if screen_y >= window.begy && screen_y < (window.begy + window.maxy) &&
           screen_x >= window.begx && screen_x < (window.begx + window.maxx)
          return window
        end
      end
    end
    nil
  end
end
