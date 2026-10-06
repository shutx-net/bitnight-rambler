# Bitnight Rambler

Tiny pixel-art ramblers that roam the edges of your terminal.

`rambit` is a small animation engine written in Zig with no dependencies
beyond the standard library. Sprites are plain text files, so a new rambler
is data, not code.

![A cat, a slime and a ghost roaming three terminals](docs/demo.gif)

> **Status:** proof of concept. See [ABSTRACT.md](ABSTRACT.md) for the
> design goals.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh | sh
```

This installs one static binary, with every built-in rambler inside it,
as `~/.local/bin/rambit`. It needs no sudo and never edits your shell's
startup files; if `~/.local/bin` is not on your `PATH`, it says what to
add. It runs on Linux x86_64 and aarch64 (any distribution, WSL2
included; built for kernel 5.10 or newer) and on macOS 13 or newer, on
Intel and Apple silicon.

Before it installs anything, the installer checks:

1. the signature of the release's `SHA256SUMS` (ECDSA P-256), with the
   public key written into `install.sh` itself;
2. the binary's SHA-256 against `SHA256SUMS`;
3. the binary's GitHub build-provenance attestation (Sigstore), when
   `gh` is installed and logged in: it must come from this repository's
   release workflow, built from the release's tag on a GitHub-hosted
   runner;
4. that `rambit --version` names the release asked for, so an older
   signed release cannot pass for a newer one.

If a check fails, nothing is installed. It needs `curl` and `openssl`
(LibreSSL, as on macOS, works) and stops if either is missing.

Run it as yourself. Under `sudo` or `doas` it refuses, because it would
leave a root-owned `~/.local/bin` in your home, unless you name the
directory. To install for every user:

```sh
curl -fsSL https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh | sudo env RAMBIT_INSTALL_DIR=/usr/local/bin sh
```

| Variable | Meaning |
| -------- | ------- |
| `RAMBIT_VERSION` | The release to install, e.g. `v0.2.0` or `0.2.0`. Defaults to the latest. |
| `RAMBIT_INSTALL_DIR` | An absolute directory to install into instead of `~/.local/bin`. |
| `RAMBIT_SKIP_ATTESTATION=1` | Skip the `gh` attestation check, e.g. when GitHub's attestation service is down. The signature and SHA-256 are still checked. |
| `RAMBIT_INSECURE_SKIP_SIGNATURE=1` | Only when `openssl` is not installed: install with the SHA-256 check alone. That catches a corrupted download, not a tampered release. With `openssl` installed it is ignored, so a bad signature is never skipped. |
| `RAMBIT_DOWNLOAD_BASE` | For testing: an `https://` or `file://` URL to download the release from instead of GitHub. Needs `RAMBIT_VERSION`; the signature is still checked with the embedded key. |

To pin a version, set `RAMBIT_VERSION` for `sh`, not for `curl`:

```sh
curl -fsSL https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh | RAMBIT_VERSION=v0.2.0 sh
```

To read the script before you run it, download it first:

```sh
curl -fsSL -o install.sh https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh
less install.sh
sh install.sh            # sh install.sh --help lists the options
```

### Verifying by hand

You can make the same checks yourself. Download the binary for your
machine (`rambit-x86_64-linux`, `rambit-aarch64-linux`,
`rambit-x86_64-macos` or `rambit-aarch64-macos`), `SHA256SUMS` and
`SHA256SUMS.sig` from the release, and take the public key out of
`install.sh`:

```sh
v=v0.2.0
base=https://github.com/shutx-net/bitnight-rambler/releases/download/$v
curl -fsSL -O "$base/rambit-x86_64-linux" -O "$base/SHA256SUMS" -O "$base/SHA256SUMS.sig"
curl -fsSL https://raw.githubusercontent.com/shutx-net/bitnight-rambler/main/install.sh |
  sed -n '/^-----BEGIN PUBLIC KEY-----$/,/^-----END PUBLIC KEY-----$/p' > rambit-release.pem
```

Then check the signature (it prints `Verified OK`), the hash, and, with
`gh`, the attestation:

