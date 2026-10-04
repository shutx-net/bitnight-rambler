//! `rambit shell`: a shell, or any other command, on a pseudo-terminal with
//! a rambler roaming over it. It works like tmux: the child writes to a pty,
//! an `Emulator` keeps its screen, the rambler is composited over that
//! screen, and only the cells that changed reach the real terminal. Keys go
//! back to the child as they are, apart from the prefix commands (see
//! `Prefix`), so the real terminal is told to encode them the way the child
//! asked for: its keyboard modes are mirrored.
//!
//! The rambler stays out of the cursor's row, and out of a few rows around
//! it while the user is typing, so that it never covers what is being typed.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const Environ = std.process.Environ;
const posix = std.posix;
const Actor = @import("Actor.zig");
const Canvas = @import("Canvas.zig");
const Display = @import("Display.zig");
const Prefix = @import("Prefix.zig");
const Pty = @import("Pty.zig");
const Rambler = @import("Rambler.zig");
const Terminal = @import("Terminal.zig");
const color = @import("color.zig");
const compose = @import("compose.zig").compose;
const play = @import("play.zig");
const poll = @import("poll.zig");
const Emulator = @import("vt/Emulator.zig");
const Grid = @import("vt/Grid.zig");

pub const Options = struct {
    /// Prefix n cycles through these, starting with the first. Not empty.
    ramblers: []const Rambler,
    seed: u64,
    color_mode: color.Mode,
    /// The command to run; see `command`.
    argv: []const []const u8,
    /// Its environment; see `childEnvironment`.
    environ: *const Environ.Map,
};

/// Set in the child's environment, so that rambit can refuse to run inside
/// itself.
pub const nesting_variable = "RAMBIT_SHELL";

/// The shell when there is no $SHELL.
const default_shell = "/bin/sh";

/// Rows kept clear above and below the cursor's while the user is typing.
const typing_margin = 2;
/// How long after a key press the user still counts as typing.
const typing_ns = 2 * std.time.ns_per_s;

/// Input waiting for the child beyond which no more is read, for when the
/// child stops reading.
const max_pending_input = 1024 * 1024;
/// Most reads from the pty between two frames, 64 KiB each.
const max_reads = 16;
/// How long to wait for input while nothing needs drawing.
const idle_timeout_ms = 500;

/// The environment for the child: `parent` with TERM=xterm-256color, which
/// is what the emulator implements (bce, ech, rep, indn and rin, italics,
/// the 1049 alternate screen, ESC ( 0 line drawing) and which matches the
/// keys of the xterm-compatible terminal the raw input comes from. LINES and
/// COLUMNS would override the pty's size, so they go. COLORTERM passes
/// through, since colors are passed through as they are.
pub fn childEnvironment(arena: Allocator, parent: *const Environ.Map) Allocator.Error!Environ.Map {
    var env = try parent.clone(arena);
    try env.put("TERM", "xterm-256color");
    try env.put(nesting_variable, "1");
    _ = env.orderedRemove("LINES");
    _ = env.orderedRemove("COLUMNS");
    return env;
}

/// What to run: `args` if there are any, otherwise the user's shell.
pub fn command(arena: Allocator, environ: *const Environ.Map, args: []const []const u8) Allocator.Error![]const []const u8 {
    if (args.len > 0) return args;
    const program = environ.get("SHELL") orelse "";
    return arena.dupe([]const u8, &.{if (program.len > 0) program else default_shell});
}

/// The canvas rows to keep the rambler out of: those of the cursor's row,
/// and `typing_margin` rows either side while the user is typing. They may
/// reach past the canvas.
fn keepOut(cursor_row: u16, typing: bool) Actor.KeepOut {
    const margin: i32 = if (typing) typing_margin else 0;
    const row: i32 = cursor_row;
    return .{ .top = 2 * (row - margin), .bottom = 2 * (row + 1 + margin) };
}

/// The keyboard modes the real terminal has been put in for the child.
const Mirrored = struct {
    app_cursor: bool = false,
    app_keypad: bool = false,
    bracketed_paste: bool = false,
};

/// Each mirrored mode with the sequences that turn it on and off.
const mirrored_modes = .{
    .{ "app_cursor", "\x1b[?1h", "\x1b[?1l" },
    .{ "app_keypad", "\x1b=", "\x1b>" },
    .{ "bracketed_paste", "\x1b[?2004h", "\x1b[?2004l" },
};

