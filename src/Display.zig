//! Writes frames of general terminal cells, the composited screen of
//! `rambit shell`, sending only the cells that changed since the previous
//! frame, and puts the real cursor where the emulator's is. `Screen` is its
//! counterpart for the half-block cells of `rambit <name>`.
//!
//! The terminal runs with line wrapping off, so writing the last column of
//! a row never scrolls the screen.

const Display = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const color = @import("color.zig");
const Grid = @import("vt/Grid.zig");

const Cell = Grid.Cell;
const Style = Grid.Style;
const Color = Grid.Color;

cols: u16,
rows: u16,
mode: color.Mode,
/// What the terminal shows, as far as we know.
front: []Cell,
/// Whether the real cursor is shown. `Terminal` hides it on entering.
cursor_shown: bool = false,
/// Where the real cursor was last put, if known.
cursor_at: ?Position = null,

pub const Cursor = struct { x: u16, y: u16, visible: bool };

const Position = struct { x: u16, y: u16 };

/// A cell no frame contains, so that comparing against it always differs.
const unknown: Cell = .{ .cp = std.math.maxInt(u21) };

/// Assumes the terminal has just been cleared.
pub fn init(gpa: Allocator, cols: u16, rows: u16, mode: color.Mode) Allocator.Error!Display {
    assert(cols >= 1 and rows >= 1);
    const front = try gpa.alloc(Cell, @as(usize, cols) * rows);
    @memset(front, .{});
    return .{ .cols = cols, .rows = rows, .mode = mode, .front = front };
}

pub fn deinit(d: *Display, gpa: Allocator) void {
    gpa.free(d.front);
    d.* = undefined;
}

/// Resizes the buffer, assuming the terminal has just been cleared.
pub fn resize(d: *Display, gpa: Allocator, cols: u16, rows: u16) Allocator.Error!void {
    var resized: Display = try .init(gpa, cols, rows, d.mode);
    resized.cursor_shown = d.cursor_shown;
    d.deinit(gpa);
    d.* = resized;
}

/// Forgets what the terminal shows, so that the next frame is drawn whole.
pub fn invalidate(d: *Display) void {
    @memset(d.front, unknown);
    d.cursor_at = null;
}

/// Writes the escape sequences that bring the terminal from the previous
/// frame to `frame`, `cols` by `rows` cells, and puts the cursor at
/// `cursor`. Leaves the colors reset to the defaults.
pub fn draw(d: *Display, w: *Writer, frame: []const Cell, cursor: Cursor) Writer.Error!void {
    assert(frame.len == d.front.len);
    var pen: Style = .{};
    var wrote = false;
    // Where the terminal cursor is, if known: writing a cell advances it.
    var at: ?usize = null;
    const cols: usize = d.cols;
    for (frame, 0..) |cell, i| {
        const x = i % cols;
        // The right half of a wide character is drawn with its left half.
        if (cell.wide == .spacer) continue;
        const pair = cell.wide == .head and x + 1 < cols;
        const changed = !cell.eql(d.front[i]) or (pair and !frame[i + 1].eql(d.front[i + 1]));
        if (!changed) continue;

        if (!wrote and d.cursor_shown) {
            try w.writeAll("\x1b[?25l");
            d.cursor_shown = false;
        }
        wrote = true;
        if (at != i) try w.print("\x1b[{d};{d}H", .{ i / cols + 1, x + 1 });
        if (!cell.style.eql(pen)) {
            try d.writeStyle(w, cell.style);
            pen = cell.style;
        }
        const ascii = try writeCodepoint(w, cell.cp);
        d.front[i] = cell;
        if (pair) d.front[i + 1] = frame[i + 1];
        // A terminal may disagree about the width of anything else, which
        // must not shift the rest of the row. Without line wrapping the
        // cursor stays put at the end of a row.
        at = if (ascii and x + 1 < cols) i + 1 else null;
    }
    if (!pen.eql(.{})) try w.writeAll("\x1b[0m");

    const target: Position = .{ .x = @min(cursor.x, d.cols - 1), .y = @min(cursor.y, d.rows - 1) };
    const moved = if (d.cursor_at) |p| p.x != target.x or p.y != target.y else true;
    if (wrote or moved) {
        try w.print("\x1b[{d};{d}H", .{ target.y + 1, target.x + 1 });
        d.cursor_at = target;
    }
    if (cursor.visible and !d.cursor_shown) {
        try w.writeAll("\x1b[?25h");
        d.cursor_shown = true;
    } else if (!cursor.visible and d.cursor_shown) {
        try w.writeAll("\x1b[?25l");
        d.cursor_shown = false;
    }
}

/// Writes `cp` as UTF-8, with control characters and anything that is not
/// a Unicode scalar value replaced. Returns whether one ASCII byte was
/// written.
fn writeCodepoint(w: *Writer, cp: u21) Writer.Error!bool {
    if (cp < 0x20 or (cp >= 0x7f and cp <= 0x9f)) {
        try w.writeByte(' ');
        return true;
    }
    if (cp < 0x80) {
        try w.writeByte(@intCast(cp));
        return true;
    }
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch
        std.unicode.utf8Encode(std.unicode.replacement_character, &buf) catch unreachable;
    try w.writeAll(buf[0..len]);
    return false;
}

