//! One screen's worth of cells: what the program in the pseudo-terminal has
//! drawn, with the editing operations the emulator needs. The grid knows
//! nothing of cursors, modes or escape sequences; the emulator drives it and
//! the renderer reads it.
//!
//! A two-cell character is a `head` cell followed by a `spacer` cell. Every
//! operation keeps such pairs whole: a half left without its other half
//! becomes a blank.

const Grid = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const color = @import("../color.zig");

cols: u16,
rows: u16,
/// `rows` storage rows of `cols` cells each.
cells: []Cell,
/// `lines[y]` is the storage row shown at screen row y. Scrolling rotates
/// these instead of moving cells, since `cat` of a large file scrolls once
/// per line.
lines: []u16,

pub const Color = union(enum) {
    /// The terminal's own foreground or background color.
    default,
    /// An entry of the 256-color palette, as set by SGR 30 to 37, 38;5;n and
    /// the like.
    palette: u8,
    /// A direct color, as set by SGR 38;2;r;g;b.
    rgb: color.Rgb,

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .palette => |i| b == .palette and b.palette == i,
            .rgb => |c| b == .rgb and b.rgb.eql(c),
        };
    }
};

pub const Attrs = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    invisible: bool = false,
    strikethrough: bool = false,
};

/// How a cell is drawn, as set by SGR.
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    attrs: Attrs = .{},

    pub fn eql(a: Style, b: Style) bool {
        return a.fg.eql(b.fg) and a.bg.eql(b.bg) and
            @as(u8, @bitCast(a.attrs)) == @as(u8, @bitCast(b.attrs));
    }
};

pub const Cell = struct {
    cp: u21 = ' ',
    wide: Wide = .narrow,
    style: Style = .{},

    pub const Wide = enum(u2) {
        /// A character one cell wide.
        narrow,
        /// The left half of a character two cells wide.
        head,
        /// The right half of a character two cells wide. Its code point is
        /// ignored.
        spacer,
    };

    pub fn eql(a: Cell, b: Cell) bool {
        return a.wide == b.wide and (a.wide == .spacer or a.cp == b.cp) and a.style.eql(b.style);
    }

    /// What erasing leaves behind: a space in the current background color,
    /// as xterm-256color advertises background color erase (bce).
    pub fn blank(style: Style) Cell {
        return .{ .style = .{ .bg = style.bg } };
    }
};

comptime {
    // Two screens of a large terminal are diffed every frame.
    assert(@sizeOf(Cell) <= 16);
}

pub fn init(gpa: Allocator, cols: u16, rows: u16) Allocator.Error!Grid {
    assert(cols >= 1 and rows >= 1);
    const cells = try gpa.alloc(Cell, @as(usize, cols) * rows);
    errdefer gpa.free(cells);
    const lines = try gpa.alloc(u16, rows);
    @memset(cells, .{});
    for (lines, 0..) |*line, y| line.* = @intCast(y);
    return .{ .cols = cols, .rows = rows, .cells = cells, .lines = lines };
}

pub fn deinit(g: *Grid, gpa: Allocator) void {
    gpa.free(g.cells);
    gpa.free(g.lines);
    g.* = undefined;
}

/// The cells shown at screen row y.
pub fn row(g: *const Grid, y: u16) []Cell {
    assert(y < g.rows);
    const start = @as(usize, g.lines[y]) * g.cols;
    return g.cells[start..][0..g.cols];
}

pub fn eraseAll(g: *Grid, blank: Cell) void {
    @memset(g.cells, blank);
}

/// Fills columns [x0, x1) of row y with `blank`, for EL, ECH and ED. A wide
/// character cut in two by either edge is erased whole.
pub fn erase(g: *Grid, y: u16, x0: u16, x1: u16, blank: Cell) void {
    const cells = g.row(y);
    const end = @min(x1, g.cols);
    if (x0 >= end) return;
    @memset(cells[x0..end], blank);
    repair(cells, x0, blank);
    repair(cells, end, blank);
}

/// Shifts columns [x, cols) of row y right by n and fills the gap with
/// `blank`, for ICH and insert mode. What is pushed past the last column is
/// lost.
pub fn insertBlanks(g: *Grid, y: u16, x: u16, n: u16, blank: Cell) void {
    if (x >= g.cols) return;
    const cells = g.row(y);
    const count = @min(n, g.cols - x);
    if (count == 0) return;
    std.mem.copyBackwards(Cell, cells[x + count ..], cells[x .. g.cols - count]);
    @memset(cells[x..][0..count], blank);
    repair(cells, x, blank);
    repair(cells, x + count, blank);
    repair(cells, g.cols, blank);
}