/// Puts the real terminal in the keyboard modes the child has set, writing
/// only the changes. Input is forwarded raw, so the terminal must encode
/// keys the way the child expects.
fn mirrorModes(w: *Writer, shown: *Mirrored, modes: Emulator.Modes) Writer.Error!void {
    inline for (mirrored_modes) |mode| {
        const on = @field(modes, mode[0]);
        if (@field(shown, mode[0]) != on) {
            try w.writeAll(if (on) mode[1] else mode[2]);
            @field(shown, mode[0]) = on;
        }
    }
}

/// The sink for `Prefix`: collects the input for the child and counts the
/// commands in one read.
const Keys = struct {
    gpa: Allocator,
    to_child: *std.ArrayList(u8),
    /// Toggles since the last `next`, or in all if there was none.
    toggles: u32 = 0,
    nexts: u32 = 0,
    /// Whether any input went to the child.
    pressed: bool = false,

    /// What the commands do to a rambler that is `visible`.
    const Outcome = struct {
        visible: bool,
        /// Whether a rambler comes in afresh.
        restart: bool,
    };

    /// Drops the input when out of memory.
    pub fn forward(k: *Keys, bytes: []const u8) void {
        k.pressed = true;
        k.to_child.appendSlice(k.gpa, bytes) catch {};
    }

    pub fn act(k: *Keys, action: Prefix.Action) void {
        switch (action) {
            .toggle => k.toggles += 1,
            .next => {
                k.nexts += 1;
                k.toggles = 0;
            },
        }
    }

    /// A `next` brings the next rambler in, shown; a toggle that shows a
    /// rambler brings it in afresh as well.
    fn outcome(k: Keys, visible: bool) Outcome {
        const flipped = k.toggles % 2 == 1;
        if (k.nexts > 0) return .{ .visible = !flipped, .restart = true };
        return .{ .visible = visible != flipped, .restart = flipped and !visible };
    }
};

/// Runs `options.argv` on a pty in this terminal until it exits, and returns
/// its exit code. Spawn errors are returned before the terminal is touched.
pub fn run(gpa: Allocator, io: Io, options: Options) !u8 {
    std.debug.assert(options.ramblers.len > 0);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();

    // The user's settings, before `Terminal` makes them raw.
    const original = posix.tcgetattr(posix.STDIN_FILENO) catch null;
    const size = Terminal.size(io);
    // Spawned first, so that a command that cannot run is reported on the
    // normal screen.
    var pty: Pty = try .spawn(arena_state.allocator(), io, .{
        .argv = options.argv,
        .environ = options.environ,
        .size = .{ .cols = size.cols, .rows = size.rows },
        .termios = original,
    });
    errdefer {
        pty.hangUp();
        _ = reap(io, &pty);
    }

    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &out_buffer);
    const out = &stdout_writer.interface;
    var terminal: Terminal = try .enterShell(io, out);
    defer terminal.leave(out);

    var state: State = try .init(gpa, io, out, &options, &pty, size);
    defer state.deinit();
    const status = try state.loop();
    const final = status orelse reap(io, &pty);
    pty.close();
    return final.exitCode();
}

/// Collects the child after its pty has closed or rambit has been told to
/// stop. A child whose pty closed is on its way out; one that is still
/// around after a while is hung up on, and in the end killed, so that rambit
/// always exits.
fn reap(io: Io, pty: *Pty) Pty.Status {
    if (waitAWhile(io, pty)) |status| return status;
    pty.hangUp();
    if (waitAWhile(io, pty)) |status| return status;
    _ = posix.system.kill(pty.pid, .KILL);
    return pty.wait();
}

/// Waits up to about two seconds for the child to exit.
fn waitAWhile(io: Io, pty: *Pty) ?Pty.Status {
    for (0..200) |_| {
        if (pty.tryWait()) |status| return status;
        io.sleep(.fromMilliseconds(10), .awake) catch {};
    }
    return pty.tryWait();
}

