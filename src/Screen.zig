//! Turns a canvas into terminal cells and writes the ANSI escape sequences
//! for the cells that changed since the previous frame.
//!
//! A cell shows two logical pixels with the half-block characters: the
//! foreground color paints one half and the background color the other.
//! Transparent pixels use the terminal's default background, so ramblers sit
//! on whatever color scheme the terminal has.

const Screen = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const color = @import("color.zig");
const Rgb = color.Rgb;
const Canvas = @import("Canvas.zig");

cols: u16,
rows: u16,
mode: color.Mode,
/// What the terminal shows, as far as we know.
front: []Cell,
/// What the next frame should show.
back: []Cell,

pub const Cell = struct {
    glyph: Glyph = .blank,
    fg: ?Rgb = null,
    bg: ?Rgb = null,

    pub const Glyph = enum {
        blank,
        upper,
        lower,

        fn bytes(g: Glyph) []const u8 {
            return switch (g) {
                .blank => " ",
                .upper => "▀",
                .lower => "▄",
            };
        }
    };

    /// Encodes a vertical pair of pixels as one cell.
    pub fn fromPixels(top: ?Rgb, bottom: ?Rgb) Cell {
        if (top) |t| {
            if (bottom) |b| {
                // A plain background fill is crisper than a block glyph in
                // fonts whose block characters do not quite fill the cell.
                if (t.eql(b)) return .{ .bg = t };
                return .{ .glyph = .upper, .fg = t, .bg = b };
            }
            return .{ .glyph = .upper, .fg = t };
        }
        if (bottom) |b| return .{ .glyph = .lower, .fg = b };
        return .{};
    }

    pub fn eql(a: Cell, b: Cell) bool {
        return a.glyph == b.glyph and optionalEql(a.fg, b.fg) and optionalEql(a.bg, b.bg);
    }
};

pub fn init(gpa: Allocator, cols: u16, rows: u16, mode: color.Mode) Allocator.Error!Screen {
    const len = @as(usize, cols) * rows;
    const front = try gpa.alloc(Cell, len);
    errdefer gpa.free(front);
    const back = try gpa.alloc(Cell, len);
    @memset(front, .{});
    @memset(back, .{});
    return .{ .cols = cols, .rows = rows, .mode = mode, .front = front, .back = back };
}

pub fn deinit(s: *Screen, gpa: Allocator) void {
    gpa.free(s.front);
    gpa.free(s.back);
    s.* = undefined;
}

/// Resizes the buffers, assuming the terminal has just been cleared.
pub fn resize(s: *Screen, gpa: Allocator, cols: u16, rows: u16) Allocator.Error!void {
    const resized = try init(gpa, cols, rows, s.mode);
    s.deinit(gpa);
    s.* = resized;
}

/// Converts `canvas`, which must be `cols` wide and `2 * rows` tall, into
/// the cells of the next frame.
pub fn compose(s: *Screen, canvas: *const Canvas) void {
    std.debug.assert(canvas.width == s.cols and canvas.height == 2 * @as(u32, s.rows));
    cellsFromCanvas(s.back, canvas);
}

/// Fills `cells` (one per pair of pixel rows) from `canvas`, whose height
/// must be even.
pub fn cellsFromCanvas(cells: []Cell, canvas: *const Canvas) void {
    const cols = canvas.width;
    std.debug.assert(canvas.height % 2 == 0 and cells.len == @as(usize, cols) * (canvas.height / 2));
    for (cells, 0..) |*cell, i| {
        const x = i % cols;
        const y = i / cols;
        cell.* = .fromPixels(canvas.get(x, 2 * y), canvas.get(x, 2 * y + 1));
    }
}

/// Writes the escape sequences that bring the terminal from the previous
/// frame to the next one. Leaves the colors reset to the defaults.
pub fn flush(s: *Screen, w: *Writer) Writer.Error!void {
    var pen: Pen = .{ .mode = s.mode };
    // Where the terminal cursor is, if known: writing a cell advances it.
    var cursor: ?usize = null;
    for (s.back, s.front, 0..) |next, *shown, i| {
        if (next.eql(shown.*)) continue;
        if (cursor != i) {
            try w.print("\x1b[{d};{d}H", .{ i / s.cols + 1, i % s.cols + 1 });
        }
        try pen.draw(w, next);
        shown.* = next;
        // With line wrapping disabled the cursor stays put at the end of a row.
        cursor = if ((i + 1) % s.cols == 0) null else i + 1;
    }
    try pen.reset(w);
}

/// Writes `cells`, `cols` per row, as plain lines of text, for output that
/// is not an animation, such as `rambit preview`.
pub fn writeLines(w: *Writer, cells: []const Cell, cols: usize, mode: color.Mode) Writer.Error!void {
    var pen: Pen = .{ .mode = mode };
    var rows = std.mem.window(Cell, cells, cols, cols);
    while (rows.next()) |row| {
        // Trailing blank cells need neither colors nor characters.
        var end = row.len;
        while (end > 0 and row[end - 1].eql(.{})) end -= 1;
        for (row[0..end]) |cell| try pen.draw(w, cell);
        try pen.reset(w);
        try w.writeByte('\n');
    }
}