/// Deletes n cells of row y from column x, shifting the rest of the row left
/// and filling its end with `blank`, for DCH.
pub fn deleteCells(g: *Grid, y: u16, x: u16, n: u16, blank: Cell) void {
    if (x >= g.cols) return;
    const cells = g.row(y);
    const count = @min(n, g.cols - x);
    if (count == 0) return;
    // Erase the deleted cells first, so that a wide character cut by either
    // edge goes whole rather than leaving a half that the shift would pair
    // with the wrong neighbor.
    @memset(cells[x..][0..count], blank);
    repair(cells, x, blank);
    repair(cells, x + count, blank);
    std.mem.copyForwards(Cell, cells[x .. g.cols - count], cells[x + count ..]);
    @memset(cells[g.cols - count ..], blank);
    repair(cells, g.cols - count, blank);
}

/// Scrolls rows [top, bottom] up by n: the top n rows are lost and n rows of
/// `blank` appear at the bottom.
pub fn scrollUp(g: *Grid, top: u16, bottom: u16, n: u16, blank: Cell) void {
    assert(top <= bottom and bottom < g.rows);
    const region = g.lines[top .. bottom + 1];
    const count = @min(n, region.len);
    if (count == 0) return;
    std.mem.rotate(u16, region, count);
    for (bottom + 1 - count..bottom + 1) |y| @memset(g.row(@intCast(y)), blank);
}

/// Scrolls rows [top, bottom] down by n: the bottom n rows are lost and n
/// rows of `blank` appear at the top.
pub fn scrollDown(g: *Grid, top: u16, bottom: u16, n: u16, blank: Cell) void {
    assert(top <= bottom and bottom < g.rows);
    const region = g.lines[top .. bottom + 1];
    const count = @min(n, region.len);
    if (count == 0) return;
    std.mem.rotate(u16, region, region.len - count);
    for (top..top + count) |y| @memset(g.row(@intCast(y)), blank);
}

/// Changes the size of the grid. Screen row y comes from old row
/// y + drop_top; rows that no longer fit are lost and new ones are blank.
/// Columns are cut off or padded on the right. Lines are not reflowed.
pub fn resize(g: *Grid, gpa: Allocator, cols: u16, rows: u16, drop_top: u16) Allocator.Error!void {
    const new = try g.resized(gpa, cols, rows, drop_top);
    g.deinit(gpa);
    g.* = new;
}

/// A copy of the grid at another size, as `resize` makes it, leaving the grid
/// itself alone.
pub fn resized(g: *const Grid, gpa: Allocator, cols: u16, rows: u16, drop_top: u16) Allocator.Error!Grid {
    assert(cols >= 1 and rows >= 1);
    const cells = try gpa.alloc(Cell, @as(usize, cols) * rows);
    errdefer gpa.free(cells);
    const lines = try gpa.alloc(u16, rows);
    @memset(cells, .{});
    const keep = @min(cols, g.cols);
    for (lines, 0..) |*line, y| {
        line.* = @intCast(y);
        const new = cells[y * cols ..][0..cols];
        const old_y = y + drop_top;
        if (old_y < g.rows) @memcpy(new[0..keep], g.row(@intCast(old_y))[0..keep]);
        // A character cut off from its right half.
        repair(new, cols, .{});
    }
    return .{ .cols = cols, .rows = rows, .cells = cells, .lines = lines };
}

/// Writes row y as UTF-8 text, without the right halves of wide characters
/// and without trailing spaces. Styles are left out.
pub fn writeRow(g: *const Grid, y: u16, w: *Writer) Writer.Error!void {
    const cells = g.row(y);
    var end = cells.len;
    while (end > 0 and cells[end - 1].wide != .spacer and cells[end - 1].cp == ' ') end -= 1;
    for (cells[0..end]) |cell| {
        if (cell.wide == .spacer) continue;
        try w.printUnicodeCodepoint(cell.cp);
    }
}