/// Everything the loop works with.
const State = struct {
    gpa: Allocator,
    io: Io,
    out: *Writer,
    options: *const Options,
    pty: *Pty,
    emulator: Emulator,
    canvas: Canvas,
    display: Display,
    /// The emulator's screen with the rambler over it.
    frame: []Grid.Cell,
    /// Seeds the ramblers after the first.
    prng: std.Random.DefaultPrng,
    actor: Actor,
    /// Which of `options.ramblers` the actor is.
    current: usize = 0,
    prefix: Prefix = .{},
    /// Input and replies waiting to be written to the child.
    to_child: std.ArrayList(u8) = .empty,
    mirrored: Mirrored = .{},
    last_key: ?Io.Timestamp = null,
    /// Whether the emulator's screen changed since the last frame.
    dirty: bool = true,
    visible: bool = true,
    master_open: bool = true,
    stdin_open: bool = true,
    next_tick: Io.Timestamp,

    fn init(
        gpa: Allocator,
        io: Io,
        out: *Writer,
        options: *const Options,
        pty: *Pty,
        size: Terminal.Size,
    ) Allocator.Error!State {
        var emulator: Emulator = try .init(gpa, size.cols, size.rows);
        errdefer emulator.deinit();
        var canvas: Canvas = try .init(gpa, size.cols, 2 * size.rows);
        errdefer canvas.deinit(gpa);
        var display: Display = try .init(gpa, size.cols, size.rows, options.color_mode);
        errdefer display.deinit(gpa);
        const frame = try gpa.alloc(Grid.Cell, @as(usize, size.cols) * size.rows);
        return .{
            .gpa = gpa,
            .io = io,
            .out = out,
            .options = options,
            .pty = pty,
            .emulator = emulator,
            .canvas = canvas,
            .display = display,
            .frame = frame,
            .prng = .init(options.seed),
            // The same seed gives the same stroll as `rambit <name> --seed`.
            .actor = .init(&options.ramblers[0], .roam, options.seed, .{ .width = canvas.width, .height = canvas.height }),
            .next_tick = Io.Clock.awake.now(io),
        };
    }

    fn deinit(s: *State) void {
        s.emulator.deinit();
        s.canvas.deinit(s.gpa);
        s.display.deinit(s.gpa);
        s.gpa.free(s.frame);
        s.to_child.deinit(s.gpa);
    }

    /// Runs until the child exits or rambit is told to stop. Returns the
    /// child's status if it has been collected.
    fn loop(s: *State) !?Pty.Status {
        var buf: [64 * 1024]u8 = undefined;
        while (true) {
            if (Terminal.interrupted.load(.acquire)) {
                s.pty.hangUp();
                return null;
            }
            if (Terminal.resized.swap(false, .acq_rel)) try s.resize(Terminal.size(s.io));
            const now = Io.Clock.awake.now(s.io);
            if (now.nanoseconds >= s.next_tick.nanoseconds) try s.tick(now);
            if (!s.master_open) return null;
            if (s.pty.tryWait()) |status| return status;

            var interests: [2]poll.Interest = undefined;
            var ready: [2]poll.Ready = undefined;
            var count: usize = 0;
            const reading_keys = s.stdin_open and s.to_child.items.len < max_pending_input;
            if (reading_keys) {
                interests[count] = .{ .fd = posix.STDIN_FILENO, .read = true };
                count += 1;
            }
            const master = count;
            interests[master] = .{ .fd = s.pty.master, .read = true, .write = s.to_child.items.len > 0 };
            count += 1;
            try poll.wait(interests[0..count], &ready, s.timeout(Io.Clock.awake.now(s.io)));

            if (reading_keys and ready[0].read) s.readKeys(&buf);
            if (ready[master].read) try s.readChild(&buf);
            // Written straight away: the pty takes what it can without
            // blocking, and the poll waits for room for the rest.
            if (s.to_child.items.len > 0) s.writeChild();
        }
    }

    /// Milliseconds to wait for input before the next frame is due.
    fn timeout(s: *const State, now: Io.Timestamp) i32 {
        if (!s.visible and !s.dirty) return idle_timeout_ms;
        const ns = s.next_tick.nanoseconds - now.nanoseconds;
        if (ns <= 0) return 0;
        const ms = @divFloor(ns + std.time.ns_per_ms - 1, std.time.ns_per_ms);
        return @intCast(@min(ms, idle_timeout_ms));
    }

    fn rambler(s: *const State) *const Rambler {
        return &s.options.ramblers[s.current];
    }

    fn field(s: *const State) Actor.Field {
        return .{ .width = s.canvas.width, .height = s.canvas.height };
    }

    fn isTyping(s: *const State, now: Io.Timestamp) bool {
        const last = s.last_key orelse return false;
        return now.nanoseconds - last.nanoseconds < typing_ns;
    }

    /// Advances the rambler to `now` and draws the frame, which with the
    /// rambler hidden only happens when the screen changed.
    fn tick(s: *State, now: Io.Timestamp) Writer.Error!void {
        const step: Io.Duration = .fromMicroseconds(play.tick_us);
        if (s.visible) {
            s.actor.setKeepOut(keepOut(s.emulator.cursor.y, s.isTyping(now)));
            var ticks: u32 = 0;
            while (s.next_tick.nanoseconds <= now.nanoseconds) : (ticks += 1) {
                if (ticks == play.max_catch_up_ticks) {
                    s.next_tick = now;
                    break;
                }
                s.actor.update(play.tick_us);
                s.next_tick = s.next_tick.addDuration(step);
            }
            const f = s.actor.frame();
            s.canvas.clear();
            s.canvas.drawSprite(f.sprite, &s.rambler().palette, f.x, f.y, f.flip);
        } else {
            s.next_tick = now.addDuration(step);
            if (!s.dirty) return;
        }
        compose(s.frame, s.emulator.screen(), if (s.visible) &s.canvas else null);
        try s.display.draw(s.out, s.frame, .{
            .x = s.emulator.cursor.x,
            .y = s.emulator.cursor.y,
            .visible = s.emulator.modes.cursor_visible,
        });
        try s.out.flush();
        s.dirty = false;
    }

    fn resize(s: *State, size: Terminal.Size) !void {
        try s.emulator.resize(size.cols, size.rows);
        s.pty.resize(.{ .cols = size.cols, .rows = size.rows });
        try s.canvas.resize(s.gpa, size.cols, 2 * size.rows);
        s.frame = try s.gpa.realloc(s.frame, @as(usize, size.cols) * size.rows);
        try s.display.resize(s.gpa, size.cols, size.rows);
        try s.out.writeAll(Terminal.clear_sequence);
        s.actor.resize(s.field());
        s.dirty = true;
    }

    /// Reads the keyboard and passes what it gets through the prefix filter.
    fn readKeys(s: *State, buf: []u8) void {
        const len = posix.read(posix.STDIN_FILENO, buf) catch |err| switch (err) {
            error.WouldBlock => return,
            else => 0,
        };
        if (len == 0) {
            s.stdin_open = false;
            return;
        }
        var keys: Keys = .{ .gpa = s.gpa, .to_child = &s.to_child };
        s.prefix.feed(buf[0..len], &keys);
        if (keys.pressed) s.last_key = Io.Clock.awake.now(s.io);

        const outcome = keys.outcome(s.visible);
        s.current = (s.current + keys.nexts) % s.options.ramblers.len;
        if (outcome.restart) {
            s.actor = .init(s.rambler(), .roam, s.prng.random().int(u64), s.field());
        }
        if (outcome.visible != s.visible) s.dirty = true;
        s.visible = outcome.visible;
    }

    /// Drains what the child wrote into the emulator, then queues the
    /// emulator's replies and passes its keyboard modes and bell on.
    fn readChild(s: *State, buf: []u8) !void {
        reads: for (0..max_reads) |_| switch (s.pty.read(buf)) {
            .data => |len| {
                s.emulator.feed(buf[0..len]);
                s.dirty = true;
                try s.to_child.appendSlice(s.gpa, s.emulator.replies());
                s.emulator.clearReplies();
            },
            .would_block => break :reads,
            .closed => {
                s.master_open = false;
                break :reads;
            },
        };
        try mirrorModes(s.out, &s.mirrored, s.emulator.modes);
        if (s.emulator.bell) {
            try s.out.writeByte(0x07);
            s.emulator.bell = false;
        }
        try s.out.flush();
    }

    fn writeChild(s: *State) void {
        const written = s.pty.write(s.to_child.items) catch {
            s.master_open = false;
            return;
        };
        const rest = s.to_child.items.len - written;
        std.mem.copyForwards(u8, s.to_child.items[0..rest], s.to_child.items[written..]);
        s.to_child.shrinkRetainingCapacity(rest);
    }
};

