# Replay benchmarks

Tools for measuring how much CPU ProfanityFE uses on a real game stream, finding where it goes, and checking that a speed-up changes nothing the user sees. They drive the real `profanity.rb`, unmodified, in a pseudo-terminal, so the numbers include parsing, gags, highlights, window drawing and curses, as a player's window would.

| Tool | What it does |
|---|---|
| `stream_fixture.rb` | Turns a captured stream into a replay fixture (`.jsonl`) |
| `record.rb` | Records exactly what a running Lich sends a front end |
| `replay.rb` | Replays a fixture into `profanity.rb` and prints the CPU it used, as JSON |
| `compare.rb` | Replays the same fixture into several checkouts at once and prints medians |
| `fleet.rb` | Runs N replays at once, to see what N windows cost a host |
| `attach.rb` | Attaches N real windows to running Lich sessions and measures them (Linux) |
| `filter_dump.rb` | Dumps what the gag filter keeps for every line, to compare two checkouts |
| `profile_preload.rb` | Loaded into the client by `replay.rb`: CPU at exit, server-thread CPU, profilers |

Captures go in `script/bench/fixtures/` and results in `script/bench/out/`; git ignores both.

## Quick start

```sh
# A fixture from a stream already in the repo (no timestamps, so paced at --rate lines a second)
ruby script/bench/stream_fixture.rb spec/fixtures/stream_routing_session.xml script/bench/out/session.jsonl --rate=20

# Replay it into this checkout
ruby script/bench/replay.rb script/bench/out/session.jsonl
# {"label":"session","lines":75,"chunks":75,"cpu_s":0.21,...,"counters":{"server_thread_cpu":0.015}}
```

`cpu_s` is the whole client process, startup included (about 0.1-0.25 s), and so is `us_per_line` (`cpu_s` over the lines sent). `counters.server_thread_cpu` is the thread that reads and processes server lines, measured exactly with the thread CPU clock. It is the number to watch when changing line handling: it leaves out startup and the input loop. `replay.rb` exits non-zero, showing the end of what the client's terminal showed, if the client never connects, stops reading, or exits without writing its report.

## Getting a real stream

A useful benchmark needs minutes of real play, not a spec fixture. Two ways to get one:

1. **From a `logxml` log** (`logs/<game>-<Name>/<year>/<month>/*.xml`). Run logxml with timestamps on every line, and with the stream tags kept:
   ```
   ;logxml streams --timestamp="%F %T %Z"
   ```
   Without `--timestamp`, the lines have no times, and the whole log is paced at `--rate`. Without `streams`, logxml leaves out lines that start with `<pushStream` or `<popStream`, so the stream structure the client sees is incomplete. Then:
   ```sh
   ruby script/bench/stream_fixture.rb --from=19:10:00 --to=19:20:00 path/to/log.xml script/bench/fixtures/crafting.jsonl
   ```
   The converter skips logxml's header and footer lines, its reget block and its comments (the client's own commands). `--from`/`--to` take `HH:MM:SS` (on the log's first date; a `--to` earlier than `--from` means the next day) or `"YYYY-MM-DD HH:MM:SS"`. A pause longer than `--max-gap` (60 s) is shortened to it, so an idle hour or a clock change doesn't stall a replay.

   logxml logs the stream as the game sent it, which is not quite what a front end receives (see the next item). That's fine for relative comparisons, but it overstates line lengths for DragonRealms.
2. **Recorded from a running Lich** (exact):
   ```sh
   ruby script/bench/record.rb 43685 180 script/bench/fixtures/crafting-raw.xml   # PORT SECONDS OUT
   ruby script/bench/stream_fixture.rb script/bench/fixtures/crafting-raw.xml script/bench/fixtures/crafting.jsonl
   ```
   `record.rb` connects to Lich's detachable-client port as one more client and sends nothing. It gets what a front end gets: Lich's per-client rewrites (DragonRealms' `<a exist>` links are removed for clients that have not declared them, which makes lines about 40% shorter) and script output, which the log does not have. If a window is already attached, Lich's listener must accept several clients at once. Lich 5.23 does; an older Lich may drop the attached window.

**Captures are private.** They hold everything the character saw, including other players' names and speech. Keep them in `script/bench/fixtures/` (ignored by git). Never commit one, and don't paste lines from one into an issue or PR.

`--drop-inv` removes DragonRealms' worn-inventory stream (`<clearStream id='inv'/>` ... `<popStream/>`, resent every few seconds while crafting), keeping the rest of the lines it shares. In a log without stream tags, the next prompt ends a dump. Replaying a fixture with and without the option measures what those dumps cost.

## Measuring

```sh
# Two checkouts on the same fixture, 3 rounds, replayed 4x faster than recorded
ruby script/bench/compare.rb --rounds=3 --speed=4 script/bench/fixtures/crafting.jsonl main=../pfe-main branch=.
```

What makes the numbers trustworthy:

- **Run builds at the same time, never one after another.** `compare.rb` does this. On CPUs with performance and efficiency cores (Apple silicon, Intel 12th generation and later), the same work can cost up to about twice the CPU time on an efficiency core, and the scheduler decides which core a process gets. Runs started together share the same conditions. Absolute numbers from separate batches are not comparable; ratios within a batch are.
- **Use medians of at least 3 rounds**, and look at the per-round differences: a real improvement shows in every round.
- **Use the settings the user runs.** Gags and highlights dominate the per-line cost, and that cost depends on the patterns in the settings file. `--settings=FILE` (default `templates/default.xml`) is copied into a temporary `HOME` for each run, so `~/.profanity` is never touched.
- **Replay speed changes the work.** The client draws the screen when no more server data is waiting, so a faster replay batches more lines per screen update and the drawing share shrinks. Fixed costs per wall-clock second (the input loop wakes 10 times a second) shrink too. `--speed=4` or `8` is fine for comparing line handling. For "what does a window cost per hour", replay at `--speed=1`.
- **Check the replay against reality once.** On the host where the windows run, read a window's CPU from `/proc/<pid>/stat` (fields 14 and 15, in clock ticks) over a few minutes while `record.rb` records the same minutes from its Lich. Then replay that recording at `--speed=1`. In the investigation below the replay came to about 90% of the live window's CPU.
- **Terminal size matters a little** (`--rows`, `--cols`; default 60x230). Text window wrapping and the screen update scale with it.

`fleet.rb --windows=30 FIXTURE` runs 30 replays at once. It reports their total CPU in cores: the total over the median window's stream time, startup included. It also reports `server_cores`, which leaves out startup and the input loop, and the load average every 5 s while they ran. It exits non-zero if any replay failed, as does `compare.rb`, and Ctrl-C or TERM ends every replay it started. `attach.rb` does the same with real windows attached to running Lich sessions (`NAME:PORT:LICH_PID` per session). It types nothing, so nothing reaches the game. It ends every window it started, and it stops early if the load average passes `--max-load`. A window whose client exits before measuring starts (a wrong port, say) is listed under `failed` and left out of the totals.

## Finding where the time goes

`replay.rb --vernier=out/report.txt` writes a per-thread report of running samples, self and inclusive, from [vernier](https://github.com/jhawthorn/vernier). The gem is not in the bundle; install it next to it:

```sh
gem install vernier --install-dir /tmp/bench-gems
GEM_PATH=/tmp/bench-gems:$(gem env gempath) ruby script/bench/replay.rb --vernier=script/bench/out/v.txt FIXTURE
```

Look at the `server_connection.rb` thread (the server reader). The main thread's samples are mostly startup and the input loop. Profiling adds system time, so take CPU numbers from runs without a profiler.

- **stackprof** (`--stackprof=FILE`) samples whichever thread holds the GVL. With ProfanityFE's threads it pinned most samples on the input loop's `IO.select` while the server thread was doing the work. Prefer vernier.
- **rbspy** did not support Ruby 4.0.9 when these tools were written.
- **On a live process,** `gdb -p PID -batch -ex "thread apply all bt"` works where ptrace is allowed, but it pauses the window for each sample.

`--count-highlights` adds `counters.highlights`: calls, texts seen before, and CPU in `HighlightProcessor.apply_highlights`.

## Checking that nothing visible changed

A speed-up must not change what the user sees. For gag matching:

```sh
ruby script/bench/filter_dump.rb ../pfe-main SETTINGS.xml main.txt script/bench/fixtures/*.jsonl
ruby script/bench/filter_dump.rb .            SETTINGS.xml mine.txt script/bench/fixtures/*.jsonl
cmp main.txt mine.txt
```

Each line goes through the real `LineFilter` twice, so the second pass covers lines the filter has seen before. For other changes, build the same kind of harness around the code you changed: feed every line of real fixtures to both checkouts and compare a full dump of the output (window writes, events, colour spans). Then break your change on purpose and confirm the harness notices.

## Example: the 2026 investigation

On a host running about 30 DragonRealms characters, each ProfanityFE window used more CPU than its Lich process. Replays of recorded streams with these tools showed:

| Server-thread CPU | Crafting stream | Travel stream |
|---|---|---|
| General gag matching | 73% | 45% |
| Highlights | ~2% | 18% |
| Room window and screen updates | ~2% | ~21% |

81-94% of lines repeated an earlier line, mostly the worn-inventory dump. The fixes:

- gag verdicts remembered per line, and each gag tried on its own instead of through a `Regexp.union` (#280, merged with #283);
- `FamiliarNotifier` key-word guards (#281);
- highlight regions remembered per text (#282);
- combat gags tried one by one (#283).

The gag change alone cut a recorded 3-minute crafting stream's replay CPU by about 44%, net of startup. Each was checked with a dump like the one above, over tens of thousands of real lines.

Two other results from the same work. Thirty windows attached to real sessions with `attach.rb` came to about 0.2 cores in total. And with line handling cheap, the largest remaining cost is the input loop's ten wake-ups a second (about 0.9 ms of CPU a second per window).