```sh
openssl dgst -sha256 -verify rambit-release.pem -signature SHA256SUMS.sig SHA256SUMS
sha256sum -c --ignore-missing SHA256SUMS    # macOS: shasum -a 256 -c --ignore-missing SHA256SUMS
gh attestation verify rambit-x86_64-linux --repo shutx-net/bitnight-rambler \
  --signer-workflow shutx-net/bitnight-rambler/.github/workflows/release.yml \
  --source-ref "refs/tags/$v" --deny-self-hosted-runners
```

If all three pass, install it under the name `rambit`:

```sh
chmod +x rambit-x86_64-linux
mkdir -p ~/.local/bin && mv rambit-x86_64-linux ~/.local/bin/rambit
```

The macOS binaries are not notarized. Files downloaded with `curl` are
not quarantined, so macOS runs them; one downloaded with a browser is,
and `xattr -d com.apple.quarantine <file>` lets it run.

### Uninstall

```sh
rm ~/.local/bin/rambit     # or rambit in your RAMBIT_INSTALL_DIR
```

rambit writes no other files.

### What you trust

The signature catches release files that were changed after they were
signed, and a download that went wrong on the way. It does not protect
you from this repository itself: `install.sh`, with the key in it, comes
from the same repository as the releases, so whoever can change `main`
can change the key. In the end you trust GitHub and the people who
maintain this repository. The private key is kept offline and in a
GitHub secret that only the signing step of the release workflow can
read. The attestation does not depend on that key: it ties each binary
to the workflow run, tag and commit that built it, and the release
workflow checks that the build is the same, byte for byte, on Linux and
macOS before anything is signed. [docs/RELEASING.md](docs/RELEASING.md)
describes how releases are made.

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/).

```sh
zig build                          # builds zig-out/bin/rambit
zig build run -- cat               # builds and runs
zig build test                     # unit tests, including every built-in rambler
zig build validate                 # rambit validate ramblers
zig build -Doptimize=ReleaseSmall  # a standalone binary of under 300 KB
zig build -Dversion=0.2.0-dev      # report another version than build.zig.zon's
tools/build-release.sh dist        # the four release binaries and SHA256SUMS
```

`rambit --version` reports the version in `build.zig.zon` unless
`-Dversion` sets another; it must be a semantic version.
`tools/build-release.sh` cross-builds the release binaries from any one
host, and gives the same bytes on Linux and macOS. How releases are
signed and published is in [docs/RELEASING.md](docs/RELEASING.md).