/// Sets every attribute and both colors of `style` in one SGR sequence,
/// starting from a reset.
fn writeStyle(d: *const Display, w: *Writer, style: Style) Writer.Error!void {
    try w.writeAll("\x1b[0");
    const a = style.attrs;
    const flags = [_]struct { bool, []const u8 }{
        .{ a.bold, ";1" },
        .{ a.dim, ";2" },
        .{ a.italic, ";3" },
        .{ a.underline, ";4" },
        .{ a.blink, ";5" },
        .{ a.inverse, ";7" },
        .{ a.invisible, ";8" },
        .{ a.strikethrough, ";9" },
    };
    for (flags) |flag| if (flag[0]) try w.writeAll(flag[1]);
    try d.writeColor(w, style.fg, .foreground);
    try d.writeColor(w, style.bg, .background);
    try w.writeByte('m');
}

fn writeColor(d: *const Display, w: *Writer, c: Color, layer: enum { foreground, background }) Writer.Error!void {
    const base: u8 = if (layer == .foreground) 30 else 40;
    switch (c) {
        .default => {},
        .palette => |n| if (n < 8)
            try w.print(";{d}", .{base + n})
        else if (n < 16)
            try w.print(";{d}", .{base + 60 + n - 8})
        else
            try w.print(";{d};5;{d}", .{ base + 8, n }),
        .rgb => |rgb| switch (d.mode) {
            .truecolor => try w.print(";{d};2;{d};{d};{d}", .{ base + 8, rgb.r, rgb.g, rgb.b }),
            .@"256" => try w.print(";{d};5;{d}", .{ base + 8, rgb.to256() }),
        },
    }
}

const testing = std.testing;

const Fixture = struct {
    display: Display,
    frame: []Cell,
    buf: [1024]u8 = undefined,

    fn init(cols: u16, rows: u16, mode: color.Mode) !Fixture {
        const gpa = testing.allocator;
        var display: Display = try .init(gpa, cols, rows, mode);
        errdefer display.deinit(gpa);
        const frame = try gpa.alloc(Cell, @as(usize, cols) * rows);
        @memset(frame, .{});
        return .{ .display = display, .frame = frame };
    }

    fn deinit(f: *Fixture) void {
        f.display.deinit(testing.allocator);
        testing.allocator.free(f.frame);
    }

    fn at(f: *Fixture, x: usize, y: usize) *Cell {
        return &f.frame[y * f.display.cols + x];
    }

    /// Draws the frame and checks what was written.
    fn expectDraw(f: *Fixture, cursor: Cursor, expected: []const u8) !void {
        var w: Writer = .fixed(&f.buf);
        try f.display.draw(&w, f.frame, cursor);
        try testing.expectEqualStrings(expected, w.buffered());
    }
};

const home: Cursor = .{ .x = 0, .y = 0, .visible = true };

test "draw writes only what changed" {
    var f: Fixture = try .init(4, 3, .truecolor);
    defer f.deinit();
    f.at(2, 1).* = .{ .cp = 'x' };
    // The cursor starts hidden, so there is nothing to hide.
    try f.expectDraw(home, "\x1b[2;3Hx\x1b[1;1H\x1b[?25h");
    try f.expectDraw(home, "");

    // Hidden while cells are written, shown again at the cursor.
    f.at(2, 1).* = .{};
    try f.expectDraw(home, "\x1b[?25l\x1b[2;3H \x1b[1;1H\x1b[?25h");
}

test "draw moves the cursor and toggles its visibility" {
    var f: Fixture = try .init(4, 3, .truecolor);
    defer f.deinit();
    try f.expectDraw(.{ .x = 1, .y = 2, .visible = false }, "\x1b[3;2H");
    try f.expectDraw(.{ .x = 1, .y = 2, .visible = false }, "");
    try f.expectDraw(.{ .x = 1, .y = 2, .visible = true }, "\x1b[?25h");
    try f.expectDraw(.{ .x = 3, .y = 0, .visible = true }, "\x1b[1;4H");
    try f.expectDraw(.{ .x = 3, .y = 0, .visible = false }, "\x1b[?25l");
    // Beyond the screen is clamped to it.
    try f.expectDraw(.{ .x = 9, .y = 9, .visible = false }, "\x1b[3;4H");
}

