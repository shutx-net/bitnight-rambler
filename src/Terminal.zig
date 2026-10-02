//! Prepares the terminal for animation and puts it back afterwards: raw
//! keyboard input, the alternate screen, a hidden cursor and no line
//! wrapping. Resize and termination signals are turned into flags for the
//! main loop to poll, since almost nothing is safe to do in a signal handler.

const Terminal = @This();

const std = @import("std");
const Io = std.Io;
const posix = std.posix;

io: Io,
/// Input settings to restore on exit; null when stdin is not a terminal,
/// in which case keys are not read at all.
original: ?posix.termios,
/// Cleared when stdin reaches end of file.
reading_keys: bool,
previous_actions: [handled_signals.len]posix.Sigaction = undefined,

pub const Size = struct { cols: u16, rows: u16 };

pub const Key = enum { none, quit };

/// Set by the signal handlers, consumed by the main loop.
pub var resized: std.atomic.Value(bool) = .init(false);
pub var interrupted: std.atomic.Value(bool) = .init(false);

const handled_signals = [_]posix.SIG{ .WINCH, .INT, .TERM, .HUP };

const enter_sequence =
    "\x1b[?1049h" ++ // switch to the alternate screen
    "\x1b[?25l" ++ // hide the cursor
    "\x1b[?7l" ++ // disable line wrapping
    clear_sequence;

/// Resets colors first, since clearing fills the screen with the current
/// background color.
pub const clear_sequence = "\x1b[0m\x1b[2J";

const leave_sequence =
    "\x1b[0m" ++
    "\x1b[?7h" ++
    "\x1b[?25h" ++
    "\x1b[?1049l";

/// Copy of `original` for `emergencyRestore`, which cannot be handed one.
var saved_termios: ?posix.termios = null;
var active: std.atomic.Value(bool) = .init(false);

pub fn enter(io: Io, out: *Io.Writer) !Terminal {
    var t: Terminal = .{
        .io = io,
        .original = posix.tcgetattr(posix.STDIN_FILENO) catch null,
        .reading_keys = true,
    };
    if (t.original) |original| {
        var raw = original;
        // Read keys one at a time, unechoed. Ctrl-C arrives as a byte rather
        // than as SIGINT, so it goes through the same orderly exit as `q`.
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.iflag.IXON = false;
        raw.iflag.ICRNL = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;
        try posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw);
        saved_termios = original;
    }

    resized.store(false, .release);
    interrupted.store(false, .release);
    const action: posix.Sigaction = .{
        .handler = .{ .handler = handleSignal },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (handled_signals, &t.previous_actions) |sig, *previous| posix.sigaction(sig, &action, previous);

    active.store(true, .release);
    errdefer t.leave(out);
    try out.writeAll(enter_sequence);
    try out.flush();
    return t;
}

pub fn leave(t: *Terminal, out: *Io.Writer) void {
    out.writeAll(leave_sequence) catch {};
    out.flush() catch {};
    if (t.original) |original| posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original) catch {};
    for (handled_signals, &t.previous_actions) |sig, *previous| posix.sigaction(sig, previous, null);
    active.store(false, .release);
    saved_termios = null;
}

/// Restores the terminal from a panic, bypassing all buffering.
pub fn emergencyRestore() void {
    if (!active.swap(false, .acq_rel)) return;
    _ = posix.system.write(posix.STDOUT_FILENO, leave_sequence.ptr, leave_sequence.len);
    if (saved_termios) |original| posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original) catch {};
}

fn handleSignal(sig: posix.SIG) callconv(.c) void {
    switch (sig) {
        .WINCH => resized.store(true, .release),
        else => interrupted.store(true, .release),
    }
}

/// The size of the terminal on stdout, or 80×24 when it cannot be determined.
pub fn size(io: Io) Size {
    const fallback: Size = .{ .cols = 80, .rows = 24 };
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = io.operate(.{ .device_io_control = .{
        .file = .stdout(),
        .code = posix.T.IOCGWINSZ,
        .arg = &ws,
    } }) catch return fallback;
    if (result.device_io_control < 0 or ws.col == 0 or ws.row == 0) return fallback;
    return .{ .cols = ws.col, .rows = ws.row };
}

/// Waits up to `timeout_ms` for a key press. Returns early when a signal
/// arrives, so that resizes are handled promptly.
pub fn waitForKey(t: *Terminal, timeout_ms: u32) Key {
    if (t.original == null or !t.reading_keys) {
        t.io.sleep(.fromMilliseconds(timeout_ms), .awake) catch {};
        return .none;
    }
    var fds = [_]posix.pollfd{.{ .fd = posix.STDIN_FILENO, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&fds, @intCast(timeout_ms)) catch return .none;
    if (ready == 0) return .none;

    var buf: [64]u8 = undefined;
    const len = posix.read(posix.STDIN_FILENO, &buf) catch return .none;
    if (len == 0) {
        t.reading_keys = false;
        return .none;
    }
    return parseKeys(buf[0..len]);
}

fn parseKeys(bytes: []const u8) Key {
    // A lone Esc quits; Esc followed by more bytes is an escape sequence,
    // such as an arrow key, and is ignored.
    if (bytes.len == 1 and bytes[0] == 0x1b) return .quit;
    if (bytes[0] == 0x1b) return .none;
    for (bytes) |byte| switch (byte) {
        'q', 'Q', 0x03, 0x04 => return .quit, // q, Ctrl-C, Ctrl-D
        else => {},
    };
    return .none;
}

test parseKeys {
    try std.testing.expectEqual(.quit, parseKeys("q"));
    try std.testing.expectEqual(.quit, parseKeys("\x03"));
    try std.testing.expectEqual(.quit, parseKeys("\x1b"));
    try std.testing.expectEqual(.none, parseKeys("\x1b[A"));
    try std.testing.expectEqual(.none, parseKeys("x"));
}
