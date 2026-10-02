# Bitnight Rambler

Tiny pixel-art ramblers that roam the bottom of your terminal.

`rambit` is a small animation engine written in Zig with no dependencies
beyond the standard library. Sprites are plain text files, so a new rambler
is data, not code.

![A cat, a slime and a ghost roaming three terminals](docs/demo.gif)

> **Status:** proof of concept. See [ABSTRACT.md](ABSTRACT.md) for the
> design goals.

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/).

```sh
zig build                          # builds zig-out/bin/rambit
zig build run -- cat               # builds and runs
zig build test                     # unit tests, including every built-in rambler
zig build validate                 # rambit validate ramblers
zig build -Doptimize=ReleaseSmall  # a standalone binary of under 300 KB
```

Tested on Linux. It also builds for macOS, but has not been tried there
yet. Windows is not supported yet.

### With Nix

The flake provides Zig 0.16.0 and ZLS for x86_64-linux, aarch64-linux
and aarch64-darwin:

```sh
nix develop          # a shell with zig and zls
direnv allow         # or let direnv load it whenever you cd in (.envrc)
nix build            # ./result/bin/rambit, after running the tests
nix run . -- cat
nix flake check
```

## Usage

```sh
rambit cat              # q, Esc or Ctrl-C sends it home
rambit slime --once     # cross the screen once and exit, like sl
rambit ghost --seed 42  # the same seed gives the same stroll
rambit list             # the built-in ramblers
rambit preview cat      # print every frame, e.g. to review a pull request
rambit validate         # check the built-in ramblers, or given directories
```

| Option           | Meaning                                                      |
| ---------------- | ------------------------------------------------------------ |
| `--once`         | Cross the screen once and exit.                              |
| `--seed <n>`     | Seed the movement for a reproducible run.                    |
| `--color <mode>` | `auto` (default), `truecolor` or `256`. `auto` uses 24-bit color when `COLORTERM` is `truecolor` or `24bit`. |

A rambler runs on the alternate screen, like `less` or `vim`, so your
terminal looks exactly as before once it leaves.

## Adding a rambler

Make a directory under `ramblers/`. The build embeds every directory there,
so no code needs to change:

```text
ramblers/cat/
├── manifest.json
├── idle-0.sprite
├── walk-0.sprite
└── ...
```

While drawing, run it straight from the directory, without rebuilding:

```sh
rambit preview ./ramblers/cat   # every frame side by side
rambit ./ramblers/cat           # the real thing
rambit validate ramblers/cat    # what is wrong, with file:line:column
```

### manifest.json

```json
{
  "id": "cat",
  "name": "Cat",
  "description": "A little tabby that strolls along the bottom of your terminal.",
  "width": 16,
  "height": 12,
  "facing": "right",
  "palette": { "k": "#3b2730", "o": "#f2a65a", "w": "#ffe9c7" },
  "animations": {
    "idle": { "frames": ["idle-0", "idle-1"], "frame_ms": 400 },
    "walk": { "frames": ["walk-0", "walk-1", "walk-2", "walk-3"], "frame_ms": 140 }
  },
  "motion": { "speed": 9 }
}
```

| Field          | Required | Meaning |
| -------------- | -------- | ------- |
| `id`           | yes      | Lowercase letters, digits and `-`. Must match the directory name. |
| `name`         | yes      | Display name. |
| `description`  | no       | Shown by `rambit list`. |
| `width`, `height` | yes   | Size of every frame in pixels, 1 to 64. |
| `facing`       | no       | `right` (default) or `left`: the direction the frames are drawn facing. They are mirrored automatically for the other direction. |
| `palette`      | yes      | Single-character symbols mapped to `#rrggbb` colors. |
| `animations`   | yes      | `idle` and `walk` are used today; `run`, `sleep` and `jump` are accepted for later. At least one of `idle` or `walk` is required, and each falls back to the other. |
| `frames`       | yes      | Sprite file names without `.sprite`. Repeat a name to hold a frame longer. |
| `frame_ms`     | no       | Milliseconds per frame, 20 to 10000. Defaults to 150. |
| `motion.speed` | no       | Pixels (terminal columns) per second, 1 to 64. Defaults to 8. |

`walk` plays while the rambler moves, and `idle` while it rests. A rambler
does not need legs: the slime hops and the ghost floats through the same
`walk` animation.

### Sprites

One line of text per pixel row. `.` is transparent, which shows the
terminal's own background; every other character must be in the palette.

```text
..........k...k.
.k.......kpkkkpk
kok......koooook
kok......kokokok
```

Each terminal cell shows two pixels stacked vertically, so a 16×12 sprite
takes up 16 columns and 6 rows.

### Validation

`rambit validate` and `zig build test` check the manifest syntax (with the
line and column of JSON errors), required and unknown fields, value ranges,
frame dimensions, palette symbols, missing frame files, frame names, ids
that do not match their directory or clash with a command or another
rambler, and file size limits. Sprite files no animation uses produce a
warning.

## How it works

- **Rendering.** Ramblers are drawn into a framebuffer of logical pixels.
  Every terminal cell shows two pixels using `▀` and `▄` with ANSI
  foreground and background colors. Only cells that changed since the last
  frame are written.
- **Movement and animation are separate.** The movement logic decides where
  to go and whether to walk or rest; the rambler provides the frames.
  Movement advances in fixed 30 Hz steps from a seeded random number
  generator, so a run is reproducible.
- **Terminal handling.** Raw input, the alternate screen, a hidden cursor
  and no line wrapping while running. The terminal is restored on exit,
  including on `SIGINT`, `SIGTERM`, `SIGHUP` and panics. Resizes are picked
  up through `SIGWINCH`.
- **Single binary.** `build.zig` scans `ramblers/` and generates a module
  that embeds every manifest and sprite with `@embedFile`.

```text
src/
├── main.zig         CLI: play, list, preview, validate
├── play.zig         the animation loop
├── Actor.zig        movement: walking, resting, turning around
├── Rambler.zig      manifest parsing and validation
├── sprite.zig       sprite file parsing
├── Source.zig       embedded files or a directory on disk
├── Diagnostics.zig  problems collected by the validator
├── Canvas.zig       the logical pixel framebuffer
├── Screen.zig       pixels to cells, and cells to escape sequences
├── Terminal.zig     raw mode, alternate screen, signals, terminal size
└── color.zig        colors, palettes, 256-color fallback
```

## Not yet

- Ramblers only walk along the bottom edge.
- `run`, `sleep` and `jump` animations are accepted but not used.
- A pseudo-terminal mode where ramblers share the screen with your shell,
  as described in the abstract, is a later-stage feature.
- No CI yet; `zig build test` and `zig build validate` are what it would
  run on pull requests.
