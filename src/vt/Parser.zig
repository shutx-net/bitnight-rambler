//! Splits what a program writes to its terminal into printable characters,
//! control characters and escape sequences, one byte at a time. It follows
//! Paul Williams' state machine for DEC terminals
//! (https://vt100.net/emu/dec_ansi_parser), decodes UTF-8 in the ground state
//! and never treats bytes 0x80 to 0xFF as C1 controls, as on a UTF-8 terminal.
//!
//! OSC, DCS, SOS, PM and APC strings are swallowed whole: window titles,
//! hyperlinks, color queries and the like are ignored.
//!
//! The parser holds no allocations and knows nothing of the screen. What it
//! finds goes to a handler, any value (usually a pointer) with these methods:
//!
//! - `print(cp: u21) void`: a character to draw. Malformed UTF-8 arrives as
//!   U+FFFD.
//! - `execute(c: u8) void`: a C0 control character such as BEL, BS or LF.
//! - `csiDispatch(csi: Csi) void`: a control sequence, `ESC [ ... final`.
//! - `escDispatch(esc: Esc) void`: any other escape sequence, `ESC ... final`.
//!   A string terminator `ESC \` arrives here with final `\`.
//!
//! The slices in `Csi` and `Esc` point into the parser and are only valid
//! during the call.

const Parser = @This();

const std = @import("std");

pub const max_params = 16;
pub const max_intermediates = 2;

const replacement: u21 = 0xFFFD;

const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    /// The body of an OSC, DCS, SOS, PM or APC string, which is ignored.
    string,
};

state: State = .ground,

/// The code point decoded so far from a UTF-8 sequence.
utf8_cp: u21 = 0,
/// How many continuation bytes the UTF-8 sequence still needs.
utf8_need: u2 = 0,
/// The range the next continuation byte must fall in, which is narrower than
/// 0x80 to 0xBF after some lead bytes so that overlong encodings, surrogates
/// and code points past U+10FFFF are rejected.
utf8_lower: u8 = 0x80,
utf8_upper: u8 = 0xBF,

params: [max_params]u16 = undefined,
/// The number of parameters seen so far, the one being parsed included, or
/// 0 when no parameter character has been seen. It stops at max_params + 1:
/// parameters past max_params are parsed but dropped.
param_count: u8 = 0,
/// Bit i is set when params[i] followed a ':' rather than a ';'.
sub: u16 = 0,
intermediates: [max_intermediates]u8 = undefined,
/// The number of intermediates seen. In an escape sequence it may run past
/// max_intermediates, and such a sequence is dropped.
intermediate_count: u8 = 0,
/// The private marker '<', '=', '>' or '?' of a control sequence, or 0.
marker: u8 = 0,

/// A control sequence: `ESC [`, an optional private marker, parameters
/// separated by ';' or ':', intermediates from 0x20 to 0x2F and a final byte.
pub const Csi = struct {
    marker: u8,
    intermediates: []const u8,
    /// Empty when no parameter character was seen; otherwise one more than
    /// the number of separators (up to max_params), with empty ones as 0.
    params: []const u16,
    /// Bit i is set when params[i] is a sub-parameter, i.e. followed a ':'.
    sub: u16,
    final: u8,

    /// Parameter `i`, or `default` when it is missing or 0.
    pub fn param(c: Csi, i: usize, default: u16) u16 {
        return if (i < c.params.len and c.params[i] != 0) c.params[i] else default;
    }

    /// Whether parameter `i` followed a ':'.
    pub fn isSub(c: Csi, i: usize) bool {
        return i < c.params.len and c.sub & (@as(u16, 1) << @intCast(i)) != 0;
    }
};

/// An escape sequence other than a control sequence or a string:
/// `ESC`, intermediates from 0x20 to 0x2F and a final byte.
pub const Esc = struct {
    intermediates: []const u8,
    final: u8,
};

/// Parses `bytes`, calling `handler` for what they hold. A sequence split
/// between calls carries over to the next one.
pub fn feed(p: *Parser, bytes: []const u8, handler: anytype) void {
    for (bytes) |byte| p.step(byte, handler);
}

