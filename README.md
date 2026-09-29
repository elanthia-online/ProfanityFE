# ProfanityFE

A curses-based terminal frontend for [DragonRealms](https://www.play.net/dr/) and [GemStone IV](https://www.play.net/gs4/), connecting through a local game proxy such as [Lich](https://github.com/elanthia-online/lich-5).

## Features

- Multi-window layouts (story, combat, death, thoughts, room, spells, etc.)
- Color highlighting with configurable regex patterns
- Countdown timers for roundtime/casttime/stun
- Progress bars for health, mana, stamina, stance, encumbrance
- Clickable in-game links (directions, objects, players)
- Tabbed text windows with per-tab activity indicators
- Dedicated room window with creature highlighting
- Experience tracking window
- Active spell display with duration sorting
- Gag patterns for filtering unwanted text
- Emacs-style kill ring and command history
- Mouse scroll wheel support
- Macro engine with key bindings

## Quick Start

```bash
git clone https://github.com/elanthia-online/ProfanityFE.git
cd ProfanityFE
bundle install
ruby profanity.rb --port=8000 --char=YourCharacter
```

## Documentation

See the **[User Guide](USER_GUIDE.md)** for full documentation including settings XML reference, layout configuration, key bindings, and troubleshooting.

## Dependencies

- Ruby 4.0+
- Gems to run the client:
  - [curses](https://rubygems.org/gems/curses) (~> 1.4)
  - [rexml](https://rubygems.org/gems/rexml) (~> 3.4)
- Gems for development (the `test` group):
  - [rspec](https://rubygems.org/gems/rspec) (~> 3.13): the test suite
  - [rubocop](https://rubygems.org/gems/rubocop) (~> 1.75): style checks; CI runs the version locked in `Gemfile.lock`
  - [yard](https://rubygems.org/gems/yard) (~> 0.9): API documentation; CI fails on YARD warnings or undocumented public objects

Install all dependencies with `bundle install`, or only the ones needed to run the client with `bundle config set --local without test && bundle install`.

## License

Licensed under the GNU General Public License v2.0. See [profanity.rb](profanity.rb) header for details.
