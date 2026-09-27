# frozen_string_literal: true

# key_codes.rb: Key name to curses key code mappings for ProfanityFE.

# Builds the key name to curses key code table (KEY_NAME) used by the
# settings file's <key id="..."> bindings.
#
# Codes up to KEY_MAX are ncurses' standard key codes and are the same
# everywhere. Codes for modified keys (ctrl/alt/shift with arrows, home,
# end, page up/down, insert, delete) are not: ncurses numbers them at run
# time from the terminal's terminfo extended key capabilities, so they
# differ between ncurses builds and terminfo databases. Those codes are
# read from ncurses (+Curses.keyname+) once curses is up; the codes in
# FALLBACK are used only where ncurses names nothing.
module KeyCodes
  # ncurses KEY_MAX (0777): the highest standard key code.
  STANDARD_KEY_MAX = 0o777

  # Codes to ask ncurses about, from KEY_MIN. ncurses numbers extended keys
  # from about KEY_MAX up; the upper bound leaves room for any terminfo entry.
  SCAN_RANGE = (0o401..(STANDARD_KEY_MAX + 1024))

  # terminfo extended key capability stem => binding key name.
  KEYS = {
    'DC'  => 'delete',
    'IC'  => 'insert',
    'UP'  => 'up',
    'DN'  => 'down',
    'LFT' => 'left',
    'RIT' => 'right',
    'HOM' => 'home',
    'END' => 'end',
    'NXT' => 'page_down',
    'PRV' => 'page_up'
  }.freeze

  # xterm modifier parameter (the capability's digit suffix) => binding
  # modifier prefix.
  MODIFIERS = {
    '2' => 'shift',
    '3' => 'alt',
    '4' => 'alt+shift',
    '5' => 'ctrl',
    '6' => 'ctrl+shift',
    '7' => 'ctrl+alt',
    '8' => 'ctrl+alt+shift'
  }.freeze

  # An extended key capability name as returned by +Curses.keyname+,
  # e.g. "kLFT5" (ctrl+left) or "kNXT3" (alt+page_down).
  EXTENDED_NAME = /\Ak(#{KEYS.keys.join('|')})([2-8])\z/

  # Read the modified-key codes from ncurses.
  #
  # @param keyname [#call] returns the ncurses name of a key code, or nil
  # @return [Hash{String => Integer}] binding name => key code
  def self.extended_key_names(keyname)
    SCAN_RANGE.each_with_object({}) do |code, names|
      match = EXTENDED_NAME.match(keyname.call(code))
      next unless match

      names["#{MODIFIERS[match[2]]}+#{KEYS[match[1]]}"] ||= code
    end
  end

  # Build the key name table: FALLBACK, with the modified-key codes that
  # ncurses names put in place of the fallback ones.
  #
  # A fallback extended code is dropped when ncurses gives its name a code
  # or gives its code another name, since the fallback number then means a
  # different key on this terminal. Standard codes are never replaced.
  #
  # @param keyname [#call, nil] returns the ncurses name of a key code, or
  #   nil; with no keyname the table is FALLBACK
  # @return [Hash{String => Integer, Array}] binding name => key code (or
  #   key sequence)
  def self.key_names(keyname = default_keyname)
    derived = keyname ? extended_key_names(keyname) : {}
    claimed = derived.values
    kept = FALLBACK.reject do |name, code|
      code.is_a?(Integer) && code > STANDARD_KEY_MAX && (derived.key?(name) || claimed.include?(code))
    end
    kept.merge(derived.reject { |name, _code| kept.key?(name) })
  end

  # +Curses.keyname+, when the curses in use provides it. ncurses names
  # extended key codes only once curses is started and keypad mode is on.
  #
  # @return [Method, nil]
  def self.default_keyname
    Curses.method(:keyname) if defined?(Curses) && Curses.respond_to?(:keyname)
  end
end

# Key codes used where ncurses names nothing. The modified-key codes above
# KeyCodes::STANDARD_KEY_MAX are from one ncurses build and terminfo.
KeyCodes::FALLBACK = {
  'ctrl+a'        => 1,
  'ctrl+b'        => 2,
  #	'ctrl+c'    => 3,
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
  #	'ctrl+q'    => 17,
  'ctrl+r'        => 18,
  #	'ctrl+s'    => 19,
  'ctrl+t'        => 20,
  'ctrl+u'        => 21,
  'ctrl+v'        => 22,
  'ctrl+w'        => 23,
  'ctrl+x'        => 24,
  'ctrl+y'        => 25,
  #	'ctrl+z'    => 26,
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
  'win_end'       => 358,
  'end'           => 360,
  'resize'        => 410,
  'num_7'         => 449,
  'num_8'         => 450,
  'num_9'         => 451,
  'num_4'         => 452,
  'num_5'         => 453,
  'num_6'         => 454,
  'num_1'         => 455,
  'num_2'         => 456,
  'num_3'         => 457,
  'num_enter'     => 459,
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
  'shift+down'    => 336,
  'shift+up'      => 337,
  'shift+delete'  => 383,
  'shift+end'     => 386,
  'shift+home'    => 391,
  'shift+insert'  => 392,
  'shift+left'    => 393,
  'shift+right'   => 402,
  'ctrl+up'       => 560,
  # Alt+number for tab switching: the terminal sends ESC then the digit.
  # Curses getch returns a printable key as a one-character String, not its
  # Integer code, so the digit must be a String here to ever match.
  'alt+1'         => [27, '1'],
  'alt+2'         => [27, '2'],
  'alt+3'         => [27, '3'],
  'alt+4'         => [27, '4'],
  'alt+5'         => [27, '5']
}.freeze

# Key name => curses key code (or key sequence) for <key> bindings. Built
# when this file is loaded, so load it after curses_setup has started curses.
KEY_NAME = KeyCodes.key_names.freeze