/// Parses one byte.
pub fn step(p: *Parser, byte: u8, handler: anytype) void {
    if (p.state == .ground) return p.ground(byte, handler);

    // Wherever the parser is, CAN and SUB cancel the sequence and ESC starts
    // a new one; ESC also ends a string.
    switch (byte) {
        0x18, 0x1A => {
            handler.execute(byte);
            p.state = .ground;
            return;
        },
        0x1B => return p.enterEscape(),
        else => {},
    }

    switch (p.state) {
        .ground => unreachable,
        .escape => switch (byte) {
            0x00...0x1F => handler.execute(byte),
            0x20...0x2F => p.collectEsc(byte),
            '[' => p.state = .csi_entry,
            ']', 'P', 'X', '^', '_' => p.state = .string,
            0x30...0x4F, 0x51...0x57, 0x59...0x5A, 0x5C, 0x60...0x7E => p.dispatchEsc(byte, handler),
            0x7F...0xFF => {},
        },
        .escape_intermediate => switch (byte) {
            0x00...0x1F => handler.execute(byte),
            0x20...0x2F => p.collectEsc(byte),
            0x30...0x7E => p.dispatchEsc(byte, handler),
            0x7F...0xFF => {},
        },
        .csi_entry => switch (byte) {
            0x00...0x1F => handler.execute(byte),
            0x20...0x2F => p.collectCsi(byte),
            '0'...'9', ':', ';' => {
                p.paramByte(byte);
                p.state = .csi_param;
            },
            0x3C...0x3F => {
                p.marker = byte;
                p.state = .csi_param;
            },
            0x40...0x7E => p.dispatchCsi(byte, handler),
            0x7F...0xFF => {},
        },
        .csi_param => switch (byte) {
            0x00...0x1F => handler.execute(byte),
            0x20...0x2F => p.collectCsi(byte),
            '0'...'9', ':', ';' => p.paramByte(byte),
            0x3C...0x3F => p.state = .csi_ignore,
            0x40...0x7E => p.dispatchCsi(byte, handler),
            0x7F...0xFF => {},
        },
        .csi_intermediate => switch (byte) {
            0x00...0x1F => handler.execute(byte),
            0x20...0x2F => p.collectCsi(byte),
            0x30...0x3F => p.state = .csi_ignore,
            0x40...0x7E => p.dispatchCsi(byte, handler),
            0x7F...0xFF => {},
        },
        .csi_ignore => switch (byte) {
            0x00...0x1F => handler.execute(byte),
            0x40...0x7E => p.state = .ground,
            else => {},
        },
        .string => if (byte == 0x07) {
            p.state = .ground;
        },
    }
}

fn ground(p: *Parser, byte: u8, handler: anytype) void {
    if (p.utf8_need != 0) {
        if (byte >= p.utf8_lower and byte <= p.utf8_upper) {
            p.utf8_cp = p.utf8_cp << 6 | (byte & 0x3F);
            p.utf8_need -= 1;
            p.utf8_lower = 0x80;
            p.utf8_upper = 0xBF;
            if (p.utf8_need == 0) handler.print(p.utf8_cp);
            return;
        }
        // The sequence is cut short: replace it, then take the byte afresh.
        p.utf8_need = 0;
        p.utf8_lower = 0x80;
        p.utf8_upper = 0xBF;
        handler.print(replacement);
    }
    switch (byte) {
        0x00...0x1A, 0x1C...0x1F => handler.execute(byte),
        0x1B => p.enterEscape(),
        0x20...0x7E => handler.print(byte),
        0x7F => {},
        0xC2...0xDF => p.utf8Start(byte & 0x1F, 1),
        0xE0...0xEF => {
            p.utf8Start(byte & 0x0F, 2);
            if (byte == 0xE0) p.utf8_lower = 0xA0; // no overlong forms
            if (byte == 0xED) p.utf8_upper = 0x9F; // no surrogates
        },
        0xF0...0xF4 => {
            p.utf8Start(byte & 0x07, 3);
            if (byte == 0xF0) p.utf8_lower = 0x90; // no overlong forms
            if (byte == 0xF4) p.utf8_upper = 0x8F; // nothing past U+10FFFF
        },
        0x80...0xC1, 0xF5...0xFF => handler.print(replacement),
    }
}

fn utf8Start(p: *Parser, bits: u8, need: u2) void {
    p.utf8_cp = bits;
    p.utf8_need = need;
}

fn enterEscape(p: *Parser) void {
    p.param_count = 0;
    p.sub = 0;
    p.intermediate_count = 0;
    p.marker = 0;
    p.state = .escape;
}