/// Blanks the halves of wide characters that the boundary between columns
/// x - 1 and x has left alone: a head at x - 1 without a spacer after it, or
/// a spacer at x without a head before it.
fn repair(cells: []Cell, x: usize, blank: Cell) void {
    if (x > 0 and x - 1 < cells.len and cells[x - 1].wide == .head and
        (x == cells.len or cells[x].wide != .spacer))
    {
        cells[x - 1] = blank;
    }
    if (x < cells.len and cells[x].wide == .spacer and
        (x == 0 or cells[x - 1].wide != .head))
    {
        cells[x] = blank;
    }
}

const testing = std.testing;
const codepointWidth = @import("width.zig").codepointWidth;

/// Writes `text` into row y from column x, two cells for wide characters.
fn put(g: *Grid, y: u16, x: u16, text: []const u8) void {
    const cells = g.row(y);
    var i: usize = x;
    var it = (std.unicode.Utf8View.init(text) catch unreachable).iterator();
    while (it.nextCodepoint()) |cp| {
        if (codepointWidth(cp) == 2) {
            cells[i] = .{ .cp = cp, .wide = .head };
            cells[i + 1] = .{ .wide = .spacer };
            i += 2;
        } else {
            cells[i] = .{ .cp = cp };
            i += 1;
        }
    }
}

fn expectRows(g: *const Grid, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, g.rows);
    for (expected, 0..) |text, y| {
        var buf: [256]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try g.writeRow(@intCast(y), &w);
        try testing.expectEqualStrings(text, w.buffered());
    }
}

/// Checks that every head is followed by a spacer and every spacer follows a
/// head.
fn expectWhole(g: *const Grid) !void {
    for (0..g.rows) |y| {
        const cells = g.row(@intCast(y));
        for (cells, 0..) |cell, x| switch (cell.wide) {
            .narrow => {},
            .head => try testing.expect(x + 1 < cells.len and cells[x + 1].wide == .spacer),
            .spacer => try testing.expect(x > 0 and cells[x - 1].wide == .head),
        };
    }
}

fn expectPermutation(g: *const Grid) !void {
    var seen: [64]bool = @splat(false);
    for (g.lines) |line| {
        try testing.expect(!seen[line]);
        seen[line] = true;
    }
}

const red: Style = .{ .bg = .{ .palette = 1 } };

test "init is blank" {
    var g: Grid = try .init(testing.allocator, 4, 3);
    defer g.deinit(testing.allocator);
    for (g.cells) |cell| try testing.expect(cell.eql(.{}));
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2 }, g.lines);
    try expectRows(&g, &.{ "", "", "" });
}

test "writeRow skips spacers and trims trailing spaces" {
    var g: Grid = try .init(testing.allocator, 8, 1);
    defer g.deinit(testing.allocator);
    put(&g, 0, 0, " aあ b");
    try expectRows(&g, &.{" aあ b"});
    put(&g, 0, 6, "い");
    try expectRows(&g, &.{" aあ bい"});
}

test "erase keeps wide characters whole" {
    var g: Grid = try .init(testing.allocator, 8, 1);
    defer g.deinit(testing.allocator);
    put(&g, 0, 0, "あいう");
    // Columns 1 and 4 are the right half of あ and the left half of う.
    g.erase(0, 1, 5, .blank(red));
    try expectRows(&g, &.{""});
    try expectWhole(&g);
    for (g.row(0)[0..6]) |cell| try testing.expect(cell.eql(.blank(red)));

    put(&g, 0, 0, "あいう");
    g.erase(0, 3, 4, .{});
    try expectRows(&g, &.{"あ  う"});
    try expectWhole(&g);

    // An empty or out-of-range erase does nothing.
    g.erase(0, 4, 4, .{});
    g.erase(0, 9, 12, .{});
    try expectRows(&g, &.{"あ  う"});
    // x1 is clamped to the row.
    g.erase(0, 5, 100, .{});
    try expectRows(&g, &.{"あ"});
    try expectWhole(&g);
}

test "eraseAll" {
    var g: Grid = try .init(testing.allocator, 3, 2);
    defer g.deinit(testing.allocator);
    put(&g, 0, 0, "abc");
    put(&g, 1, 0, "あ");
    g.eraseAll(.blank(red));
    try expectRows(&g, &.{ "", "" });
    for (g.cells) |cell| try testing.expect(cell.eql(.blank(red)));
}