/// Tracks the current SGR colors to avoid repeating them for every cell.
const Pen = struct {
    mode: color.Mode,
    fg: ?Rgb = null,
    bg: ?Rgb = null,

    fn draw(p: *Pen, w: *Writer, cell: Cell) Writer.Error!void {
        // The foreground color is invisible behind a blank.
        const fg_changed = cell.glyph != .blank and !optionalEql(p.fg, cell.fg);
        const bg_changed = !optionalEql(p.bg, cell.bg);
        if (fg_changed or bg_changed) {
            try w.writeAll("\x1b[");
            if (fg_changed) try p.writeColor(w, cell.fg, .foreground);
            if (fg_changed and bg_changed) try w.writeByte(';');
            if (bg_changed) try p.writeColor(w, cell.bg, .background);
            try w.writeByte('m');
            if (fg_changed) p.fg = cell.fg;
            if (bg_changed) p.bg = cell.bg;
        }
        try w.writeAll(cell.glyph.bytes());
    }

    fn writeColor(p: Pen, w: *Writer, c: ?Rgb, layer: enum { foreground, background }) Writer.Error!void {
        const base: u8 = if (layer == .foreground) 30 else 40;
        const rgb = c orelse return w.print("{d}", .{base + 9});
        switch (p.mode) {
            .truecolor => try w.print("{d};2;{d};{d};{d}", .{ base + 8, rgb.r, rgb.g, rgb.b }),
            .@"256" => try w.print("{d};5;{d}", .{ base + 8, rgb.to256() }),
        }
    }

    fn reset(p: *Pen, w: *Writer) Writer.Error!void {
        if (p.fg == null and p.bg == null) return;
        try w.writeAll("\x1b[0m");
        p.fg = null;
        p.bg = null;
    }
};

fn optionalEql(a: ?Rgb, b: ?Rgb) bool {
    if (a) |x| return if (b) |y| x.eql(y) else false;
    return b == null;
}

const testing = std.testing;
const red: Rgb = .{ .r = 255, .g = 0, .b = 0 };
const blue: Rgb = .{ .r = 0, .g = 0, .b = 255 };

test "Cell.fromPixels" {
    try testing.expect(Cell.fromPixels(null, null).eql(.{}));
    try testing.expect(Cell.fromPixels(red, null).eql(.{ .glyph = .upper, .fg = red }));
    try testing.expect(Cell.fromPixels(null, red).eql(.{ .glyph = .lower, .fg = red }));
    try testing.expect(Cell.fromPixels(red, blue).eql(.{ .glyph = .upper, .fg = red, .bg = blue }));
    try testing.expect(Cell.fromPixels(red, red).eql(.{ .bg = red }));
}

test "flush writes only what changed" {
    const gpa = testing.allocator;
    var screen: Screen = try .init(gpa, 3, 2, .truecolor);
    defer screen.deinit(gpa);
    var canvas: Canvas = try .init(gpa, 3, 4);
    defer canvas.deinit(gpa);

    canvas.pixels[1] = red; // (1, 0): top half of cell (1, 0)
    canvas.pixels[2] = red; // (2, 0)
    canvas.pixels[3 * 3 + 2] = blue; // (2, 3): bottom half of cell (2, 1)
    screen.compose(&canvas);

    var buf: [512]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try screen.flush(&w);
    try testing.expectEqualStrings(
        "\x1b[1;2H\x1b[38;2;255;0;0m▀▀" ++
            "\x1b[2;3H\x1b[38;2;0;0;255m▄\x1b[0m",
        w.buffered(),
    );

    // Nothing changed: nothing to write.
    w = .fixed(&buf);
    try screen.flush(&w);
    try testing.expectEqualStrings("", w.buffered());

    // Erasing a cell writes a blank with the default colors.
    canvas.pixels[2] = null;
    screen.compose(&canvas);
    w = .fixed(&buf);
    try screen.flush(&w);
    try testing.expectEqualStrings("\x1b[1;3H ", w.buffered());
}

test "flush in 256-color mode" {
    const gpa = testing.allocator;
    var screen: Screen = try .init(gpa, 1, 1, .@"256");
    defer screen.deinit(gpa);
    var canvas: Canvas = try .init(gpa, 1, 2);
    defer canvas.deinit(gpa);

    canvas.pixels[0] = red;
    canvas.pixels[1] = blue;
    screen.compose(&canvas);

    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try screen.flush(&w);
    try testing.expectEqualStrings("\x1b[1;1H\x1b[38;5;196;48;5;21m▀\x1b[0m", w.buffered());
}

test writeLines {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try writeLines(&w, &.{ .{ .bg = red }, .{}, .{}, .{}, .{ .glyph = .lower, .fg = blue }, .{} }, 3, .truecolor);
    try testing.expectEqualStrings(
        "\x1b[48;2;255;0;0m \x1b[0m\n" ++
            " \x1b[38;2;0;0;255m▄\x1b[0m\n",
        w.buffered(),
    );
}