fn collectEsc(p: *Parser, byte: u8) void {
    if (p.intermediate_count < max_intermediates) p.intermediates[p.intermediate_count] = byte;
    p.intermediate_count +|= 1;
    p.state = .escape_intermediate;
}

fn collectCsi(p: *Parser, byte: u8) void {
    if (p.intermediate_count == max_intermediates) {
        p.state = .csi_ignore;
        return;
    }
    p.intermediates[p.intermediate_count] = byte;
    p.intermediate_count += 1;
    p.state = .csi_intermediate;
}

/// Takes a digit, ';' or ':' of the parameters.
fn paramByte(p: *Parser, byte: u8) void {
    if (p.param_count == 0) {
        p.params[0] = 0;
        p.param_count = 1;
    }
    if (byte == ';' or byte == ':') {
        if (p.param_count < max_params) {
            p.params[p.param_count] = 0;
            if (byte == ':') p.sub |= @as(u16, 1) << @intCast(p.param_count);
        }
        if (p.param_count <= max_params) p.param_count += 1;
        return;
    }
    if (p.param_count > max_params) return;
    const current = &p.params[p.param_count - 1];
    const value = @as(u32, current.*) * 10 + (byte - '0');
    current.* = @intCast(@min(value, std.math.maxInt(u16)));
}

fn dispatchEsc(p: *Parser, final: u8, handler: anytype) void {
    p.state = .ground;
    if (p.intermediate_count > max_intermediates) return;
    handler.escDispatch(Esc{
        .intermediates = p.intermediates[0..p.intermediate_count],
        .final = final,
    });
}

fn dispatchCsi(p: *Parser, final: u8, handler: anytype) void {
    p.state = .ground;
    handler.csiDispatch(Csi{
        .marker = p.marker,
        .intermediates = p.intermediates[0..p.intermediate_count],
        .params = p.params[0..@min(p.param_count, max_params)],
        .sub = p.sub,
        .final = final,
    });
}

const testing = std.testing;

/// What a handler was called with, copied out of the parser.
const Event = union(enum) {
    print: u21,
    execute: u8,
    csi: struct {
        marker: u8 = 0,
        intermediates: [max_intermediates]u8 = @splat(0),
        intermediate_count: usize = 0,
        params: [max_params]u16 = @splat(0),
        param_count: usize = 0,
        sub: u16 = 0,
        final: u8,
    },
    esc: struct {
        intermediates: [max_intermediates]u8 = @splat(0),
        intermediate_count: usize = 0,
        final: u8,
    },

    fn seq(marker: u8, intermediates: []const u8, params: []const u16, sub: u16, final: u8) Event {
        var e: Event = .{ .csi = .{ .marker = marker, .sub = sub, .final = final } };
        @memcpy(e.csi.intermediates[0..intermediates.len], intermediates);
        e.csi.intermediate_count = intermediates.len;
        @memcpy(e.csi.params[0..params.len], params);
        e.csi.param_count = params.len;
        return e;
    }

    fn escape(intermediates: []const u8, final: u8) Event {
        var e: Event = .{ .esc = .{ .final = final } };
        @memcpy(e.esc.intermediates[0..intermediates.len], intermediates);
        e.esc.intermediate_count = intermediates.len;
        return e;
    }
};

const Recorder = struct {
    events: std.ArrayList(Event) = .empty,

    fn add(r: *Recorder, e: Event) void {
        r.events.append(testing.allocator, e) catch @panic("OOM");
    }

    pub fn print(r: *Recorder, cp: u21) void {
        r.add(.{ .print = cp });
    }

    pub fn execute(r: *Recorder, c: u8) void {
        r.add(.{ .execute = c });
    }

    pub fn csiDispatch(r: *Recorder, c: Csi) void {
        r.add(.seq(c.marker, c.intermediates, c.params, c.sub, c.final));
    }

    pub fn escDispatch(r: *Recorder, e: Esc) void {
        r.add(.escape(e.intermediates, e.final));
    }
};

/// Feeds `chunks` one after another to a new parser and checks what comes out.
fn expectEvents(chunks: []const []const u8, expected: []const Event) !void {
    var p: Parser = .{};
    var r: Recorder = .{};
    defer r.events.deinit(testing.allocator);
    for (chunks) |chunk| p.feed(chunk, &r);
    try testing.expectEqualDeep(expected, r.events.items);
}