test "insertBlanks pushes a wide character off the edge cleanly" {
    var g: Grid = try .init(testing.allocator, 6, 1);
    defer g.deinit(testing.allocator);
    put(&g, 0, 0, "abあい");
    g.insertBlanks(0, 1, 1, .{});
    // い is cut at the edge: its head lands in the last column.
    try expectRows(&g, &.{"a bあ"});
    try expectWhole(&g);

    put(&g, 0, 0, "abあい");
    g.insertBlanks(0, 2, 2, .{});
    try expectRows(&g, &.{"ab  あ"});
    try expectWhole(&g);

    // Inserting into the right half of a wide character erases it.
    put(&g, 0, 0, "abあい");
    g.insertBlanks(0, 3, 1, .blank(red));
    try expectRows(&g, &.{"ab"});
    try expectWhole(&g);
    try testing.expect(g.row(0)[2].eql(.blank(red)));
    try testing.expect(g.row(0)[3].eql(.blank(red)));

    // More than the rest of the row, and past the edge.
    put(&g, 0, 0, "abcdef");
    g.insertBlanks(0, 2, 100, .{});
    try expectRows(&g, &.{"ab"});
    g.insertBlanks(0, 6, 1, .{});
    try expectRows(&g, &.{"ab"});
}

test "deleteCells through a wide character" {
    var g: Grid = try .init(testing.allocator, 6, 1);
    defer g.deinit(testing.allocator);
    put(&g, 0, 0, "aあいb");
    g.deleteCells(0, 1, 1, .blank(red));
    // The right half of あ is shifted to column 1 without its head.
    try expectRows(&g, &.{"a いb"});
    try expectWhole(&g);
    try testing.expect(g.row(0)[5].eql(.blank(red)));

    put(&g, 0, 0, "aあいb");
    g.deleteCells(0, 2, 2, .{});
    // Deleting from the right half of あ erases its left half.
    try expectRows(&g, &.{"a  b"});
    try expectWhole(&g);

    put(&g, 0, 0, "aあいb");
    g.deleteCells(0, 1, 2, .{});
    try expectRows(&g, &.{"aいb"});
    try expectWhole(&g);

    put(&g, 0, 0, "abcdef");
    g.deleteCells(0, 4, 100, .{});
    try expectRows(&g, &.{"abcd"});
    g.deleteCells(0, 6, 1, .{});
    try expectRows(&g, &.{"abcd"});
}

test "scrollUp and scrollDown on a region" {
    var g: Grid = try .init(testing.allocator, 2, 5);
    defer g.deinit(testing.allocator);
    for (0..5) |y| put(&g, @intCast(y), 0, &.{@intCast('0' + y)});

    g.scrollUp(1, 3, 1, .blank(red));
    try expectRows(&g, &.{ "0", "2", "3", "", "4" });
    for (g.row(3)) |cell| try testing.expect(cell.eql(.blank(red)));
    try testing.expect(g.row(4)[1].eql(.{}));

    g.scrollDown(1, 3, 2, .{});
    try expectRows(&g, &.{ "0", "", "", "2", "4" });

    // n is clamped to the region.
    g.scrollUp(0, 4, 100, .{});
    try expectRows(&g, &.{ "", "", "", "", "" });
    put(&g, 2, 0, "x");
    g.scrollDown(2, 2, 9, .{});
    try expectRows(&g, &.{ "", "", "", "", "" });
    g.scrollUp(0, 4, 0, .{});
    try expectPermutation(&g);
}

test "repeated scrollUp keeps lines a permutation" {
    var g: Grid = try .init(testing.allocator, 3, 7);
    defer g.deinit(testing.allocator);
    var i: u8 = 0;
    while (i < 50) : (i += 1) {
        g.scrollUp(1 + i % 3, 6 - i % 2, 1 + i % 4, .{});
        g.scrollDown(i % 2, 4 + i % 3, 1 + i % 3, .{});
        put(&g, 6, 0, &.{'a' + i % 26});
        try expectPermutation(&g);
    }
    // Every storage row is still distinct, so writing one row shows once.
    g.eraseAll(.{});
    put(&g, 3, 0, "z");
    try expectRows(&g, &.{ "", "", "", "z", "", "", "" });
}