Tested on Linux. CI also runs the tests on macOS, the pseudo-terminal
ones included, but rambit has not been tried there by hand yet. Native
Windows is not supported; under WSL it runs as on Linux.

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
rambit slime --once     # cross the bottom once and exit, like sl
rambit ghost --seed 42  # the same seed gives the same stroll
rambit list             # the built-in ramblers
rambit preview cat      # print every frame, e.g. to review a pull request
rambit validate         # check the built-in ramblers, or given directories
rambit shell            # your shell, with a rambler roaming over it
rambit shell slime      # the same, starting with the slime
rambit shell -- top     # a command instead of the shell
```

| Option           | Meaning                                                      |
| ---------------- | ------------------------------------------------------------ |
| `--once`         | Cross the screen once along the bottom and exit.             |
| `--seed <n>`     | Seed the movement for a reproducible run.                    |
| `--color <mode>` | `auto` (default), `truecolor` or `256`. `auto` uses 24-bit color when `COLORTERM` is `truecolor` or `24bit`. |

A rambler runs on the alternate screen, like `less` or `vim`, so your
terminal looks exactly as before once it leaves.

### Your shell, with a rambler

`rambit shell` runs your shell (`$SHELL`, or `/bin/sh` without one), or
the command after `--`, on a pseudo-terminal, the way tmux and screen do.
It keeps the program's screen itself, draws the rambler over it and
writes only the cells that changed. When the program exits, so does
rambit, with the program's exit status: 128 plus the signal's number if
it was killed by a signal. A command that cannot be run is reported
before the screen changes, with status 127 if it was not found and 126
otherwise, as a shell would.

The session runs on the alternate screen, so what it showed is gone when
it ends and your terminal looks as it did before. There is no
scrollback: as in tmux, what scrolls off the top is lost, and your
terminal's own scroll bar never sees it.

`--seed` and `--color` work as they do for `rambit <name>`; `--once`
does not apply. Every key goes to the program, Ctrl-C and Esc included,
except Ctrl-] followed by a command key:

| Keys              | Effect                                                 |
| ----------------- | ------------------------------------------------------ |
| `Ctrl-]` `h`      | Hide or show the rambler.                              |
| `Ctrl-]` `n`      | Bring in the next rambler.                             |
| `Ctrl-]` `Ctrl-]` | Send Ctrl-] to the program.                            |

The rambler you name, or else the first built-in, comes first, and
`Ctrl-]` `n` goes on through the other built-ins and round again. Any
other key after Ctrl-] is swallowed, arrow keys and Alt combinations
included. Ctrl-] is telnet's escape key. It takes away no shell binding,
unlike tmux's Ctrl-b and screen's Ctrl-a, which readline and emacs use;
vim follows tags with it, which still works by pressing it twice. Text pasted while the program has bracketed paste on passes
through untouched, Ctrl-] included.

The rambler roams its edges over the text as usual, but stays off the
cursor's row so that it never covers what you type. For two
seconds after a key press it also keeps two rows clear above and below
the cursor. With the cursor on the bottom row, a rambler that climbs
comes in at a corner and goes up the wall; one that only walks the floor
waits off screen until there is room.

Inside the session `RAMBIT_SHELL=1` is set, and `rambit shell` refuses
to start where it is set, rather than nest.

#### How the shell mode works

- **`TERM=xterm-256color`.** Keys are passed on exactly as your terminal
  sends them, and that is almost always an xterm-compatible terminal, so
  the program is told it is in one. The emulator implements what that
  terminfo entry advertises: background color erase, ECH, REP, scroll
  regions, inserting and deleting lines and characters, italics, the 1049
  alternate screen and DEC line drawing. `LINES` and `COLUMNS` are
  removed so that the pty's size counts. `COLORTERM` is passed through,
  and 24-bit colors become the nearest of 256 when rambit itself uses 256
  colors (see `--color`).
- **Modes and replies.** The cursor key, keypad and bracketed paste modes
  the program sets are mirrored to your terminal, and reset when rambit
  exits. Status, cursor position and device attribute queries (DSR, DA)
  are answered, and the bell passes through. Mouse reporting, focus
  events and synchronized output are ignored, and so are OSC, DCS and APC
  strings such as window titles and hyperlinks.
- **Wide characters.** East Asian wide and fullwidth characters take two
  cells, per a table that `tools/width_table.py` generates from Python's
  `unicodedata` (Unicode 14.0), with the few extra wide ranges glibc has,
  so that it agrees with glibc's `wcwidth` up to Unicode 14.
  Ambiguous-width characters take one cell, and combining marks are
  dropped. After any non-ASCII character rambit moves the real cursor
  explicitly, so a terminal that disagrees about a width cannot shift the
  rest of the row.
- **Parsing.** The parser follows Paul Williams' state machine for DEC
  terminals and decodes UTF-8, showing U+FFFD for malformed bytes. Bytes
  0x80 to 0x9F are never taken as C1 controls.
- **Resizing.** A new size is passed on to the pty, and the kernel tells
  the program with `SIGWINCH`. Nothing reflows; the cursor's row stays in
  view, so a prompt at the bottom stays at the bottom.
- **Throughput.** The pty is read as fast as the program writes, and the
  screen is drawn at most 30 times a second, so `cat` of a large file is
  not held up by the terminal.
- **Leaving.** On `SIGINT`, `SIGTERM` or `SIGHUP` rambit hangs up on the
  program, as a closing terminal window would, and kills it if it is
  still there a few seconds later.
- **Platforms.** On Linux, rambit opens `/dev/ptmx` with ioctls and needs
  no libc. On macOS it uses `posix_openpt` and friends from libSystem,
  which every macOS program links, and waits with `select(2)`, since
  `poll(2)` does not work with terminals there.

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

Only `manifest.json` and the `.sprite` files are embedded; the build
ignores anything else in the directory, such as a README or credits.

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
  "description": "A little tabby that strolls around the edges of your terminal.",
  "width": 16,
  "height": 12,
  "facing": "right",
  "palette": {
    "k": "#3b2730",
    "o": "#f2a65a",
    "d": "#c8743a",
    "w": "#ffe9c7",
    "p": "#f497a9"
  },
  "animations": {
    "idle": { "frames": ["idle-0", "idle-0", "idle-0", "idle-1", "idle-0", "idle-0", "idle-2", "idle-2"], "frame_ms": 400 },
    "walk": { "frames": ["walk-0", "walk-1", "walk-2", "walk-3"], "frame_ms": 140 },
    "run": { "frames": ["run-0", "run-1"], "frame_ms": 110 },
    "sleep": { "frames": ["sleep-0", "sleep-1"], "frame_ms": 800 },
    "jump": { "frames": ["run-1", "run-0"], "frame_ms": 120 }
  },
  "wall_animations": {
    "walk": { "frames": ["climb-0", "climb-1", "climb-2", "climb-3"], "frame_ms": 160 },
    "jump": { "frames": ["climb-1", "climb-0"], "frame_ms": 120 }
  },
  "ceiling_animations": {
    "walk": { "frames": ["ceiling-walk-0", "ceiling-walk-1", "ceiling-walk-2", "ceiling-walk-3"], "frame_ms": 140 }
  },
  "motion": { "speed": 9, "run_speed": 20 }
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
| `animations`   | yes      | The floor's animations: `idle`, `walk`, `run`, `sleep` and `jump`. At least one of `idle` or `walk` is required, and each falls back to the other; the others are optional. |
| `wall_animations` | no    | The same kinds and rules, for the walls. With these the rambler climbs them. |
| `ceiling_animations` | no | The same again, for the ceiling. The ceiling is reached by a wall, so this needs `wall_animations` too. |
| `edges`        | no       | The edges to walk along: any of `bottom`, `left`, `right` and `top`. Must include `bottom`; the walls need `wall_animations`, and `top` needs `ceiling_animations` and `left` or `right`. Defaults to every edge the rambler has animations for. |
| `frames`       | yes      | Sprite file names without `.sprite`. Repeat a name to hold a frame longer. |
| `frame_ms`     | no       | Milliseconds per frame, 20 to 10000. Defaults to 150. |
| `motion.speed` | no       | Pixels (terminal columns) per second, 1 to 64. Defaults to 8. |
| `motion.run_speed` | no   | Pixels per second while running, 1 to 64. Defaults to twice `speed`, at most 64. |
| `motion.jump_height` | no | How high a jump goes, in pixels, 1 to 64. Defaults to half the `height`, at least 1. |

`walk` plays while the rambler moves, and `idle` while it rests. The other
three are optional, and a rambler only does what it has an animation for:
with `run` it sets off at `run_speed` now and then, with `sleep` some rests
end in a longer nap, and with `jump` it sometimes leaps `jump_height`
pixels up while on the move. `jump` starts from its first frame at every
takeoff and holds its last frame until the rambler lands. Without `idle` a
rambler never rests, but with `sleep` it still stops for the odd nap. With
`--once`, ramblers only walk, and only along the bottom. A rambler does
not need legs: the slime hops and the ghost floats through the same `walk`
animation.

With `wall_animations` a rambler also climbs the walls, and with
`ceiling_animations` as well it crosses the ceiling, so with every edge it
can go all the way round. It always comes in along the bottom, and goes
round the corners from one edge to the next. On each edge it uses that
surface's animations, and only rests, sleeps, runs or jumps where it has
the animation for it: `idle` and `walk` fall back to each other within a set,
and a run turns into a walk when it comes round a corner onto a surface
without `run`. Jumps go away from the edge, toward the middle of the
screen, and never round a corner. The cat, for example, climbs and jumps
on the walls but only walks on the ceiling, so it only rests and sleeps on
the floor.

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

#### Wall and ceiling frames

Frames are never rotated: the engine only mirrors them and turns them
upside down. Turning the floor frames a quarter turn would leave a
climber lying on its side, lit from the wrong way, so each surface has
frames of its own and you draw the rambler as it should look there.

Wall frames are `height` pixels wide and `width` pixels tall. Draw them
on the right-hand wall heading up, with the wall on the right: the cat
climbs with its paws on the wall, and the ghost drifts up with its back to
it. They are mirrored for the left wall, and turned upside down on the way
down, so a face that reads either way up helps: the slime keeps its eyes
level, and the ghost has a flat mouth on the walls.

Ceiling frames are `width` by `height`, like floor frames, and are drawn
as they should look against the top of the screen, facing `facing`. They
are mirrored for the other direction, but never turned upside down, so
that is up to you: the cat walks upside down, while the ghost floats
upright with its head brushing the ceiling.

### Validation

`rambit validate` and `zig build test` check the manifest syntax (with the
line and column of JSON errors), required and unknown fields, value ranges,
frame dimensions (`height` by `width` for wall frames), palette symbols,
missing frame files, frame names, `edges` that lack their animations, leave
out `bottom` or have a ceiling without a wall, ids that do not match their
directory or clash with a command or another rambler, and file size
limits. Sprite files no animation uses produce a warning, as do wall or
ceiling animations no edge uses, `motion.run_speed` without a `run`
animation and `motion.jump_height` without a `jump` animation.

CI runs `zig build validate` and `zig build test` on every pull request
and every push to `main`, so a pull request shows these problems before
it is merged.
CI also lints and tests `install.sh` and the release scripts, and
cross-builds the release binaries. A separate workflow turns a version
tag into a signed release.

## How it works

- **Rendering.** Ramblers are drawn into a framebuffer of logical pixels.
  Every terminal cell shows two pixels using `▀` and `▄` with ANSI
  foreground and background colors. Only cells that changed since the last
  frame are written.
- **Movement and animation are separate.** The movement logic decides where
  to go and whether to walk, run, jump, rest or sleep; the rambler provides
  the frames. Movement advances in fixed 30 Hz steps from a seeded random
  number generator, so a run is reproducible.
- **One line round the edges.** The edges a rambler walks are unrolled
  into one line of positions, so climbing a wall is just going further
  along it. Each frame is then placed against the edge the position lies
  on, and flipped to face the way it is going.
- **Shell mode.** `rambit shell` puts the program on a pseudo-terminal,
  feeds what it writes to a terminal emulator of its own (`src/vt/`),
  lays the rambler's pixels over the emulator's cells and writes the
  cells that changed. The rambler is kept out of the rows around the
  cursor. See [How the shell mode works](#how-the-shell-mode-works).
- **Terminal handling.** Raw input, the alternate screen, a hidden cursor
  and no line wrapping while running. The terminal is restored on exit,
  including on `SIGINT`, `SIGTERM`, `SIGHUP` and panics. Leaving
  `rambit shell` also resets the keyboard modes passed on from the
  program. Resizes are picked up through `SIGWINCH`.
- **Single binary.** `build.zig` scans `ramblers/` and generates a module
  that embeds every manifest and sprite with `@embedFile`.

```text
install.sh               the installer, for curl | sh
src/
├── main.zig             CLI: play, shell, list, preview, validate
├── play.zig             the animation loop
├── shell.zig            the shell loop: pty, emulator, keys and rambler
├── Actor.zig            movement: walking, climbing, running, jumping, resting, sleeping
├── Track.zig            the edges as one line, and where frames go
├── Rambler.zig          manifest parsing and validation
├── sprite.zig           sprite file parsing
├── Source.zig           embedded files or a directory on disk
├── Diagnostics.zig      problems collected by the validator
├── Canvas.zig           the logical pixel framebuffer
├── Screen.zig           pixels to cells, and cells to escape sequences
├── compose.zig          a rambler's pixels laid over the emulator's cells
├── Display.zig          changed emulator cells to escape sequences
├── Pty.zig              a pseudo-terminal with the child process on it
├── Prefix.zig           the Ctrl-] keys, filtered out of the input
├── poll.zig             waiting on the keyboard and the pty
├── Terminal.zig         raw mode, alternate screen, signals, terminal size
├── color.zig            colors, palettes, 256-color fallback
└── vt/                  the terminal emulator
    ├── vt.zig           the package
    ├── Parser.zig       escape sequences and UTF-8, byte by byte
    ├── Emulator.zig     the program's screens, cursor, modes and replies
    ├── Grid.zig         one screen of cells and its editing operations
    ├── width.zig        how many cells a character takes up
    └── width_table.zig  generated by tools/width_table.py
tools/
├── build-release.sh     the four release binaries and their SHA256SUMS
├── release-key.sh       the release signing key: generate, embed, check
├── test-install.sh      install.sh against fake signed releases
└── width_table.py       the width table, from Python's unicodedata
```

## Not yet

- Scrollback in `rambit shell`.
- Mouse reporting, window titles and hyperlinks (OSC) in `rambit shell`.
- Combining characters and emoji sequences.
- More than one rambler at a time.
- A configurable prefix key.