fn prints(comptime s: []const u8) [s.len]Event {
    var events: [s.len]Event = undefined;
    for (s, &events) |c, *e| e.* = .{ .print = c };
    return events;
}

test "ascii prints" {
    try expectEvents(&.{"Hi, ~!"}, &prints("Hi, ~!"));
    try expectEvents(&.{"a\x7fb"}, &prints("ab"));
}

test "utf-8 decodes" {
    try expectEvents(&.{"é あ 😀"}, &.{
        .{ .print = 0xE9 },    .{ .print = ' ' },
        .{ .print = 0x3042 },  .{ .print = ' ' },
        .{ .print = 0x1F600 },
    });
    try expectEvents(&.{ "\xE3", "\x81", "\x82" }, &.{.{ .print = 0x3042 }});
    try expectEvents(&.{ "\xF0\x9F", "\x98\x80" }, &.{.{ .print = 0x1F600 }});
    try expectEvents(&.{"\xF4\x8F\xBF\xBF"}, &.{.{ .print = 0x10FFFF }});
}

test "invalid utf-8 prints replacement characters" {
    const r: Event = .{ .print = replacement };
    try expectEvents(&.{"\xC0\xFFa"}, &.{ r, r, .{ .print = 'a' } });
    try expectEvents(&.{"\x80a"}, &.{ r, .{ .print = 'a' } });
    try expectEvents(&.{"\xE3\x81A"}, &.{ r, .{ .print = 'A' } });
    try expectEvents(&.{"\xE3\x81"}, &.{});
    // A surrogate, an overlong form and a code point past U+10FFFF.
    try expectEvents(&.{"\xED\xA0\x80"}, &.{ r, r, r });
    try expectEvents(&.{"\xE0\x80\x80"}, &.{ r, r, r });
    try expectEvents(&.{"\xF4\x90\x80\x80"}, &.{ r, r, r, r });
    // A cut-short sequence does not swallow a control or an escape.
    try expectEvents(&.{"\xC3\n\xC3\x1b[A"}, &.{
        r, .{ .execute = '\n' }, r, .seq(0, "", &.{}, 0, 'A'),
    });
    // 0x9B is not a CSI.
    try expectEvents(&.{"\x9B2J"}, &.{ r, .{ .print = '2' }, .{ .print = 'J' } });
}

test "c0 controls execute" {
    try expectEvents(&.{"\x07\x08\t\n\ra\x0e\x0f"}, &.{
        .{ .execute = 0x07 }, .{ .execute = 0x08 }, .{ .execute = '\t' },
        .{ .execute = '\n' }, .{ .execute = '\r' }, .{ .print = 'a' },
        .{ .execute = 0x0E }, .{ .execute = 0x0F },
    });
}

test "control sequences" {
    try expectEvents(&.{"\x1b[H"}, &.{.seq(0, "", &.{}, 0, 'H')});
    try expectEvents(&.{"\x1b[12;34H"}, &.{.seq(0, "", &.{ 12, 34 }, 0, 'H')});
    try expectEvents(&.{"\x1b[;5H"}, &.{.seq(0, "", &.{ 0, 5 }, 0, 'H')});
    try expectEvents(&.{"\x1b[5;H"}, &.{.seq(0, "", &.{ 5, 0 }, 0, 'H')});
    try expectEvents(&.{"\x1b[m"}, &.{.seq(0, "", &.{}, 0, 'm')});
    try expectEvents(&.{ "\x1b[1", "2;3", "4H" }, &.{.seq(0, "", &.{ 12, 34 }, 0, 'H')});
    try expectEvents(&.{"\x1b[99999A"}, &.{.seq(0, "", &.{65535}, 0, 'A')});
}