test "resize larger and smaller" {
    var g: Grid = try .init(testing.allocator, 4, 3);
    defer g.deinit(testing.allocator);
    put(&g, 0, 0, "abcd");
    put(&g, 1, 0, "efgh");
    put(&g, 2, 0, "ijkl");
    g.scrollUp(0, 2, 1, .{});
    put(&g, 2, 0, "mnop");

    try g.resize(testing.allocator, 6, 4, 0);
    try testing.expectEqual(6, g.cols);
    try testing.expectEqual(4, g.rows);
    try testing.expectEqualSlices(u16, &.{ 0, 1, 2, 3 }, g.lines);
    try expectRows(&g, &.{ "efgh", "ijkl", "mnop", "" });
    for (g.row(3)) |cell| try testing.expect(cell.eql(.{}));
    try testing.expect(g.row(0)[5].eql(.{}));

    try g.resize(testing.allocator, 2, 2, 0);
    try expectRows(&g, &.{ "ef", "ij" });
}

test "resize with drop_top" {
    var g: Grid = try .init(testing.allocator, 3, 4);
    defer g.deinit(testing.allocator);
    for (0..4) |y| put(&g, @intCast(y), 0, &.{@intCast('0' + y)});
    try g.resize(testing.allocator, 3, 2, 2);
    try expectRows(&g, &.{ "2", "3" });
    try g.resize(testing.allocator, 3, 3, 1);
    try expectRows(&g, &.{ "3", "", "" });
}

test "resize truncating through a wide character" {
    var g: Grid = try .init(testing.allocator, 6, 2);
    defer g.deinit(testing.allocator);
    put(&g, 0, 0, "aあい");
    put(&g, 1, 0, "あいう");
    try g.resize(testing.allocator, 4, 2, 0);
    try expectRows(&g, &.{ "aあ", "あい" });
    try expectWhole(&g);
    try g.resize(testing.allocator, 3, 2, 0);
    try expectRows(&g, &.{ "aあ", "あ" });
    try expectWhole(&g);
    try g.resize(testing.allocator, 1, 2, 0);
    try expectRows(&g, &.{ "a", "" });
    try expectWhole(&g);
}

test "resize fails without losing the grid" {
    var g: Grid = try .init(testing.allocator, 2, 2);
    defer g.deinit(testing.allocator);
    put(&g, 0, 0, "ab");
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, g.resize(failing.allocator(), 3, 3, 0));
    try expectRows(&g, &.{ "ab", "" });
}

test "eql" {
    try testing.expect(Color.eql(.default, .default));
    try testing.expect(Color.eql(.{ .palette = 3 }, .{ .palette = 3 }));
    try testing.expect(!Color.eql(.{ .palette = 3 }, .{ .palette = 4 }));
    try testing.expect(!Color.eql(.{ .palette = 0 }, .default));
    try testing.expect(Color.eql(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }));
    try testing.expect(!Color.eql(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .{ .rgb = .{ .r = 1, .g = 2, .b = 4 } }));
    try testing.expect(!Color.eql(.{ .rgb = .{ .r = 0, .g = 0, .b = 0 } }, .{ .palette = 0 }));

    try testing.expect(Style.eql(.{}, .{}));
    try testing.expect(Style.eql(red, .{ .bg = .{ .palette = 1 } }));
    try testing.expect(!Style.eql(red, .{ .fg = .{ .palette = 1 } }));
    try testing.expect(!Style.eql(.{ .attrs = .{ .bold = true } }, .{}));
    try testing.expect(!Style.eql(.{ .attrs = .{ .strikethrough = true } }, .{ .attrs = .{ .bold = true } }));

    try testing.expect(Cell.eql(.{}, .{}));
    try testing.expect(!Cell.eql(.{ .cp = 'a' }, .{ .cp = 'b' }));
    try testing.expect(!Cell.eql(.{ .cp = 'a', .wide = .head }, .{ .cp = 'a' }));
    try testing.expect(!Cell.eql(.{ .style = red }, .{}));
    // The code point of a spacer is ignored.
    try testing.expect(Cell.eql(.{ .cp = 'a', .wide = .spacer }, .{ .wide = .spacer }));

    // A blank keeps only the background.
    const styled: Style = .{ .fg = .{ .palette = 2 }, .bg = .{ .palette = 1 }, .attrs = .{ .underline = true } };
    try testing.expect(Cell.blank(styled).eql(.{ .style = red }));
}
