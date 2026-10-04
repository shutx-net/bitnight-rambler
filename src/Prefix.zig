//! The filter between the keyboard and the program in rambit shell. Bytes
//! pass through unchanged, except for the prefix key followed by a command
//! key, tmux style: `h` hides or shows the rambler, `n` switches to the next
//! one, and the prefix key pressed twice sends the prefix key itself.
//!
//! The prefix key is Ctrl-] (0x1D), telnet's escape key. Shells rarely need
//! it and, unlike tmux's Ctrl-b or screen's Ctrl-a, it takes away no readline
//! or emacs binding. Vim uses it to follow tags, which still works by
//! pressing it twice.
//!
//! A command key that means nothing is swallowed, and so is a whole escape
//! sequence after the prefix, so that the prefix followed by an arrow key or
//! an Alt combination does not leave stray bytes behind. Text pasted while
//! the program has bracketed paste mode on passes through untouched, prefix
//! keys included.
//!
//! The filter holds no allocations. What it lets through and the commands it
//! finds go to a sink, any value (usually a pointer) with these methods:
//!
//! - `forward(bytes: []const u8) void`: bytes for the program. Runs of
//!   ordinary bytes arrive as one slice, which is only valid during the call.
//! - `act(action: Action) void`: a command.

const Prefix = @This();

const std = @import("std");

/// The prefix key, Ctrl-].
pub const key: u8 = 0x1d;

pub const Action = enum {
    /// Hide or show the rambler.
    toggle,
    /// Switch to the next rambler.
    next,
};

const State = enum {
    normal,
    /// The prefix key was pressed; the next key is a command.
    armed,
    /// An escape after the prefix key, which starts an Alt combination or an
    /// escape sequence.
    escape,
    /// A control sequence or SS3 sequence after the prefix key, swallowed up
    /// to its final byte.
    sequence,
};

/// Where the forwarded bytes are relative to a bracketed paste.
const Paste = struct {
    inside: bool = false,
    /// How many bytes of the marker that would change `inside` have been
    /// seen at the end of the forwarded bytes.
    matched: u8 = 0,
};

const paste_start = "\x1b[200~";
const paste_end = "\x1b[201~";

const esc = 0x1b;

state: State = .normal,
paste: Paste = .{},

/// Filters `input`, which may end anywhere: a prefix, an escape sequence or
/// a paste marker split across calls is followed into the next one.
pub fn feed(p: *Prefix, input: []const u8, sink: anytype) void {
    // The run of bytes to forward is input[start..i]. Outside the normal
    // state it is always empty.
    var start: usize = 0;
    for (input, 0..) |byte, i| {
        switch (p.state) {
            .normal => {
                if (p.paste.inside or byte != key) {
                    p.track(byte);
                    continue;
                }
                flush(sink, input[start..i]);
                p.state = .armed;
            },
            .armed => {
                p.state = .normal;
                switch (byte) {
                    key => {
                        // Joins the run that follows.
                        p.track(byte);
                        start = i;
                        continue;
                    },
                    'h', 'H' => sink.act(.toggle),
                    'n', 'N' => sink.act(.next),
                    esc => p.state = .escape,
                    else => {},
                }
            },
            .escape => p.state = switch (byte) {
                '[', 'O' => .sequence,
                else => .normal,
            },
            .sequence => if (byte >= 0x40 and byte <= 0x7e) {
                p.state = .normal;
            },
        }
        start = i + 1;
    }
    flush(sink, input[start..]);
}

fn flush(sink: anytype, bytes: []const u8) void {
    if (bytes.len > 0) sink.forward(bytes);
}

/// Follows the bracketed paste markers through the forwarded bytes.
fn track(p: *Prefix, byte: u8) void {
    const marker = if (p.paste.inside) paste_end else paste_start;
    if (byte == marker[p.paste.matched]) {
        p.paste.matched += 1;
        if (p.paste.matched == marker.len) p.paste = .{ .inside = !p.paste.inside };
    } else {
        // The markers repeat no prefix of themselves past their first
        // byte, so a mismatch can only restart the match.
        p.paste.matched = @intFromBool(byte == marker[0]);
    }
}

const testing = std.testing;

