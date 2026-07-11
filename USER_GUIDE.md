# ProfanityFE User Guide

ProfanityFE is a curses-based terminal frontend for DragonRealms, a text-based
MUD. It connects to a local game proxy (such as Lich) and provides a
configurable multi-window interface with color highlighting, key bindings,
scrollable text buffers, progress bars, countdown timers, and more -- all
running inside a standard terminal emulator.

**Version:** 1.0.0

---

## Table of Contents

1. [Getting Started](#1-getting-started)
2. [Settings File](#2-settings-file)
3. [Layouts](#3-layouts)
4. [Key Bindings](#4-key-bindings)
5. [Highlights](#5-highlights)
6. [Gag Patterns](#6-gag-patterns)
7. [Dot-Commands](#7-dot-commands)
8. [Color System](#8-color-system)
9. [Window Scrolling](#9-window-scrolling)
10. [Tab Management](#10-tab-management)
11. [Stream Routing](#11-stream-routing)
12. [Link Display](#12-link-display)
13. [Mouse Scroll Wheel](#13-mouse-scroll-wheel)
14. [Autocomplete](#14-autocomplete)
15. [Process Title](#15-process-title)
16. [Tips and Troubleshooting](#16-tips-and-troubleshooting)
17. [Sample Login Script](#17-sample-login-script)

---

## 1. Getting Started

### Dependencies

- **Ruby** (3.0 or later recommended)
- **Bundler** -- install gems with `bundle install` (handles curses, rexml, rspec)
- A terminal emulator that supports at least 256 colors (iTerm2, kitty,
  gnome-terminal, etc.)
- A local game proxy (Lich or similar) listening on a TCP port

### Installation

```bash
git clone https://github.com/elanthia-online/ProfanityFE.git
cd ProfanityFE
bundle install
```

### Launching

Start ProfanityFE by pointing it at the port your game proxy is listening on:

```bash
ruby profanity.rb --port=8000 --char=Mahtra
```

ProfanityFE connects to `127.0.0.1` on the specified port.

### Command-Line Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--port=<port>` | `8000` | TCP port to connect to on localhost |
| `--char=<name>` | -- | Character name (for log file and process title) |
| `--config=<name>` | same as `--char` | Config name to load (use when multiple characters share one config) |
| `--template=<file>` | -- | Template filename from `templates/` subfolder |
| `--no-status` | off | Disable process title updates |
| `--links` | off | Enable in-game link highlighting |
| `--speech-ts` | off | Add timestamps to speech, familiar, and thought windows |
| `--room-window-only` | off | Do not echo room data to the story window (show only in room window) |
| `--remote-url` | off | Display LaunchURLs as text instead of opening browser (for SSH/remote sessions) |
| `--default-color-id=<id>` | `7` | Curses color ID for the default foreground color |
| `--default-background-color-id=<id>` | `0` | Curses color ID for the default background color |
| `--custom-colors=<on\|off\|yes\|no>` | auto-detected | Force custom color mode on or off |
| `--use-default-colors` | off | Call `Curses.use_default_colors` for transparent background support |
| `--log-file=<path>` | see below | Full path for the log file (overrides --log-dir and --char) |
| `--log-dir=<dir>` | see below | Directory for the log file |
| `--profile` | off | Log boot timing breakdown to the log file (for startup performance debugging) |
| `--help` / `-h` / `-?` | -- | Print usage and exit |

> **Note:** `--settings-file=<path>` is still supported as a hidden override
> that bypasses the normal config resolution order (see
> [Settings File](#2-settings-file)).

#### Examples

```bash
# Typical launch: connect on port 8000 as character Mahtra
ruby profanity.rb --port=8000 --char=Mahtra

# Connect on port 8010 with link highlighting enabled
ruby profanity.rb --port=8010 --char=Navesi --links

# Force custom colors off (use nearest-match from 256-color palette)
ruby profanity.rb --port=8000 --char=Mahtra --custom-colors=off

# Transparent background (if your terminal supports it)
ruby profanity.rb --port=8000 --char=Mahtra --use-default-colors --default-color-id=-1 --default-background-color-id=-1

# Remote/SSH session (display URLs as text instead of launching)
ruby profanity.rb --port=8000 --char=Mahtra --remote-url

# Log to a specific file (overrides --char default)
ruby profanity.rb --port=8000 --char=Mahtra --log-file=~/logs/mahtra.log

# Disable process title updates
ruby profanity.rb --port=8000 --char=Mahtra --no-status

# Multiple characters sharing one config (separate logs and process titles)
ruby profanity.rb --port=8000 --char=Mahtra                     # config: mahtra.xml, log: mahtra.log
ruby profanity.rb --port=8001 --char=Othchar --config=mahtra    # config: mahtra.xml, log: othchar.log
ruby profanity.rb --port=8002 --char=Thirdchar --config=mahtra  # config: mahtra.xml, log: thirdchar.log
```

---

## 2. Settings File

### Creating Your Settings File

ProfanityFE requires a settings XML file to run. **You must create this file
yourself** -- it is not generated automatically.

The `~/.profanity/` directory is created automatically on first run. This is
where your personal per-character configuration files live.

### Included Templates

The `templates/` subfolder contains example configurations you can use as
starting points. **Do not use them as-is** -- copy one and customize it for
your own character, terminal size, and preferences:

```bash
cp templates/mahtra.xml ~/.profanity/mychar.xml
```

Available templates:

| Template | Game | Description |
|----------|------|-------------|
| `default.xml` | DR | Full-featured DragonRealms layout with tabbed windows, room display, combat gags, and spell abbreviations. The recommended starting point for DR players. |
| `mahtra.xml` | DR | A real DR player's configuration — same as default.xml but serves as a named-character example. |
| `original.xml` | GS | Minimal GemStone IV baseline — simple 3-window layout with basic highlights. Good clean starting point for GS players. |
| `tysong.xml` | GS | GemStone IV 1080p template with character class highlighting (Empath, Wizard, Cleric, Ranger, Sorcerer name lists). |
| `eleazzar.xml` | GS | Advanced GemStone IV template requiring nerd fonts and effectmon.lic/targetlist.lic scripts. Three-column layout with buff/debuff panels. |

After copying, edit the file to suit your needs. At minimum you'll want to:
- Adjust the layout dimensions for your terminal size
- Customize highlight patterns for your character's guild and hunting areas
- Remove gag patterns for creatures you don't fight
- Add your own key bindings and macros

### Config Resolution Order

When you launch with `--char=<name>`, ProfanityFE searches for a settings file
in this order:

1. `~/.profanity/<charname>.xml` -- personal config (highest priority)
2. `templates/<charname>.xml` -- bundled with the app
3. `templates/default.xml` -- fallback

The first file found is used. This means you can start with a bundled template
and later override it by placing a customized copy in `~/.profanity/`.

The `--settings-file=<path>` flag still works as a direct override, bypassing
the resolution order entirely.

### Overall XML Structure

The settings file is a standard XML document. The root element is `<settings>`.
Inside it you place highlight rules, presets, key bindings, gag patterns,
perc-transforms, and one or more layouts.

A convenient pattern is to define XML entities at the top of the file for your
color palette so you can refer to colors by name throughout:

```xml
<!DOCTYPE highlight [
  <!ENTITY black   "000000">
  <!ENTITY red     "ff0000">
  <!ENTITY green   "00ff00">
  <!ENTITY yellow  "ffff00">
  <!ENTITY blue    "0000ff">
  <!ENTITY magenta "ff00ff">
  <!ENTITY cyan    "00ffff">
  <!ENTITY white   "ffffff">
  <!ENTITY grey    "808080">
  <!ENTITY orange  "ff8700">
]>

<settings>
  <!-- highlights, presets, keys, layouts, gags, perc-transforms go here -->
</settings>
```

### Hot-Reloading

Type `.reload` in the command line to hot-reload the settings file without
restarting. On reload, the following are refreshed:

- Highlights
- Key bindings
- Gag patterns (general and combat)
- Perc-transforms

Presets and layouts are **not** reloaded by `.reload` -- they are only read on
initial startup. To switch layouts at runtime, use `.layout <name>`.

---

## 3. Layouts

A layout defines the set of windows that appear on screen -- their positions,
sizes, and types. You can define multiple named layouts in your settings file
and switch between them at runtime.

### Defining a Layout

Each layout is wrapped in a `<layout>` element with a unique `id`. The layout
named `default` is loaded automatically at startup.

```xml
<layout id='default'>
  <!-- window definitions go here -->
</layout>

<layout id='combat'>
  <!-- an alternative layout optimized for combat -->
</layout>
```

Switch layouts at runtime with `.layout combat`.

### Layout Math Expressions

All positional and size attributes (`top`, `left`, `height`, `width`) accept
arithmetic expressions using two special tokens:

| Token | Meaning |
|-------|---------|
| `lines` | Current terminal height in rows |
| `cols` | Current terminal width in columns |

You can combine them with `+`, `-`, `*`, `/`, and parentheses:

| Expression | Meaning |
|------------|---------|
| `lines-2` | Two rows from the bottom |
| `cols/3` | One-third of terminal width |
| `(cols/3)*2` | Two-thirds of terminal width |
| `((cols/6)*5)+4` | Five-sixths of width plus 4 |

All expressions are evaluated as integers.

### Window Types

Every window inside a layout is a `<window>` element with a `class` attribute
that determines its type. The following subsections document every window class.

---

#### 3.1 Text Window (`class='text'`)

A scrollable text buffer window. This is the primary window type for displaying
game output. Text windows have a 1-column scrollbar on the right edge.

**Attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `class` | yes | Must be `'text'` |
| `top` | yes | Top row position (expression) |
| `left` | yes | Left column position (expression) |
| `height` | yes | Height in rows (expression) |
| `width` | yes | Width in columns (expression); 1 column is reserved for the scrollbar |
| `value` | yes | Comma-separated list of stream names to display in this window |
| `buffer-size` | no | Maximum lines retained in the scroll buffer (default: `1000`) |
| `timestamp` | no | Set to `'true'` to append `[HH:MM]` timestamps to each line |

**Examples:**

```xml
<!-- Main game output window, top-left, taking 2/3 of the screen -->
<window class='text' top='0' left='0'
        height='lines-3' width='(cols/3)*2'
        value='main' buffer-size='1000'/>

<!-- Combat window in the upper right -->
<window class='text' top='0' left='((cols/3)*2)+1'
        height='20' width='cols/3'
        value='combat,assess' buffer-size='100'/>

<!-- Chat window with timestamps -->
<window class='text' top='20' left='((cols/3)*2)+1'
        height='10' width='cols/3'
        value='lnet,thoughts,voln' buffer-size='500' timestamp='true'/>
```

Multiple streams can be routed to the same text window by listing them in the
`value` attribute separated by commas. The stream names correspond to game
protocol stream IDs (see [Stream Routing](#11-stream-routing)).

---

#### 3.2 Tabbed Text Window (`class='tabbed'`)

A multi-tab text window. Multiple named text buffers share one display area.
A tab bar at the top shows all tabs, with an asterisk (`*`) marking background
tabs that have received new content since you last viewed them.

**Attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `class` | yes | Must be `'tabbed'` |
| `top` | yes | Top row position (expression) |
| `left` | yes | Left column position (expression) |
| `height` | yes | Height in rows (expression); 1 row is reserved for the tab bar |
| `width` | yes | Width in columns (expression); 1 column reserved for scrollbar |
| `tabs` or `value` | yes | Comma-separated list of tab names (and stream names to route) |
| `buffer-size` | no | Maximum lines per tab buffer (default: `1000`) |
| `timestamp` | no | Set to `'true'` to append timestamps |

Each tab name listed in `tabs` (or `value`) becomes both a tab and a stream
routing target. The first tab listed becomes the initially active tab.

**Example:**

```xml
<!-- A tabbed window with main game, combat, and chat tabs -->
<window class='tabbed' top='0' left='0'
        height='lines-3' width='(cols/3)*2'
        tabs='main,combat,thoughts' buffer-size='1000'/>
```

With this configuration:
- Game text for the `main` stream goes to the "main" tab
- Combat text goes to the "combat" tab
- Thoughts/chat goes to the "thoughts" tab
- The tab bar at the top displays: ` 1:main | 2:combat | 3:thoughts `
- Background tabs with unread content show: ` 2:combat* `

See [Tab Management](#10-tab-management) for how to switch tabs.

---

#### 3.3 Indicator Window (`class='indicator'`)

A small single-line status indicator. The label text changes color based on
a boolean or integer state value. Used for compass directions, hand contents,
spell prepared, stunned/bleeding status, and more.

**Attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `class` | yes | Must be `'indicator'` |
| `top` | yes | Top row position |
| `left` | yes | Left column position |
| `height` | yes | Height (typically `1`) |
| `width` | yes | Width in columns |
| `value` | depends | The indicator data source (see table below) |
| `label` | no | Static label text to display (default: `'*'`) |
| `fg` | no | Comma-separated foreground colors for each state (default: `'444444,ffff00'`) |
| `bg` | no | Comma-separated background colors for each state (use `nil` for transparent) |

The `fg` and `bg` arrays are indexed by state. For boolean indicators, index 0
is the "off" state and index 1 is the "on" state. For integer indicators (like
injury levels), each index corresponds to the severity level.

**Valid `value` names for indicators:**

| Value | What it shows |
|-------|---------------|
| `stunned` | Whether you are stunned |
| `bleeding` | Whether you are bleeding |
| `kneeling` | Whether you are kneeling |
| `prone` | Whether you are prone |
| `sitting` | Whether you are sitting |
| `hidden` | Whether you are hidden |
| `dead` | Whether you are dead |
| `joined` | Whether you are in a group |
| `webbed` | Whether you are webbed |
| `left` | Item in your left hand |
| `right` | Item in your right hand |
| `spell` | Currently prepared spell |
| `prompt` | The game prompt (e.g., `H>`) |
| `compass:n` | North exit available (also: `ne`, `e`, `se`, `s`, `sw`, `w`, `nw`, `up`, `down`, `out`) |
| `nsys` | Nerve damage level (integer 0-3) |
| `head`, `neck`, `chest`, `abdomen`, `back`, `leftArm`, `rightArm`, `leftLeg`, `rightLeg`, `leftEye`, `rightEye`, `leftHand` | Body part injury level (integer 0-6) |
| `room players` | Names of other players in the room |

**Examples:**

```xml
<!-- Stun indicator -->
<window class='indicator' top='lines-1' left='0'
        height='1' width='4'
        label='STUN' value='stunned'
        fg='000000,ffff00'/>

<!-- Bleeding indicator with red background when active -->
<window class='indicator' top='lines-1' left='5'
        height='1' width='3'
        label='BLD' value='bleeding'
        fg='000000,ff0000' bg='nil,ff0000'/>

<!-- Left hand contents -->
<window class='indicator' top='lines-1' left='10'
        height='1' width='20'
        label=' ' value='left'
        fg='ffffff,ff00ff'/>

<!-- Right hand contents -->
<window class='indicator' top='lines-1' left='32'
        height='1' width='20'
        label=' ' value='right'
        fg='ffffff,ff00ff'/>

<!-- Prepared spell -->
<window class='indicator' top='lines-1' left='54'
        height='1' width='25'
        label=' ' value='spell'
        fg='ffffff,ff00ff'/>

<!-- Compass direction (north) -->
<window class='indicator' top='lines-1' left='80'
        height='1' width='2'
        label='N' value='compass:n'
        fg='444444,00ff00'/>

<!-- Room players indicator -->
<window class='indicator' top='lines-3' left='0'
        height='1' width='cols/2'
        label=' ' value='room players'
        fg='808080,00ffff'/>

<!-- Nerve damage indicator (multi-level: 0=none, 1=slurred, 2=spasms, 3=severe) -->
<window class='indicator' top='lines-1' left='90'
        height='1' width='4'
        label='NSYS' value='nsys'
        fg='444444,ffff00,ff8700,ff0000'/>

<!-- Prompt indicator (dynamic label) -->
<window class='indicator' top='lines-2' left='0'
        height='1' width='3'
        label='>' value='prompt'
        fg='ffffff'/>
```

---

#### 3.4 Progress Window (`class='progress'`)

A single-row progress bar for health, mana, stamina, concentration, spirit,
stance, and mind state. The filled portion is proportional to the current
value.

**Attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `class` | yes | Must be `'progress'` |
| `top` | yes | Top row position |
| `left` | yes | Left column position |
| `height` | yes | Height (typically `1`) |
| `width` | yes | Width in columns |
| `value` | yes | The progress data source (see table below) |
| `label` | no | Text label at the left of the bar (default: empty) |
| `fg` | no | Comma-separated foreground colors for bar regions |
| `bg` | no | Comma-separated background colors for bar regions |

**Color array positions:**

| Index | Region |
|-------|--------|
| 0 | Filled (left) portion of the bar |
| 1 | Middle transition cell |
| 2 | Unfilled (right) portion of the bar |
| 3 | Color when value is zero |

**Valid `value` names for progress bars:**

| Value | What it tracks |
|-------|----------------|
| `health` | Health percentage |
| `mana` | Mana percentage |
| `stamina` | Stamina percentage |
| `concentration` | Concentration percentage |
| `spirit` | Spirit percentage |
| `stance` | Stance percentage (0-100) |
| `mind` | Mind state (overall learning, 0-110, where 110 = saturated) |

**Examples:**

```xml
<!-- Health bar: red fill, dark background -->
<window class='progress' top='lines-1' left='0'
        height='1' width='8'
        label='HP' value='health'
        fg='ff0000,ff0000,ff0000' bg='000000'/>

<!-- Mana bar: blue fill -->
<window class='progress' top='lines-1' left='9'
        height='1' width='8'
        label='MP' value='mana'
        fg='0000ff,0000ff,0000ff' bg='000000'/>

<!-- Stamina bar: white fill -->
<window class='progress' top='lines-1' left='18'
        height='1' width='8'
        label='ST' value='stamina'
        fg='ffffff,ffffff,ffffff' bg='000000'/>

<!-- Concentration bar: green fill -->
<window class='progress' top='lines-1' left='27'
        height='1' width='8'
        label='CN' value='concentration'
        fg='00ff00,00ff00,00ff00' bg='000000'/>

<!-- Spirit bar: cyan fill -->
<window class='progress' top='lines-1' left='36'
        height='1' width='8'
        label='SP' value='spirit'
        fg='00ffff,00ffff,00ffff' bg='000000'/>

<!-- Stance bar with label and transition color -->
<window class='progress' top='lines-1' left='45'
        height='1' width='10'
        label='Stance:' value='stance'
        fg='00ff00,ffff00,ff0000' bg='004400,444400,440000'/>

<!-- Mind state bar (saturated at 110) -->
<window class='progress' top='lines-1' left='56'
        height='1' width='8'
        label='Mind' value='mind'
        fg='ffffff,ffffff,ffffff,ff0000' bg='0000aa,000055,000000,440000'/>
```

**Arbitrary Progress Bars (`arbProgress`):**

Scripts can create custom progress bars by sending `arbProgress` XML to the
game stream. These bars reuse existing progress windows by matching the `id`
attribute. Labels and colors can be overridden dynamically per update.

```xml
<arbProgress id='spellactive' max='250' current='160' label='WaterWalking' colors='1589FF,000000'</arbProgress>
```

| Attribute | Required | Description |
|-----------|----------|-------------|
| `id` | yes | Matches a `value` on a `progress` window |
| `max` | yes | Maximum value for the bar |
| `current` | yes | Current value (clamped to max) |
| `label` | no | Override the bar's label text |
| `colors` | no | Override colors as `bg,fg` (hex, comma-separated) |

To use an arbitrary progress bar, define a progress window with a matching
`value` in your template:

```xml
<window class='progress' top='5' left='0' height='1' width='20'
        value='spellactive' label='Spell' fg='1589ff' bg='000000'/>
```

---

#### 3.5 Countdown Window (`class='countdown'`)

Displays a countdown timer for roundtime, casttime, and stun duration. The bar
shrinks as the timer ticks down. Casttime is shown as a secondary overlay
(different color) on the roundtime bar.

**Attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `class` | yes | Must be `'countdown'` |
| `top` | yes | Top row position |
| `left` | yes | Left column position |
| `height` | yes | Height (typically `1`) |
| `width` | yes | Width in columns |
| `value` | yes | The countdown source (see table below) |
| `label` | no | Text label at the left of the bar (default: empty) |
| `fg` | no | Comma-separated foreground colors for bar regions |
| `bg` | no | Comma-separated background colors for bar regions |

**Color array positions:**

| Index | Region |
|-------|--------|
| 0 | Idle state (no active countdown) |
| 1 | Primary countdown fill (roundtime / stun) |
| 2 | Secondary countdown fill (casttime) |
| 3 | Background (remaining unfilled portion) |

**Valid `value` names:**

| Value | What it tracks |
|-------|----------------|
| `roundtime` | Roundtime and casttime timers (combined) |
| `stunned` | Stun duration countdown |

**Examples:**

```xml
<!-- Roundtime/casttime countdown bar -->
<window class='countdown' top='lines-1' left='0'
        height='1' width='10'
        label='RT:' value='roundtime'
        fg='ffffff,ffffff,ffffff,ffffff'
        bg='nil,0000ff,ffff00,nil'/>

<!-- Stun countdown -->
<window class='countdown' top='lines-1' left='12'
        height='1' width='8'
        label='Stun:' value='stunned'
        fg='ffffff,ffffff,ffffff,ffffff'
        bg='nil,ff0000,ff8700,nil'/>
```

When the roundtime timer is active, the bar fills from left to right with the
primary color (bg index 1). If a casttime is also running, the portion beyond
the roundtime uses the secondary color (bg index 2). When both timers reach
zero, the bar shows the idle color (index 0).

---

#### 3.6 Room Window (`class='room'`)

A dedicated window for room information: title, description, objects (with
creature highlighting), players, exits, room number, and string procs. The
room window assembles data from the game's room-related XML streams and
renders a complete room view.

By default, room data is echoed to both the room window and the story window.
Pass `--room-window-only` to suppress room data from the story window.

**Attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `class` | yes | Must be `'room'` |
| `top` | yes | Top row position |
| `left` | yes | Left column position |
| `height` | yes | Height in rows |
| `width` | yes | Width in columns |
| `title-preset` | no | Preset color for the room title (default: `'roomName'`) |
| `desc-preset` | no | Preset color for the room description |
| `creatures-preset` | no | Preset color for creature names in objects (default: `'monsterbold'`) |

To use a room window, you must also define the referenced presets. The room
title is shown in brackets, creatures in the objects list are highlighted with
the creatures preset, and exits ending with a bare colon get " none." appended.

**Example:**

```xml
<!-- Define the presets the room window references -->
<preset id='roomName' fg='00ff00'/>
<preset id='monsterbold' fg='ffff00'/>

<!-- Room window in the upper right -->
<window class='room' top='0' left='(cols/3)*2'
        height='12' width='cols/3'
        title-preset='roomName'
        desc-preset='roomDesc'
        creatures-preset='monsterbold'/>
```

---

#### 3.7 Experience Window (`class='exp'`)

Displays your skills with their ranks, percentages, and mindstates in a sorted
list. Highlight rules apply to the skill display, so you can color-code skills
by mindstate level.

**Attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `class` | yes | Must be `'exp'` |
| `top` | yes | Top row position |
| `left` | yes | Left column position |
| `height` | yes | Height in rows |
| `width` | yes | Width in columns (1 column reserved for padding) |

The `value` attribute is not needed -- the window is automatically wired to the
`exp` stream.

**Example:**

```xml
<window class='exp' top='0' left='(cols/3)*2'
        height='lines-5' width='cols/3'/>
```

Each skill is displayed in the format: `  Skill Name:  1234 56%  [12/34]`

---

#### 3.8 Perc Window (`class='percWindow'`)

Displays your active spells and effects, sorted by remaining duration (longest
first). Spell names are automatically abbreviated using a built-in lookup table
to fit narrow windows.

**Attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `class` | yes | Must be `'percWindow'` |
| `top` | yes | Top row position |
| `left` | yes | Left column position |
| `height` | yes | Height in rows |
| `width` | yes | Width in columns (1 column reserved for padding) |

The window is automatically wired to the `percWindow` stream.

**Example:**

```xml
<!-- Active spells sidebar -->
<window class='percWindow' top='0' left='((cols/6)*5)+4'
        height='17' width='cols/6'/>
```

Spells are sorted by a duration weight:
- Percentage-based effects (e.g., `50%`): weight 3000 (shown first)
- `OM` (Osrel Meraud) effects: weight 2000
- Cyclic spells: weight 1500
- Duration spells: sorted by remaining roisaen
- `Fading` effects: weight 0 (shown last)

---

#### 3.9 Command Window (`class='command'`)

The single-line input area where you type commands. There must be exactly one
command window in each layout.

**Attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `class` | yes | Must be `'command'` |
| `top` | yes | Top row position |
| `left` | yes | Left column position |
| `height` | yes | Height (typically `1`) |
| `width` | yes | Width in columns |

**Example:**

```xml
<!-- Command input at the bottom of the screen -->
<window class='command' top='lines-2' left='1'
        height='1' width='(cols/3)*2'/>
```

The command buffer supports horizontal scrolling when your input exceeds the
window width. It also supports command history (up/down arrows), word-level
cursor movement, and a kill ring (cut/paste).

---

#### 3.10 Sink Window (`class='sink'`)

A null window that silently discards all content routed to it. Use this to hide
game streams you do not want to see without creating a visible window.

**Attributes:**

| Attribute | Required | Description |
|-----------|----------|-------------|
| `class` | yes | Must be `'sink'` |
| `value` | yes | Comma-separated list of stream names to discard |

Sink windows do **not** need `top`, `left`, `height`, or `width` attributes --
they are invisible.

**Examples:**

```xml
<!-- Discard atmospheric messages -->
<window class='sink' value='atmospherics'/>

<!-- Discard both combat and assess streams -->
<window class='sink' value='combat,assess'/>
```

---

#### 3.11 Complete Layout Example

Here is a full working layout that demonstrates all window types:

```xml
<layout id='default'>
  <!-- Main game text (left 2/3 of screen) -->
  <window class='text' top='0' left='0'
          height='lines-3' width='(cols/3)*2'
          value='main' buffer-size='1000'/>

  <!-- Combat text (upper right) -->
  <window class='text' top='0' left='((cols/3)*2)+1'
          height='15' width='cols/3'
          value='combat,assess' buffer-size='100'/>

  <!-- Chat with timestamps (mid right) -->
  <window class='text' top='15' left='((cols/3)*2)+1'
          height='8' width='cols/3'
          value='lnet,thoughts,voln' buffer-size='500' timestamp='true'/>

  <!-- Active spells (lower right) -->
  <window class='percWindow' top='23' left='((cols/3)*2)+1'
          height='10' width='cols/3'/>

  <!-- Experience (bottom right) -->
  <window class='exp' top='33' left='((cols/3)*2)+1'
          height='lines-36' width='cols/3'/>

  <!-- Room players indicator -->
  <window class='indicator' top='lines-3' left='0'
          height='1' width='(cols/3)*2'
          label=' ' value='room players' fg='808080,00ffff'/>

  <!-- Command input -->
  <window class='command' top='lines-2' left='1'
          height='1' width='(cols/3)*2'/>

  <!-- Prompt indicator -->
  <window class='indicator' top='lines-2' left='0'
          height='1' width='1' label='>' fg='ffffff'/>

  <!-- Roundtime countdown -->
  <window class='countdown' top='lines-1' left='0'
          height='1' width='10' label=''
          value='roundtime'
          fg='ffffff,ffffff,ffffff,ffffff' bg='nil,0000ff,ffff00,nil'/>

  <!-- Hand indicators -->
  <window class='indicator' top='lines-1' left='12' height='1' width='2'
          label='L:' fg='0000ff'/>
  <window class='indicator' top='lines-1' left='14' height='1' width='20'
          label=' ' value='left' fg='ffffff,ff00ff'/>
  <window class='indicator' top='lines-1' left='36' height='1' width='2'
          label='R:' fg='0000ff'/>
  <window class='indicator' top='lines-1' left='38' height='1' width='20'
          label=' ' value='right' fg='ffffff,ff00ff'/>

  <!-- Status indicators -->
  <window class='indicator' top='lines-1' left='60' height='1' width='4'
          label='STUN' value='stunned' fg='000000,ffff00'/>
  <window class='indicator' top='lines-1' left='65' height='1' width='3'
          label='BLD' value='bleeding' fg='000000,ff0000'/>

  <!-- Progress bars -->
  <window class='progress' top='lines-1' left='70' height='1' width='5'
          label='' value='health'
          fg='ff0000,ff0000,ff0000' bg='000000'/>
  <window class='progress' top='lines-1' left='76' height='1' width='5'
          label='' value='mana'
          fg='0000ff,0000ff,0000ff' bg='000000'/>
  <window class='progress' top='lines-1' left='82' height='1' width='5'
          label='' value='stamina'
          fg='ffffff,ffffff,ffffff' bg='000000'/>
  <window class='progress' top='lines-1' left='88' height='1' width='5'
          label='' value='concentration'
          fg='00ff00,00ff00,00ff00' bg='000000'/>
  <window class='progress' top='lines-1' left='94' height='1' width='5'
          label='' value='spirit'
          fg='00ffff,00ffff,00ffff' bg='000000'/>

  <!-- Discard atmospheric messages -->
  <window class='sink' value='atmospherics'/>
</layout>
```

---

## 4. Key Bindings

Key bindings map keyboard input to actions or macros. They are defined inside
the `<settings>` root element (not inside a layout).

### Basic Key Binding Syntax

```xml
<key id='<key-name>' action='<action-name>'/>
```

or with a macro:

```xml
<key id='<key-name>' macro='<macro-string>'/>
```

### Available Key Names

The following key names can be used in the `id` attribute:

**Control keys:**

| Name | Key |
|------|-----|
| `ctrl+a` through `ctrl+z` | Control + letter (except `ctrl+c`, `ctrl+q`, `ctrl+s`, `ctrl+z`) |
| `tab` or `ctrl+i` | Tab key |
| `enter` or `ctrl+j` | Enter key (line feed) |
| `return` or `ctrl+m` | Return key (carriage return) |

**Navigation keys:**

| Name | Key |
|------|-----|
| `up`, `down`, `left`, `right` | Arrow keys |
| `home`, `end` | Home / End |
| `win_end` | Windows-style End key (alternate keycode) |
| `page_up`, `page_down` | Page Up / Page Down |
| `insert`, `delete` | Insert / Delete |
| `backspace` | Backspace |
| `win_backspace` | Windows-style Backspace (alternate keycode) |

**Function keys:**

| Name | Key |
|------|-----|
| `f1` through `f12` | Function keys F1-F12 |

**Numpad keys:**

| Name | Key |
|------|-----|
| `num_1` through `num_9` | Numpad 1-9 |
| `num_enter` | Numpad Enter |

**Modifier combinations:**

| Name | Key |
|------|-----|
| `alt` or `escape` | Alt / Escape (keycode 27) |
| `ctrl+left`, `ctrl+right` | Ctrl + arrow |
| `ctrl+up`, `ctrl+down` | Ctrl + arrow |
| `ctrl+delete` | Ctrl + Delete |
| `alt+left`, `alt+right` | Alt + arrow |
| `alt+up`, `alt+down` | Alt + arrow |
| `alt+page_up`, `alt+page_down` | Alt + Page Up/Down |
| `alt+1` through `alt+5` | Alt + number (for tab switching) |
| `ctrl+?` | Ctrl + ? (keycode 127) |
| `resize` | Terminal resize event |

**Single characters:** Any single character can be used directly as a key name
(e.g., `id='a'`).

**Numeric keycodes:** Raw keycode integers can be used (e.g., `id='410'`).

### Available Actions

Actions are predefined behaviors that can be bound to keys:

**Command input:**

| Action | Description |
|--------|-------------|
| `send_command` | Send the current command buffer to the game |
| `send_last_command` | Resend the most recent command from history |
| `send_second_last_command` | Resend the second-most-recent command |
| `previous_command` | Navigate to the previous (older) command in history |
| `next_command` | Navigate to the next (newer) command in history |

**Cursor movement:**

| Action | Description |
|--------|-------------|
| `cursor_left` | Move cursor left one character |
| `cursor_right` | Move cursor right one character |
| `cursor_word_left` | Move cursor left one word |
| `cursor_word_right` | Move cursor right one word |
| `cursor_home` | Move cursor to the beginning of the line |
| `cursor_end` | Move cursor to the end of the line |

**Editing:**

| Action | Description |
|--------|-------------|
| `cursor_backspace` | Delete the character before the cursor |
| `cursor_delete` | Delete the character at the cursor |
| `cursor_backspace_word` | Delete the word before the cursor (saved to kill ring) |
| `cursor_delete_word` | Delete the word after the cursor (saved to kill ring) |
| `cursor_kill_forward` | Kill text from cursor to end of line (saved to kill ring) |
| `cursor_kill_line` | Kill the entire line (saved to kill ring) |
| `cursor_yank` | Yank (paste) the kill ring contents at the cursor |

**Window management:**

| Action | Description |
|--------|-------------|
| `switch_current_window` | Cycle focus to the next scrollable window |
| `scroll_current_window_up_one` | Scroll the focused window up by one line |
| `scroll_current_window_down_one` | Scroll the focused window down by one line |
| `scroll_current_window_up_page` | Scroll the focused window up by one page |
| `scroll_current_window_down_page` | Scroll the focused window down by one page |
| `scroll_current_window_bottom` | Scroll the focused window to the bottom (newest content) |
| `resize` | Manually recalculate all window positions and sizes |
| `switch_arrow_mode` | Cycle up/down arrows through history, page scroll, and line scroll modes |

**Tab management:**

| Action | Description |
|--------|-------------|
| `next_tab` | Switch to the next tab in all tabbed windows |
| `prev_tab` | Switch to the previous tab in all tabbed windows |
| `switch_tab_1` through `switch_tab_5` | Switch to tab 1-5 by index |

**Autocomplete:**

| Action | Description |
|--------|-------------|
| `autocomplete` | Complete the current input from command history (see [Autocomplete](#15-autocomplete)) |

### Macro Syntax

Macros are strings that get "typed" into the command buffer with special escape
sequences:

| Escape | Meaning |
|--------|---------|
| `\r` | Press Enter (send the current command) |
| `\x` | Clear the command buffer |
| `\\` | Literal backslash |
| `\@` | Literal `@` character |
| `\?` | Set a backfill position (advanced) |
| `@` | Mark cursor position (after the macro finishes, the cursor moves here) |

**Examples:**

```xml
<!-- F1 sends "look" to the game -->
<key id='f1' macro='look\r'/>

<!-- F2 types "cast" but leaves cursor before pressing enter -->
<key id='f2' macro='cast @'/>

<!-- F3 clears the buffer and types a new command -->
<key id='f3' macro='\xattack\r'/>

<!-- Numpad directions -->
<key id='num_8' macro='north\r'/>
<key id='num_2' macro='south\r'/>
<key id='num_4' macro='west\r'/>
<key id='num_6' macro='east\r'/>
<key id='num_7' macro='northwest\r'/>
<key id='num_9' macro='northeast\r'/>
<key id='num_1' macro='southwest\r'/>
<key id='num_3' macro='southeast\r'/>
<key id='num_5' macro='out\r'/>
```

### Nested Key Combos (Multi-Key Sequences)

You can create multi-key sequences by nesting `<key>` elements. The first key
opens a "combo" context, and the next key press is looked up within that
context.

```xml
<!-- Escape then 'a' sends "attack" -->
<key id='escape'>
  <key id='a' macro='attack\r'/>
  <key id='h' macro='hide\r'/>
  <key id='s' macro='stalk\r'/>
</key>
```

With this binding, pressing Escape followed by `a` sends "attack". Pressing
Escape followed by any key not listed cancels the combo.

Some key names like `alt+1` through `alt+5` are internally represented as
multi-key sequences (Escape + digit). These are handled automatically when you
use those key names.

### Complete Key Binding Example

```xml
<!-- Essential bindings -->
<key id='enter' action='send_command'/>
<key id='left' action='cursor_left'/>
<key id='right' action='cursor_right'/>
<key id='ctrl+left' action='cursor_word_left'/>
<key id='ctrl+right' action='cursor_word_right'/>
<key id='home' action='cursor_home'/>
<key id='end' action='cursor_end'/>
<key id='backspace' action='cursor_backspace'/>
<key id='ctrl+h' action='cursor_backspace'/>
<key id='delete' action='cursor_delete'/>
<key id='ctrl+w' action='cursor_backspace_word'/>
<key id='ctrl+k' action='cursor_kill_forward'/>
<key id='ctrl+u' action='cursor_kill_line'/>
<key id='ctrl+y' action='cursor_yank'/>
<key id='up' action='previous_command'/>
<key id='down' action='next_command'/>

<!-- Window management -->
<key id='tab' action='switch_current_window'/>
<key id='page_up' action='scroll_current_window_up_page'/>
<key id='page_down' action='scroll_current_window_down_page'/>
<key id='alt+page_up' action='scroll_current_window_up_one'/>
<key id='alt+page_down' action='scroll_current_window_down_one'/>

<!-- Tab switching -->
<key id='alt+1' action='switch_tab_1'/>
<key id='alt+2' action='switch_tab_2'/>
<key id='alt+3' action='switch_tab_3'/>
<key id='alt+4' action='switch_tab_4'/>
<key id='alt+5' action='switch_tab_5'/>
<key id='ctrl+n' action='next_tab'/>
<key id='ctrl+p' action='prev_tab'/>

<!-- Numpad movement macros -->
<key id='num_8' macro='north\r'/>
<key id='num_2' macro='south\r'/>
<key id='num_6' macro='east\r'/>
<key id='num_4' macro='west\r'/>
<key id='num_9' macro='northeast\r'/>
<key id='num_7' macro='northwest\r'/>
<key id='num_3' macro='southeast\r'/>
<key id='num_1' macro='southwest\r'/>
<key id='num_5' macro='out\r'/>
<key id='num_enter' macro='go gate\r'/>

<!-- Resize on terminal resize event -->
<key id='resize' action='resize'/>
```

---

## 5. Highlights

Highlights apply foreground and/or background colors to text matching a regular
expression. They work across all text windows (main, combat, chat, experience,
active spells, etc.).

### Syntax

```xml
<highlight fg='<hex-color>' bg='<hex-color>' ul='true'>REGEX_PATTERN</highlight>
```

| Attribute | Required | Description |
|-----------|----------|-------------|
| `fg` | no | Foreground color as a 6-digit hex code |
| `bg` | no | Background color as a 6-digit hex code |
| `ul` | no | Set to `'true'` to underline matching text |

The text content of the element is a Ruby regular expression. Standard regex
features are supported: character classes, quantifiers, alternation, anchors,
lookahead, etc.

### Examples

```xml
<!-- Color your own name magenta -->
<highlight fg='ff00ff'>Yourname</highlight>

<!-- Color roundtime messages red -->
<highlight fg='ff0000'>^\[?Roundtime.*</highlight>

<!-- Color "wait" messages red -->
<highlight fg='ff0000'>^\.\.\.wait \d+ seconds.$</highlight>

<!-- Color exits green -->
<highlight fg='00ff00'>^(Obvious (exits|paths)|Room Exits):</highlight>

<!-- Highlight whispers cyan -->
<highlight fg='00ffff'>^\[Private(To)?\]</highlight>

<!-- Color gems yellow -->
<highlight fg='ffff00'>\b(diamond|emerald|sapphire|ruby|opal|pearl)\b</highlight>

<!-- Highlight deaths red with dark red background -->
<highlight fg='ff0000' bg='330000'>which appears dead</highlight>

<!-- Underline important items -->
<highlight fg='ffff00' ul='true'>cambrinth</highlight>

<!-- Highlight skills by mindstate using color intensity -->
<!-- Mindstate 0 = white (not learning) -->
<highlight fg='ffffff'>\w+:\s+\d+\s\d+%\s+\[\s?0/34\]</highlight>
<!-- Mindstate 1-10 = cyan (learning slowly) -->
<highlight fg='00ffff'>\w+:\s+\d+\s\d+%\s+\[\s?[1-9]|10/34\]</highlight>
<!-- Mindstate 11-20 = green (learning well) -->
<highlight fg='00ff00'>\w+:\s+\d+\s\d+%\s+\[1[1-9]|20/34\]</highlight>
<!-- Mindstate 21-30 = yellow (learning fast) -->
<highlight fg='ffff00'>\w+:\s+\d+\s\d+%\s+\[2[1-9]|30/34\]</highlight>
<!-- Mindstate 31-34 = orange (nearly capped) -->
<highlight fg='ff8700'>\w+:\s+\d+\s\d+%\s+\[3[1-4]/34\]</highlight>
```

### How Highlights Are Applied

- Highlights are applied to text **after** XML tags are stripped.
- When multiple highlight rules match overlapping regions, the rule with the
  **smallest matching range** takes priority (most specific wins).
- Highlight rules are checked in the order they appear in the settings file.
- Highlights are reloaded when you run `.reload`.

### Using XML Entities for Colors

Combine with the DOCTYPE entity definitions for readable color names:

```xml
<!DOCTYPE highlight [
  <!ENTITY red    "ff0000">
  <!ENTITY green  "00ff00">
  <!ENTITY yellow "ffff00">
]>

<settings>
  <highlight fg='&red;'>danger pattern</highlight>
  <highlight fg='&green;'>safe pattern</highlight>
  <highlight fg='&yellow;'>warning pattern</highlight>
</settings>
```

---

## 6. Gag Patterns

Gag patterns suppress (hide) lines that match a regular expression. There are
two types:

### General Gag Patterns

Applied to **all** incoming text. Lines matching a general gag are dropped
before they reach any window.

```xml
<gag>REGEX_PATTERN</gag>
```

### Combat Gag Patterns

Applied only to text in the **combat** stream. Use these to filter repetitive
combat messages.

```xml
<combat_gag>REGEX_PATTERN</combat_gag>
```

### Examples

```xml
<!-- Hide atmospheric moth messages -->
<gag>You also see .* moth</gag>

<!-- Hide weather messages -->
<gag>^A (light|heavy) (rain|snow) (begins|continues) to fall\.</gag>

<!-- Hide "You feel" atmospheric messages -->
<gag>^A warm breeze blows through the area\.</gag>

<!-- Hide combat miss messages -->
<combat_gag>swings wide and fails to connect</combat_gag>

<!-- Hide fumble messages in combat -->
<combat_gag>fumbles? .* attack</combat_gag>

<!-- Hide specific creature ambient text -->
<combat_gag>^An? \w+ (hisses|growls|snarls) menacingly\.</combat_gag>
```

### Notes

- Gag patterns use Ruby regular expression syntax.
- General gags are checked before any text processing or routing.
- Combat gags are checked only for lines in the combat stream.
- On `.reload`, custom gag patterns from XML are reloaded (defaults are
  preserved).
- Invalid regex patterns are logged as warnings and skipped.

---

## 7. Dot-Commands

Dot-commands are local ProfanityFE commands (not sent to the game server). Type
them in the command input line. All dot-commands are case-insensitive.

Any input starting with `.` that does not match a dot-command is forwarded to
the game server with the leading `.` replaced by `;` (the Lich command prefix).

### .quit

Exit ProfanityFE immediately.

```
.quit
```

### .key

Display the raw keycode of the next key you press. Useful for discovering
keycodes to use in key bindings.

```
.key
```

After typing `.key` and pressing Enter, press any key to see its keycode
displayed in the main window.

### .reload

Hot-reload the settings XML file. Refreshes highlights, key bindings, gag
patterns, and perc-transforms without restarting.

```
.reload
```

### .layout

Switch to a named layout defined in the settings file. Reloads all windows and
triggers a resize.

```
.layout default
.layout combat
.layout minimal
```

### .resize

Manually recalculate all window positions and sizes for the current terminal
dimensions. Use this when automatic resize detection does not fire (for
example, inside GNU Screen or tmux).

```
.resize
```

### .fixcolor

Reinitialize custom curses colors from the color manager. Use this after
terminal color corruption or theme changes. Only meaningful when custom colors
are enabled.

```
.fixcolor
```

### .resync

Reset the server time offset, forcing recalculation on the next prompt. Fixes
drifted countdown/roundtime timers.

```
.resync
```

### .tab

Manage tabs in tabbed windows.

```
.tab           # List all tabs (active tab marked with *)
.tab 2         # Switch to tab 2 (1-based index)
.tab combat    # Switch to the tab named "combat"
```

When listing tabs, output looks like: `* Tabs: 1:main* 2:combat 3:thoughts`

### .arrow

Cycle the up/down arrow keys through three modes:

- **History mode** (default): Up/Down navigate command history.
- **Page scroll mode**: Up/Down scroll the focused window by one page.
- **Line scroll mode**: Up/Down scroll the focused window by one line.

Each invocation advances to the next mode (history → page → line → history).
The current mode is displayed in the main window after each switch.

```
.arrow
```

This can also be bound to a key:

```xml
<key id='F2' action='switch_arrow_mode'/>
```

### .links

Toggle in-game link highlighting and clicking on or off at runtime.
When enabled, clickable text (inventory items, exits, help links) is
highlighted and can be clicked to execute the associated command.
Disables native terminal text selection while active. Toggle off to
restore text selection. See [Link Display](#13-link-display) for details.

```
.links
```

### .select

Toggle drag-to-select independently of `.links`. Use this to get
Profanity's text selection (drag, double-click word, triple-click line)
without clickable links. Like `.links`, it captures the mouse, so native
terminal selection is unavailable while it is on. Selection is active
when either `.links` or `.select` is on.

```
.select
```

### .draghl

Toggle the live selection highlight that follows the pointer while
dragging. Defaults to on; the choice is saved to
`~/.profanity/settings.json`. Turn it off if your terminal misbehaves
with mouse motion reporting — the selection still works, with the
highlight appearing when you release the button.

```
.draghl
```

### .scrollcfg

Launch the interactive mouse scroll wheel calibration wizard. See
[Mouse Scroll Wheel](#14-mouse-scroll-wheel) for details.

```
.scrollcfg
```

### .highlight

Add a temporary cyan highlight for a text string (session only -- not saved to
the settings XML). The match is case-insensitive and literal (no regex). Quotes
around the string are optional but recommended for clarity.

```
.highlight "some string"
.highlight goblin
```

With no argument, lists all active inline highlights:

```
.highlight
```

### .unhighlight

Remove a previously added inline highlight.

```
.unhighlight "some string"
.unhighlight goblin
```

### .help

Display a list of all available dot-commands with brief descriptions.

```
.help
```

---

## 8. Color System

ProfanityFE uses 6-digit hexadecimal color codes throughout (e.g., `ff0000`
for red, `00ff00` for green). These appear in highlight rules, presets,
indicator/progress/countdown `fg` and `bg` attributes, and inline game text
color tags.

### Custom Colors Mode

When custom colors are enabled (the default if your terminal supports it),
ProfanityFE reprograms curses color slots via `Curses.init_color` to display
the exact hex colors you specify. This gives you the full 24-bit color gamut
on terminals that support `can_change_color`.

### Fixed Palette Mode

When custom colors are disabled (or forced off with `--custom-colors=off`),
ProfanityFE finds the nearest match in the standard 256-color palette for each
hex color. This is useful on terminals that do not support color reprogramming.

### Default Colors

| Flag | Default | Description |
|------|---------|-------------|
| `--default-color-id` | `7` | The curses color ID used for the default foreground |
| `--default-background-color-id` | `0` | The curses color ID used for the default background |

These correspond to curses color slot IDs (0-255). The default values of 7
(white) and 0 (black) work on most terminals.

### Transparent Background

To get a transparent background (matching your terminal's background), use:

```bash
ruby profanity.rb --port=8000 --use-default-colors --default-color-id=-1 --default-background-color-id=-1
```

### Presets

Presets are named color pairs that the game engine references. Define them in
your settings file:

```xml
<preset id='roomName' fg='00ff00'/>
<preset id='roomDesc' fg='cccccc'/>
<preset id='monsterbold' fg='ffff00'/>
<preset id='speech' fg='00ff00'/>
<preset id='whisper' fg='00ffff'/>
<preset id='thought' fg='00ffff'/>
<preset id='voln' fg='3ea4a3'/>
<preset id='percWindow' fg='00ffff'/>
```

Common preset IDs used by the game:

| Preset ID | Used for |
|-----------|----------|
| `roomName` | Room title text (also used by room window) |
| `roomDesc` | Room description text (also used by room window) |
| `monsterbold` | Creature names in room objects (also used by room window) |
| `speech` | Spoken text |
| `whisper` | Whispered text |
| `thought` | Thought network text |
| `voln` | Voln network text |
| `percWindow` | Active spells display color |

### Fixing Color Issues

If colors look wrong after switching terminal themes or after a display glitch,
type `.fixcolor` to reinitialize all custom colors.

---

## 9. Window Scrolling

Text windows and tabbed text windows maintain a scrollable buffer of past
content. The active (focused) window is shown with a bold scrollbar and a
right-pointing triangle indicator at the top.

### Scrolling Keys

These actions must be bound to keys in your settings file (see
[Key Bindings](#4-key-bindings)):

| Action | Effect |
|--------|--------|
| `scroll_current_window_up_page` | Scroll up one page |
| `scroll_current_window_down_page` | Scroll down one page |
| `scroll_current_window_up_one` | Scroll up one line |
| `scroll_current_window_down_one` | Scroll down one line |
| `scroll_current_window_bottom` | Jump to the bottom (newest content) |

### Switching the Active Window

The `switch_current_window` action cycles focus between all scrollable windows
(text windows and tabbed text windows). Typically bound to Tab:

```xml
<key id='tab' action='switch_current_window'/>
```

The active window is indicated by:
- A bold vertical line scrollbar character
- A right-pointing triangle at the top of the scrollbar

Inactive windows have a plain pipe (`|`) scrollbar.

### Scrollbar Behavior

- When you scroll up, a scrollbar thumb (reversed cell) moves to indicate your
  position in the buffer.
- New text arriving while you are scrolled up does **not** auto-scroll the
  window -- it increments the buffer position instead, so you can read history
  without interruption.
- Scrolling to the bottom resumes auto-scroll behavior (new text appears
  immediately).

### Buffer Size

Each text window has a configurable buffer size (via the `buffer-size`
attribute, default 1000 lines). When the buffer exceeds this limit, the oldest
lines are discarded.

---

## 10. Tab Management

Tabbed text windows combine multiple text buffers into a single display area
with a tab bar at the top.

### Switching Tabs

There are several ways to switch tabs:

**By key binding (action):**

```xml
<key id='alt+1' action='switch_tab_1'/>
<key id='alt+2' action='switch_tab_2'/>
<key id='alt+3' action='switch_tab_3'/>
<key id='ctrl+n' action='next_tab'/>
<key id='ctrl+p' action='prev_tab'/>
```

**By dot-command:**

```
.tab 1          # Switch to first tab
.tab 2          # Switch to second tab
.tab combat     # Switch to the tab named "combat"
.tab            # List all tabs with active tab marked
```

### Tab Activity Indicator

When a background tab receives new content, an asterisk (`*`) appears next to
its name in the tab bar:

```
 1:main | 2:combat* | 3:thoughts*
```

Switching to that tab clears the activity indicator.

### Tab Bar Display

The tab bar occupies the top row of the tabbed window. Each tab is shown as
` N:name ` where N is the 1-based index. The active tab is displayed with
reverse video (inverted colors). Tabs are separated by `|`.

### Per-Tab Scroll Position

Each tab maintains its own independent scroll position. Scrolling in one tab
does not affect the others.

---

## 11. Stream Routing

The game server sends text tagged with stream identifiers. ProfanityFE routes
each stream to the window(s) configured to receive it via the `value` attribute
on text and tabbed windows.

### Available Streams

| Stream Name | Content |
|-------------|---------|
| `main` | Primary game output (descriptions, actions, etc.) |
| `combat` | Combat messages (attacks, dodges, hits, etc.) |
| `assess` | Assess/appraise results |
| `thoughts` | Thought network (gweth) messages |
| `lnet` | LichNet messages (detected from thought stream) |
| `voln` | Voln network messages |
| `death` | Player death announcements (reformatted with timestamps) |
| `logons` | Player logon/logoff announcements (reformatted with timestamps) |
| `familiar` | Familiar/notification messages (auction, skill gains, etc.) |
| `ooc` | Out-of-character messages |
| `atmospherics` | Atmospheric descriptions (weather, ambient sounds) |
| `exp` | Experience/skill data (wired to exp windows) |
| `percWindow` | Active spells/effects (wired to perc windows) |
| `moonWindow` | Moon data |
| `shopWindow` | Shop inventory |
| `room` | Room component data (title, desc, objects, players, exits) |

### Routing Rules

1. If a stream has a dedicated window (listed in that window's `value`), text
   goes to that window.
2. For tabbed windows, the stream name is matched to a tab name. If no matching
   tab exists, text goes to the active tab.
3. Streams without a dedicated window that are in the "known" set (death,
   logons, thoughts, voln, familiar, assess, ooc, combat, moonWindow,
   atmospherics) fall back to the `main` window with their preset color applied.
4. Room-related streams (`room`, `room title`, `room desc`, `room objs`,
   `room players`, `room exits`) are routed to the room window if one exists.
   By default, inline room text (title, description, objects, players, exits)
   is also shown in the story window. Use `--room-window-only` to suppress it.

### Special Stream Processing

- **death**: Death messages are reformatted to `HH:MM PlayerName` with a red
  timestamp.
- **logons**: Logon/logoff messages are reformatted to `HH:MM PlayerName` with
  colored timestamps (green for login, yellow for logout, orange for
  disconnect).
- **thoughts**: Messages matching the LNet pattern are rerouted to the `lnet`
  stream.
- **percWindow**: Spell names are automatically abbreviated using a built-in
  lookup table. Perc-transforms from the settings file are also applied.
- **combat**: Combat gag patterns are checked before routing.

### Perc-Transforms

You can define text transformations for the percWindow stream to further
shorten or modify spell display text:

```xml
<!-- Remove duration unit text to save space -->
<perc-transform pattern=" (roisaen|roisan)" replace=""/>

<!-- Shorten "minutes" to "min" -->
<perc-transform pattern="minutes" replace="min"/>
```

The `pattern` attribute is a Ruby regular expression. The `replace` attribute
is the replacement string (defaults to empty string if omitted).

---

## 12. Link Display

The `--links` flag enables colored highlighting and clicking of in-game link
tags. Both GemStone (`<a>` tags) and DragonRealms (`<d cmd='...'>` tags) are
supported. When enabled, link text is rendered using the `links` preset color
(falls back to blue `5555ff` if no preset is defined). All built-in templates
include a `links` preset by default.

**Clickable links:** When `.links` is enabled, clicking on highlighted link
text sends the associated command to the game server. In DragonRealms, this
executes the `cmd` attribute (e.g., `get #40872332`). The command is echoed
to the main window as if you had typed it.

**Text selection:** When `.links` (or `.select`) is on, you can drag to
select text within any window. The selection is clamped to the window
boundary — dragging in the main window won't bleed into adjacent windows.
Selections are anchored to the text itself, not the screen position: if new
lines arrive between press and release, you still copy the text you pressed
on, even after it scrolls. The highlight follows the pointer live while you
drag (toggle with `.draghl` if your terminal misbehaves), holding the
pointer at a window's top or bottom edge auto-scrolls to extend the
selection, double-click selects the word under the cursor, and triple-click
selects the whole line. Lines that were word-wrapped for display are copied
as one logical line, without the mid-sentence breaks. A brief
`[copied N chars]` note appears in the main window after each copy.
Selected text is copied via
OSC 52 (if your terminal supports it) and saved to `/tmp/profanity_selection.txt`.
Native terminal selection is unavailable while `.links` or `.select` is on;
toggle both off if you prefer your terminal's built-in selection.

To customize the link color, override the `links` preset in your settings XML:

```xml
<preset id='links' fg='5f87ff'/>
```

You can toggle link highlighting at runtime with the `.links` dot-command
without restarting.

---

## 13. Mouse Scroll Wheel

ProfanityFE supports mouse scroll wheel input for scrolling the active text
window. Because terminal emulators send different escape sequences for scroll
events, calibration is required.

### Calibration

Run the `.scrollcfg` command to start the interactive calibration wizard. It
will prompt you to scroll up and then scroll down so it can learn the keycodes
your terminal sends. Follow the on-screen instructions.

### Saved Settings

Scroll wheel settings are saved automatically to `~/.profanity/settings.json`.
They persist across sessions -- you only need to calibrate once per terminal
emulator.

---

## 14. Autocomplete

ProfanityFE provides command-line autocomplete via the `autocomplete` action.
Bind it to a key (typically Tab) in your settings file:

```xml
<key id='tab' action='autocomplete'/>
```

When you press the bound key, ProfanityFE searches your command history for
entries matching the current input:

- **Single match:** the command line is auto-filled with the matched command.
- **Multiple matches:** a numbered list of candidates is displayed in the main
  window, and the common prefix is filled in automatically.

---

## 15. Process Title

ProfanityFE updates three things to show your character name and game state:

1. **Process name** (`ps` output) -- via `Process.setproctitle`
2. **Terminal title** (title bar of xterm/iTerm/etc.) -- via `\033]0;` escape
3. **Screen/tmux window name** (window list) -- via `\ek` escape

The process name and terminal title show:

```
CharName [prompt:room]
```

For DragonRealms, the room includes the room number (e.g.,
`Charname [H:Bosque Deriel, Shacks (230008)]`). The screen/tmux window
name shows only the character name to keep the window list compact.

Title escape sequences are written via a forked `printf` subprocess to
avoid interleaving with curses output. Updates are dedup'd -- the escape
only fires when the title actually changes.

This is especially useful when running multiple characters in tmux or GNU
Screen -- each pane/window shows which character is active. The title
updates dynamically on every prompt and room change.

Disable this behavior with the `--no-status` flag if your terminal does not
support title updates or you find it distracting.

---

## 16. Tips and Troubleshooting

### Terminal Requirements

- Your terminal must support at least 256 colors for the best experience.
  Check with `tput colors` -- it should return 256 or higher.
- For custom colors (exact hex colors), your terminal must support
  `can_change_color`. Most modern terminals do (iTerm2, kitty,
  gnome-terminal, Windows Terminal).
- A minimum terminal size of approximately 120 columns by 40 rows is
  recommended for the default layout.

### Common Issues

**Colors look wrong or garbled:**
- Run `.fixcolor` to reinitialize colors.
- Try `--custom-colors=off` to fall back to the 256-color palette.
- Make sure your `TERM` environment variable is set correctly (e.g.,
  `xterm-256color` or `screen-256color`).

**Windows are misaligned or overlapping:**
- Run `.resize` to recalculate window positions.
- Check that your layout expressions do not produce negative values or
  positions beyond the terminal dimensions.

**Terminal resize not detected:**
- Bind the resize event: `<key id='resize' action='resize'/>`
- If automatic resize still does not work (common in GNU Screen or tmux),
  type `.resize` manually after resizing.

**Countdown timers are wrong:**
- Type `.resync` to reset the server time offset.

**Key does not work or produces unexpected behavior:**
- Use `.key` to discover the actual keycode your terminal sends for that key.
- Some key combinations may not be available in all terminals (especially
  inside tmux or GNU Screen).

### Logging

ProfanityFE writes errors and debug information to a log file. The default
location depends on how you launch:

- **With `--char=<name>`:** log file defaults to `~/.profanity/<charname>.log`
- **Without `--char`:** log file defaults to `profanity.log` in the current
  working directory

The `--log-file=<path>` flag overrides the log path entirely. The
`--log-dir=<dir>` flag sets the directory while keeping the default filename.
Both flags take precedence over the `--char` default.

Check the log file if something goes wrong.

### GNU Screen and tmux

When running inside Screen or tmux:
- Use `--custom-colors=off` if colors look wrong.
- Bind `.resize` to a key and use it after resizing the outer terminal.
- Some key combinations (especially Alt+key) may be intercepted by the
  multiplexer. Adjust your Screen/tmux configuration or use alternative
  bindings.

### Lich Integration

ProfanityFE connects to the port that Lich opens for frontend connections.
When starting Lich, note the port number it reports and pass it to ProfanityFE
with `--port=<port>`.

On connect, ProfanityFE automatically sends a `look` command as soon as the
first game prompt is received. This ensures the room window is populated
immediately without requiring manual input.

Commands starting with `.` that are not recognized as dot-commands are
forwarded to the game server with the leading `.` replaced by `;`, which is the
standard Lich script command prefix. For example, typing `.e echo hello` sends
`;e echo hello` to Lich.

### Performance

- **Settings cache:** Parsed XML settings are cached as a Marshal file in
  `~/.profanity/` (e.g. `mahtra.settings.cache`). The first load parses the
  XML normally; subsequent launches load the cache in ~1ms instead of ~230ms.
  The cache auto-invalidates when the XML file is modified, and `.reload`
  works normally (editing the XML makes it newer than the cache).
- **Boot profiling:** Use `--profile` to log a timing breakdown of each
  startup phase to the log file. Useful for diagnosing slow launches.
- The `buffer-size` attribute controls how many lines each text window retains.
  Very large values (10000+) may increase memory usage.
- ProfanityFE batches screen updates and delays rendering when more server data
  is available, reducing flicker during heavy output.
- Curses rendering is synchronized via `CursesRenderer` (a reentrant `Monitor`)
  to prevent display corruption between the input thread, server read thread,
  and timer threads. The server thread holds the monitor for the entire line
  processing cycle so that indicator, text, and countdown `noutrefresh` calls
  are flushed atomically with `doupdate`.

### Command History

- Commands shorter than 4 characters are not saved to history (except
  all-digit commands, which are always saved).
- Consecutive duplicate commands are suppressed in history.
- Use Up/Down arrows to navigate history.
- Pressing Down when at the newest entry clears the command line and saves the
  current text to history.

### Kill Ring (Cut/Paste)

ProfanityFE has a readline-style kill ring:
- `cursor_backspace_word` and `cursor_delete_word` save deleted text.
- `cursor_kill_forward` saves text from cursor to end of line.
- `cursor_kill_line` saves the entire line.
- `cursor_yank` pastes the most recently killed text.
- Successive kill operations accumulate text in the kill buffer (like Emacs).

---

## 17. Sample Login Script

Here's a sample login script for Linux that launches Lich and connects
ProfanityFE automatically. Usage: `./gemstone.sh <CHARNAME>`

> **Note:** You may need to adjust `TERM` based on your terminal emulator
> (e.g., `xterm-256color` vs `screen-256color`).

```bash
#!/bin/bash
set -e

port=8000
CHAR=$1
LICH_BIN=~/lich-5/lich.rbw
PROFANITY_BIN=~/ProfanityFE/profanity.rb

lookup_char_port () {
  local char=$1
  port=$(ps a | egrep -0 "\-\-login $char \-\-detachable-client=([0-9]+)" | egrep -o "[0-9]+" | sort | tail -n1)
}

if [[ -z $CHAR ]]; then
  echo "Usage: gemstone.sh {{character_name}}"
  exit
fi

if [[ -z $DISPLAY ]]; then
  echo "Detected empty DISPLAY setting, defaulting to :0"
fi

echo "Attempting to login as $CHAR..."

if ps aux | \grep [l]ich | \grep -i $CHAR; then
  lookup_char_port $CHAR
  echo "Detecting existing connection on port $port"
else
  if ps a | \grep [d]etachable-client; then
    max_port=$(ps a | grep -Eo "\-\-detachable-client=([0-9]+)" | egrep -o "[0-9]+" | sort | tail -n1)
    port=$(expr $max_port + 1)
  fi
  echo "Detecting existing clients but no connection for this character. Using Port[$port]"
  echo "ruby $LICH_BIN --login $CHAR --detachable-client=$port --without-frontend 2> /dev/null &"

  ruby $LICH_BIN --login $CHAR --detachable-client=$port --without-frontend 2> /dev/null &
  sleep 4
fi

for i in {1..10}; do
  echo "Attempting to connect to lich process... "
  echo "ruby $PROFANITY_BIN --port=$port --char=$CHAR"
  if ruby $PROFANITY_BIN --port=$port --char=$CHAR; then
    echo "Done"
    break
  else
    echo "Failed to establish connection, trying again in 3 seconds..."
    sleep 3
  fi
done
```