const testing = std.testing;

test childEnvironment {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parent: Environ.Map = .init(arena);
    try parent.put("TERM", "screen");
    try parent.put("PATH", "/usr/bin:/bin");
    try parent.put("COLORTERM", "truecolor");
    try parent.put("LINES", "24");
    try parent.put("COLUMNS", "80");

    const env = try childEnvironment(arena, &parent);
    try testing.expectEqualStrings("xterm-256color", env.get("TERM").?);
    try testing.expectEqualStrings("1", env.get(nesting_variable).?);
    try testing.expectEqualStrings("/usr/bin:/bin", env.get("PATH").?);
    try testing.expectEqualStrings("truecolor", env.get("COLORTERM").?);
    try testing.expectEqual(null, env.get("LINES"));
    try testing.expectEqual(null, env.get("COLUMNS"));
    // The parent is left alone.
    try testing.expectEqualStrings("screen", parent.get("TERM").?);
    try testing.expectEqual(null, parent.get(nesting_variable));
}

test command {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environ: Environ.Map = .init(arena);

    const no_args: []const []const u8 = &.{};
    try testing.expectEqualDeep(@as([]const []const u8, &.{default_shell}), try command(arena, &environ, no_args));
    try environ.put("SHELL", "");
    try testing.expectEqualDeep(@as([]const []const u8, &.{default_shell}), try command(arena, &environ, no_args));
    try environ.put("SHELL", "/bin/zsh");
    try testing.expectEqualDeep(@as([]const []const u8, &.{"/bin/zsh"}), try command(arena, &environ, no_args));
    const args: []const []const u8 = &.{ "vim", "-u", "NONE" };
    try testing.expectEqual(args, try command(arena, &environ, args));
}