const Recorder = struct {
    forwarded: std.ArrayList(u8) = .empty,
    forward_calls: usize = 0,
    actions: std.ArrayList(Action) = .empty,

    fn deinit(r: *Recorder) void {
        r.forwarded.deinit(testing.allocator);
        r.actions.deinit(testing.allocator);
    }

    pub fn forward(r: *Recorder, bytes: []const u8) void {
        r.forward_calls += 1;
        r.forwarded.appendSlice(testing.allocator, bytes) catch @panic("OOM");
    }

    pub fn act(r: *Recorder, action: Action) void {
        r.actions.append(testing.allocator, action) catch @panic("OOM");
    }
};

/// Feeds `chunks` one after another to one filter and checks what comes out.
fn expectFiltered(
    chunks: []const []const u8,
    forwarded: []const u8,
    actions: []const Action,
) !void {
    var p: Prefix = .{};
    var r: Recorder = .{};
    defer r.deinit();
    for (chunks) |chunk| p.feed(chunk, &r);
    try testing.expectEqualStrings(forwarded, r.forwarded.items);
    try testing.expectEqualSlices(Action, actions, r.actions.items);
}

test "plain bytes are forwarded in one call" {
    var p: Prefix = .{};
    var r: Recorder = .{};
    defer r.deinit();
    p.feed("ls -l\r\x1b[A\x03", &r);
    try testing.expectEqualStrings("ls -l\r\x1b[A\x03", r.forwarded.items);
    try testing.expectEqual(1, r.forward_calls);
    try testing.expectEqual(0, r.actions.items.len);
}

test "commands" {
    try expectFiltered(&.{"ab\x1dhcd"}, "abcd", &.{.toggle});
    try expectFiltered(&.{"\x1dH"}, "", &.{.toggle});
    try expectFiltered(&.{"\x1dn"}, "", &.{.next});
    try expectFiltered(&.{"\x1dN\x1dh"}, "", &.{ .next, .toggle });
}

test "the prefix key twice sends it" {
    try expectFiltered(&.{"\x1d\x1d"}, "\x1d", &.{});
    try expectFiltered(&.{"a\x1d\x1db"}, "a\x1db", &.{});
    try expectFiltered(&.{ "\x1d", "\x1d" }, "\x1d", &.{});
}

test "unknown command keys are swallowed" {
    try expectFiltered(&.{"\x1dx"}, "", &.{});
    try expectFiltered(&.{"\x1d\rok"}, "ok", &.{});
}

test "escape sequences after the prefix are swallowed" {
    try expectFiltered(&.{"\x1d\x1b[Az"}, "z", &.{});
    try expectFiltered(&.{"\x1d\x1b[1;5Cz"}, "z", &.{});
    try expectFiltered(&.{"\x1d\x1bOPz"}, "z", &.{});
    try expectFiltered(&.{"\x1d\x1bx"}, "", &.{});
    try expectFiltered(&.{ "\x1d\x1b", "[", "1;5", "Cz" }, "z", &.{});
}

test "the prefix split across feeds" {
    try expectFiltered(&.{ "ab\x1d", "hcd" }, "abcd", &.{.toggle});
    try expectFiltered(&.{ "\x1d", "n" }, "", &.{.next});
}

test "pastes pass through" {
    const paste = "\x1b[200~a\x1dhb\x1b[201~";
    try expectFiltered(&.{paste}, paste, &.{});
    // Only the end marker ends a paste.
    try expectFiltered(
        &.{"\x1b[200~\x1b[200~\x1dh\x1b[201\x1dn"},
        "\x1b[200~\x1b[200~\x1dh\x1b[201\x1dn",
        &.{},
    );
}

test "paste markers split across feeds" {
    try expectFiltered(
        &.{ "\x1b[2", "00~\x1d", "h\x1b", "[201", "~\x1dn" },
        "\x1b[200~\x1dh\x1b[201~",
        &.{.next},
    );
    // A mismatch restarts the match at an escape.
    try expectFiltered(
        &.{ "\x1b[20\x1b", "[200~\x1dh" },
        "\x1b[20\x1b[200~\x1dh",
        &.{},
    );
}

test "the prefix works again after a paste" {
    try expectFiltered(
        &.{"\x1b[200~x\x1b[201~\x1dhy"},
        "\x1b[200~x\x1b[201~y",
        &.{.toggle},
    );
}

test "a paste marker after the prefix is not followed" {
    try expectFiltered(&.{"\x1d\x1b[200~\x1dh"}, "", &.{.toggle});
}