test "draw sets styles and resets at the end" {
    var f: Fixture = try .init(4, 1, .truecolor);
    defer f.deinit();
    const bold_red: Style = .{ .fg = .{ .palette = 1 }, .attrs = .{ .bold = true } };
    f.at(0, 0).* = .{ .cp = 'a', .style = bold_red };
    f.at(1, 0).* = .{ .cp = 'b', .style = bold_red };
    f.at(2, 0).* = .{ .cp = 'c' };
    try f.expectDraw(home, "\x1b[1;1H\x1b[0;1;31mab\x1b[0mc\x1b[1;1H\x1b[?25h");

    f.at(0, 0).* = .{ .cp = 'a', .style = .{
        .fg = .{ .palette = 9 },
        .bg = .{ .palette = 12 },
        .attrs = .{ .dim = true, .italic = true, .underline = true, .blink = true, .inverse = true, .invisible = true, .strikethrough = true },
    } };
    f.at(1, 0).* = .{ .cp = 'b', .style = .{ .fg = .{ .palette = 7 }, .bg = .{ .palette = 0 } } };
    f.at(2, 0).* = .{ .cp = 'c', .style = .{ .fg = .{ .palette = 16 }, .bg = .{ .palette = 255 } } };
    try f.expectDraw(home, "\x1b[?25l\x1b[1;1H" ++
        "\x1b[0;2;3;4;5;7;8;9;91;104ma" ++
        "\x1b[0;37;40mb" ++
        "\x1b[0;38;5;16;48;5;255mc" ++
        "\x1b[0m\x1b[1;1H\x1b[?25h");
}

test "draw writes rgb colors for the color mode" {
    const style: Style = .{ .fg = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } }, .bg = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } } };
    const hidden: Cursor = .{ .x = 1, .y = 0, .visible = false };

    var truecolor: Fixture = try .init(2, 1, .truecolor);
    defer truecolor.deinit();
    truecolor.at(0, 0).* = .{ .cp = 0x2580, .style = style };
    try truecolor.expectDraw(hidden, "\x1b[1;1H\x1b[0;38;2;255;0;0;48;2;0;0;255m▀\x1b[0m\x1b[1;2H");

    var palette: Fixture = try .init(2, 1, .@"256");
    defer palette.deinit();
    palette.at(0, 0).* = .{ .cp = 0x2580, .style = style };
    try palette.expectDraw(hidden, "\x1b[1;1H\x1b[0;38;5;196;48;5;21m▀\x1b[0m\x1b[1;2H");
}

test "draw moves the cursor once for a run of ASCII" {
    var f: Fixture = try .init(5, 2, .truecolor);
    defer f.deinit();
    for ("abcde", 0..) |c, x| f.at(x, 0).* = .{ .cp = c };
    f.at(0, 1).* = .{ .cp = 'f' };
    f.at(2, 1).* = .{ .cp = 'g' };
    // The end of a row and a gap each need a move; control characters are
    // written as spaces.
    f.at(3, 1).* = .{ .cp = 0x1b };
    f.at(4, 1).* = .{ .cp = 0x85 };
    try f.expectDraw(home, "\x1b[1;1Habcde\x1b[2;1Hf\x1b[2;3Hg  \x1b[1;1H\x1b[?25h");
}

test "draw writes a wide character once" {
    var f: Fixture = try .init(5, 1, .truecolor);
    defer f.deinit();
    f.at(0, 0).* = .{ .cp = 'a' };
    f.at(1, 0).* = .{ .cp = 0x3042, .wide = .head };
    f.at(2, 0).* = .{ .wide = .spacer };
    f.at(3, 0).* = .{ .cp = 'b' };
    try f.expectDraw(home, "\x1b[1;1Haあ\x1b[1;4Hb\x1b[1;1H\x1b[?25h");

    // A change to the right half alone rewrites the character.
    f.at(2, 0).* = .{ .wide = .spacer, .style = .{ .bg = .{ .palette = 1 } } };
    try f.expectDraw(home, "\x1b[?25l\x1b[1;2Hあ\x1b[1;1H\x1b[?25h");
    f.at(1, 0).style = .{ .bg = .{ .palette = 1 } };
    try f.expectDraw(home, "\x1b[?25l\x1b[1;2H\x1b[0;41mあ\x1b[0m\x1b[1;1H\x1b[?25h");

    // Replacing it with two narrow cells writes both.
    f.at(1, 0).* = .{ .cp = 'c' };
    f.at(2, 0).* = .{ .cp = 'd' };
    try f.expectDraw(home, "\x1b[?25l\x1b[1;2Hcd\x1b[1;1H\x1b[?25h");
}

test "resize and invalidate" {
    const gpa = testing.allocator;
    var f: Fixture = try .init(2, 1, .truecolor);
    defer f.deinit();
    try f.expectDraw(home, "\x1b[1;1H\x1b[?25h");

    try f.display.resize(gpa, 3, 2);
    gpa.free(f.frame);
    f.frame = try gpa.alloc(Cell, 6);
    @memset(f.frame, .{});
    f.at(1, 1).* = .{ .cp = 'z' };
    // The cleared screen is not repainted, and the cursor stays shown.
    try f.expectDraw(home, "\x1b[?25l\x1b[2;2Hz\x1b[1;1H\x1b[?25h");
    try f.expectDraw(home, "");

    f.display.invalidate();
    try f.expectDraw(home, "\x1b[?25l\x1b[1;1H   \x1b[2;1H z \x1b[1;1H\x1b[?25h");
}