test keepOut {
    try testing.expectEqual(Actor.KeepOut{ .top = 0, .bottom = 2 }, keepOut(0, false));
    try testing.expectEqual(Actor.KeepOut{ .top = 20, .bottom = 22 }, keepOut(10, false));
    try testing.expectEqual(Actor.KeepOut{ .top = 16, .bottom = 26 }, keepOut(10, true));
    try testing.expectEqual(Actor.KeepOut{ .top = -4, .bottom = 6 }, keepOut(0, true));
}

test mirrorModes {
    var buf: [64]u8 = undefined;
    var shown: Mirrored = .{};
    var w: Writer = .fixed(&buf);

    try mirrorModes(&w, &shown, .{});
    try testing.expectEqualStrings("", w.buffered());

    try mirrorModes(&w, &shown, .{ .app_cursor = true, .app_keypad = true, .bracketed_paste = true });
    try testing.expectEqualStrings("\x1b[?1h\x1b=\x1b[?2004h", w.buffered());
    try testing.expectEqual(Mirrored{ .app_cursor = true, .app_keypad = true, .bracketed_paste = true }, shown);
    w = .fixed(&buf);
    try mirrorModes(&w, &shown, .{ .app_cursor = true, .app_keypad = true, .bracketed_paste = true });
    try testing.expectEqualStrings("", w.buffered());

    try mirrorModes(&w, &shown, .{ .app_keypad = true });
    try testing.expectEqualStrings("\x1b[?1l\x1b[?2004l", w.buffered());
    w = .fixed(&buf);
    try mirrorModes(&w, &shown, .{});
    try testing.expectEqualStrings("\x1b>", w.buffered());
    try testing.expectEqual(Mirrored{}, shown);
}

test Keys {
    var to_child: std.ArrayList(u8) = .empty;
    defer to_child.deinit(testing.allocator);
    var prefix: Prefix = .{};

    var keys: Keys = .{ .gpa = testing.allocator, .to_child = &to_child };
    prefix.feed("ls\x1dh -l\r", &keys);
    try testing.expectEqualStrings("ls -l\r", to_child.items);
    try testing.expect(keys.pressed);
    try testing.expectEqual(1, keys.toggles);
    try testing.expectEqual(0, keys.nexts);

    // Commands alone are not typing.
    keys = .{ .gpa = testing.allocator, .to_child = &to_child };
    prefix.feed("\x1dh\x1dn\x1dn\x1dh", &keys);
    try testing.expectEqualStrings("ls -l\r", to_child.items);
    try testing.expect(!keys.pressed);
    try testing.expectEqual(2, keys.nexts);
    try testing.expectEqual(1, keys.toggles);
}

test "Keys.outcome" {
    var to_child: std.ArrayList(u8) = .empty;
    const none: Keys = .{ .gpa = testing.allocator, .to_child = &to_child };
    try testing.expectEqual(Keys.Outcome{ .visible = true, .restart = false }, none.outcome(true));
    try testing.expectEqual(Keys.Outcome{ .visible = false, .restart = false }, none.outcome(false));

    var toggle = none;
    toggle.toggles = 1;
    try testing.expectEqual(Keys.Outcome{ .visible = false, .restart = false }, toggle.outcome(true));
    // Shown again, it comes in afresh.
    try testing.expectEqual(Keys.Outcome{ .visible = true, .restart = true }, toggle.outcome(false));
    toggle.toggles = 2;
    try testing.expectEqual(Keys.Outcome{ .visible = false, .restart = false }, toggle.outcome(false));

    // `next` shows the next rambler; a toggle after it hides it again.
    var next = none;
    next.nexts = 1;
    try testing.expectEqual(Keys.Outcome{ .visible = true, .restart = true }, next.outcome(false));
    next.toggles = 1;
    try testing.expectEqual(Keys.Outcome{ .visible = false, .restart = true }, next.outcome(true));
}

// No test may call `run`: the test runner talks to the build system over
// stdout. This at least compiles it; the end-to-end check runs it in a pty.
test {
    _ = &run;
}