test "private markers and intermediates" {
    try expectEvents(&.{"\x1b[?1049h"}, &.{.seq('?', "", &.{1049}, 0, 'h')});
    try expectEvents(&.{"\x1b[>c"}, &.{.seq('>', "", &.{}, 0, 'c')});
    try expectEvents(&.{"\x1b[>4;2m"}, &.{.seq('>', "", &.{ 4, 2 }, 0, 'm')});
    try expectEvents(&.{"\x1b[!p"}, &.{.seq(0, "!", &.{}, 0, 'p')});
    try expectEvents(&.{"\x1b[2 q"}, &.{.seq(0, " ", &.{2}, 0, 'q')});
    try expectEvents(&.{"\x1b[?2026$p"}, &.{.seq('?', "$", &.{2026}, 0, 'p')});
    // A marker after a parameter, a parameter after an intermediate and too
    // many intermediates make the sequence ignored.
    try expectEvents(&.{"\x1b[1?hx"}, &.{.{ .print = 'x' }});
    try expectEvents(&.{"\x1b[ 1qx"}, &.{.{ .print = 'x' }});
    try expectEvents(&.{"\x1b[!!!px"}, &.{.{ .print = 'x' }});
}

test "sub-parameters" {
    try expectEvents(&.{"\x1b[38:2::10:20:30m"}, &.{
        .seq(0, "", &.{ 38, 2, 0, 10, 20, 30 }, 0b111110, 'm'),
    });
    try expectEvents(&.{"\x1b[4:3m"}, &.{.seq(0, "", &.{ 4, 3 }, 0b10, 'm')});

    var p: Parser = .{};
    const Check = struct {
        pub fn print(_: @This(), _: u21) void {}
        pub fn execute(_: @This(), _: u8) void {}
        pub fn escDispatch(_: @This(), _: Esc) void {}
        pub fn csiDispatch(_: @This(), c: Csi) void {
            testing.expect(!c.isSub(0) and c.isSub(1) and !c.isSub(2) and !c.isSub(16)) catch @panic("isSub");
            testing.expectEqual(@as(u16, 4), c.param(0, 1)) catch @panic("param");
            testing.expectEqual(@as(u16, 7), c.param(2, 7)) catch @panic("param");
            testing.expectEqual(@as(u16, 9), c.param(3, 9)) catch @panic("param");
        }
    };
    p.feed("\x1b[4:3;0m", Check{});
}

test "parameters past the limit are dropped" {
    var expected: [max_params]u16 = undefined;
    for (&expected, 1..) |*v, i| v.* = @intCast(i);
    try expectEvents(
        &.{"\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;18;19;20:21H"},
        &.{.seq(0, "", &expected, 0, 'H')},
    );
}

test "escape sequences" {
    try expectEvents(&.{"\x1b7\x1b(0\x1b#8"}, &.{
        .escape("", '7'), .escape("(", '0'), .escape("#", '8'),
    });
    try expectEvents(&.{"\x1b\x7f8"}, &.{.escape("", '8')});
    try expectEvents(&.{"\x1b( (0x"}, &.{.{ .print = 'x' }});
}

test "strings are swallowed" {
    // OSC ending in BEL and in ST, with UTF-8 in the body.
    try expectEvents(&.{"\x1b]0;tîtle あ\x07x"}, &.{.{ .print = 'x' }});
    try expectEvents(&.{ "\x1b]2;tît", "le\x1b\\x" }, &.{ .escape("", '\\'), .{ .print = 'x' } });
    // DCS, SOS, PM and APC.
    try expectEvents(&.{"\x1bP1$r0m\x1b\\x"}, &.{ .escape("", '\\'), .{ .print = 'x' } });
    try expectEvents(&.{"\x1bXa\x1b\\\x1b^b\x1b\\\x1b_Gq=1;\x1b\\x"}, &.{
        .escape("", '\\'), .escape("", '\\'), .escape("", '\\'), .{ .print = 'x' },
    });
}

test "controls inside a control sequence" {
    // CAN aborts it.
    try expectEvents(&.{"\x1b[1\x18Ax"}, &.{ .{ .execute = 0x18 }, .{ .print = 'A' }, .{ .print = 'x' } });
    // SUB aborts a string.
    try expectEvents(&.{"\x1b]0;a\x1ab"}, &.{ .{ .execute = 0x1A }, .{ .print = 'b' } });
    // LF is executed and the sequence still dispatches.
    try expectEvents(&.{"\x1b[1\n2H"}, &.{ .{ .execute = '\n' }, .seq(0, "", &.{12}, 0, 'H') });
    // ESC starts over.
    try expectEvents(&.{"\x1b[?12;3\x1b[4m"}, &.{.seq(0, "", &.{4}, 0, 'm')});
    // DEL and bytes past it are ignored.
    try expectEvents(&.{"\x1b[1\x7f\xC3\xA92H"}, &.{.seq(0, "", &.{12}, 0, 'H')});
}
