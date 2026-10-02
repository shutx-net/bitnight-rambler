# Bitnight Rambler

## Abstract

**Bitnight Rambler** is a small terminal-native animation engine for rendering pixel-art characters and objects that roam around the edges of a terminal window.

The project is inspired by classic command-line animations such as `sl`, but instead of displaying a single hard-coded animation, Bitnight Rambler is designed as a lightweight, extensible platform for animated terminal sprites. Its command-line interface is exposed through the `rambit` command.

Bitnight Rambler is written in **Zig** and aims to remain as self-contained as possible, with no third-party runtime dependencies. Terminal control, animation timing, sprite rendering, validation, and asset loading should be implemented using Zig's standard library and direct operating-system interfaces where necessary.

## Concept

Most modern terminals use dark color schemes and provide a grid of character cells rather than a graphical framebuffer. Bitnight Rambler treats that grid as a tiny retro display.

A *rambler* is a small animated object that can move through the terminal: a cat, dog, slime, ghost, train, spaceship, or anything else that can be represented as a compact pixel-art sprite.

Rather than relying on emoji or large ASCII art, rambler graphics are intended to resemble the compact sprites of 8-bit and 16-bit games. ANSI colors and Unicode block characters can be used to approximate a pixel framebuffer while keeping the renderer terminal-native.

For example:

```sh
rambit cat
rambit slime
rambit ghost
```

The long-term goal is for users to be able to add new ramblers through pull requests or external sprite packs without modifying the rendering engine itself.

## Design Principles

Bitnight Rambler follows a few core principles:

- **Terminal-native** — Rendering should use standard terminal capabilities such as ANSI escape sequences rather than GUI overlays or terminal-specific graphics protocols.
- **Pixel-oriented** — Ramblers should look like small game sprites rather than conventional ASCII art.
- **Extensible** — New ramblers should be data, not code. Contributors should be able to add sprites and animations without changing the engine.
- **Dependency-light** — The project should avoid third-party libraries wherever practical and favor Zig's standard library and direct system interfaces.
- **Single-binary friendly** — Built-in ramblers should be embeddable into the final executable so that `rambit` can be distributed as a standalone binary.
- **Inspectable assets** — Sprite definitions should use simple, text-based formats that are easy to review in Git diffs.
- **Portable by design** — The implementation should avoid unnecessary assumptions about a specific terminal emulator.

## Rendering Model

A terminal does not provide a true transparent overlay or z-index. Bitnight Rambler therefore cannot place a graphical layer above arbitrary terminal output in the same way that a desktop GUI can.

Instead, the renderer treats terminal cells as a small framebuffer.

A likely rendering strategy is to use Unicode half-block characters such as `▀`, combined with ANSI foreground and background colors. One terminal cell can then represent two vertically stacked logical pixels:

- the foreground color represents the upper pixel;
- the background color represents the lower pixel.

A 16×16 logical sprite can therefore be rendered in approximately 16 columns by 8 terminal rows.

The renderer should maintain a clear distinction between:

1. logical sprite pixels;
2. terminal cells;
3. animation state;
4. terminal positioning and restoration.

This allows the sprite format to remain independent of the details of ANSI rendering.

## Rambler Format

Each rambler should consist primarily of declarative asset files.

A typical rambler may contain:

```text
ramblers/
└── cat/
    ├── manifest.json
    ├── idle.sprite
    ├── walk-0.sprite
    ├── walk-1.sprite
    └── walk-2.sprite
```

The manifest describes metadata such as the rambler name, dimensions, palette, animation names, frame order, and timing.

Sprite files contain a compact textual representation of palette indices. For example:

```text
................
....11....11....
...1221..1221...
..122222222221..
.12234444332221.
.12345555443221.
.12345665443221.
..123444443221..
...1222222221...
....12....21....
...12......21...
................
```

A reserved value such as `.` may represent transparency, while other symbols refer to colors defined in the rambler's palette.

The exact format may evolve, but it should remain intentionally simple enough to edit by hand and review directly in a pull request.

## Animation

Animation is frame-based.

A rambler may define animations such as:

```text
idle
walk
run
sleep
jump
```

Only a minimal subset should be required. The engine should not assume that every rambler is an animal or even that it has legs.

Where practical, horizontal mirroring should be performed by the renderer so contributors do not need to provide separate left- and right-facing frame sets.

Movement behavior and sprite animation should remain separate concepts. The same walk animation, for example, may be reused while a rambler moves left, right, pauses, or changes speed.

## Validation

Because ramblers are intended to be contributed independently, Bitnight Rambler should include a built-in validator.

A command such as:

```sh
rambit validate ./ramblers/cat
```

or a build-time validation step should be able to detect malformed assets before they are merged.

Validation may include:

- manifest syntax;
- declared dimensions versus actual frame dimensions;
- undefined palette indices;
- inconsistent frame sizes;
- missing frame files;
- unsupported values;
- duplicate rambler identifiers;
- size limits.

The same validator can run in CI for pull requests.

## CLI

The executable is named `rambit`.

Initial commands may be intentionally small:

```sh
rambit cat
rambit slime
rambit list
rambit validate ./path/to/rambler
```

The CLI should remain simple enough that the primary interaction is still just:

```sh
rambit <rambler>
```

Additional behaviors, movement modes, animation speeds, or custom asset locations can be introduced later without changing the core sprite model.

## Implementation Direction

Bitnight Rambler is implemented in Zig.

The project should prefer:

- Zig standard library facilities;
- ANSI escape sequences;
- POSIX terminal interfaces where required;
- direct terminal-size detection;
- signal handling for resize and termination;
- deterministic frame timing;
- explicit cleanup and terminal-state restoration.

A basic implementation may initially run as a foreground animation similar to `sl`.

A more advanced mode could eventually run a shell inside a pseudo-terminal and maintain its own terminal buffer, allowing rambler sprites to coexist more cleanly with interactive shell output. That architecture is deliberately considered a later-stage feature rather than a requirement for the first implementation.

## Scope

The first useful version of Bitnight Rambler does not need to be a terminal emulator, a shell, or a general-purpose game engine.

Its core job is much smaller:

> Render tiny animated pixel-art objects in a terminal, move them around predictably, and make it easy for other people to create new ones.

Everything else should grow from that foundation.
