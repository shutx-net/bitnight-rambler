//! Lays a rambler's canvas over the emulator's screen for `rambit shell`.
//!
//! Wherever the canvas has a pixel, the sprite covers the text below it,
//! drawn with the same half blocks as `rambit <name>`. A half left
//! transparent shows the background of the covered cell, so a rambler
//! walking over a colored status line keeps that color around it.

const std = @import("std");
const assert = std.debug.assert;
const Canvas = @import("Canvas.zig");
const Grid = @import("vt/Grid.zig");
const Screen = @import("Screen.zig");
const color = @import("color.zig");

const Cell = Grid.Cell;
const Color = Grid.Color;

/// Fills `out`, `text.cols` by `text.rows` cells, with the text of `text`
/// and, when given, `canvas` drawn over it. The canvas must be as wide as
/// the grid and twice as tall.
pub fn compose(out: []Cell, text: *const Grid, canvas: ?*const Canvas) void {
    const cols: usize = text.cols;
    assert(out.len == cols * text.rows);
    for (0..text.rows) |y| @memcpy(out[y * cols ..][0..cols], text.row(@intCast(y)));
    const c = canvas orelse return;
    assert(c.width == text.cols and c.height == 2 * @as(u32, text.rows));

    for (0..text.rows) |y| {
        const cells = out[y * cols ..][0..cols];
        const below = text.row(@intCast(y));
        for (cells, below, 0..) |*cell, covered, x| {
            const top = c.get(x, 2 * y);
            const bottom = c.get(x, 2 * y + 1);
            if (top == null and bottom == null) continue;
            cell.* = spriteCell(.fromPixels(top, bottom), background(covered.style));
        }
        // A wide character with one half under the sprite cannot be shown
        // whole; the half left over becomes a blank.
        for (cells, below, 0..) |*cell, covered, x| {
            const broken = switch (cell.wide) {
                .narrow => false,
                .head => x + 1 == cols or cells[x + 1].wide != .spacer,
                .spacer => x == 0 or cells[x - 1].wide != .head,
            };
            if (broken) cell.* = .{ .style = .{ .bg = background(covered.style) } };
        }
    }
}

/// The color that fills a cell around its character.
fn background(style: Grid.Style) Color {
    if (!style.attrs.inverse) return style.bg;
    // The terminal's default foreground color cannot be named.
    return if (style.fg == .default) .default else style.fg;
}

/// A cell of `rambit <name>` as a grid cell, with `under` for a transparent
/// half.
fn spriteCell(pixels: Screen.Cell, under: Color) Cell {
    return .{
        .cp = switch (pixels.glyph) {
            .blank => ' ',
            .upper => 0x2580,
            .lower => 0x2584,
        },
        .style = .{
            .fg = rgbOr(pixels.fg, .default),
            .bg = rgbOr(pixels.bg, under),
        },
    };
}

fn rgbOr(c: ?color.Rgb, otherwise: Color) Color {
    return if (c) |rgb| .{ .rgb = rgb } else otherwise;
}

const testing = std.testing;
const red_rgb: color.Rgb = .{ .r = 255, .g = 0, .b = 0 };
const green_rgb: color.Rgb = .{ .r = 0, .g = 255, .b = 0 };

fn expectCell(expected: Cell, actual: Cell) !void {
    if (!expected.eql(actual)) {
        std.debug.print("expected {any}, found {any}\n", .{ expected, actual });
        return error.TestExpectedEqual;
    }
}

const Fixture = struct {
    grid: Grid,
    canvas: Canvas,
    out: []Cell,

    fn init(cols: u16, rows: u16) !Fixture {
        const gpa = testing.allocator;
        var grid: Grid = try .init(gpa, cols, rows);
        errdefer grid.deinit(gpa);
        var canvas: Canvas = try .init(gpa, cols, 2 * rows);
        errdefer canvas.deinit(gpa);
        const out = try gpa.alloc(Cell, @as(usize, cols) * rows);
        return .{ .grid = grid, .canvas = canvas, .out = out };
    }

    fn deinit(f: *Fixture) void {
        const gpa = testing.allocator;
        f.grid.deinit(gpa);
        f.canvas.deinit(gpa);
        gpa.free(f.out);
    }

    fn set(f: *Fixture, x: usize, y: usize, rgb: color.Rgb) void {
        f.canvas.pixels[y * f.canvas.width + x] = rgb;
    }
};

test "without a canvas the text is copied" {
    var f: Fixture = try .init(3, 2);
    defer f.deinit();
    f.grid.row(0)[0] = .{ .cp = 'a', .style = .{ .attrs = .{ .bold = true } } };
    f.grid.row(1)[1] = .{ .cp = 0x3042, .wide = .head };
    f.grid.row(1)[2] = .{ .wide = .spacer };
    // Scrolled storage is read through the screen rows.
    f.grid.scrollUp(0, 1, 1, .{});
    f.grid.row(1)[2] = .{ .cp = 'z' };
    compose(f.out, &f.grid, null);
    try expectCell(f.grid.row(0)[1], f.out[1]);
    try expectCell(.{ .cp = 0x3042, .wide = .head }, f.out[1]);
    try expectCell(.{ .wide = .spacer }, f.out[2]);
    try expectCell(.{ .cp = 'z' }, f.out[5]);
    for (f.out[3..5]) |cell| try expectCell(.{}, cell);

    // An empty canvas changes nothing either.
    compose(f.out, &f.grid, &f.canvas);
    try expectCell(.{ .cp = 0x3042, .wide = .head }, f.out[1]);
    try expectCell(.{ .cp = 'z' }, f.out[5]);
}

test "a sprite covers a letter" {
    var f: Fixture = try .init(2, 1);
    defer f.deinit();
    f.grid.row(0)[0] = .{ .cp = 'a', .style = .{ .fg = .{ .palette = 2 }, .attrs = .{ .underline = true } } };
    f.grid.row(0)[1] = .{ .cp = 'b' };
    f.set(0, 0, red_rgb);
    f.set(0, 1, green_rgb);
    compose(f.out, &f.grid, &f.canvas);
    try expectCell(.{ .cp = 0x2580, .style = .{ .fg = .{ .rgb = red_rgb }, .bg = .{ .rgb = green_rgb } } }, f.out[0]);
    try expectCell(.{ .cp = 'b' }, f.out[1]);
}

test "a transparent half shows the covered background" {
    var f: Fixture = try .init(3, 1);
    defer f.deinit();
    f.grid.row(0)[0] = .{ .cp = 'a', .style = .{ .bg = .{ .palette = 1 } } };
    f.grid.row(0)[1] = .{ .cp = 'b', .style = .{ .fg = .{ .palette = 4 }, .attrs = .{ .inverse = true } } };
    f.grid.row(0)[2] = .{ .cp = 'c', .style = .{ .bg = .{ .palette = 1 }, .attrs = .{ .inverse = true } } };
    f.set(0, 0, green_rgb);
    f.set(1, 0, green_rgb);
    f.set(2, 1, green_rgb);
    compose(f.out, &f.grid, &f.canvas);
    try expectCell(.{ .cp = 0x2580, .style = .{ .fg = .{ .rgb = green_rgb }, .bg = .{ .palette = 1 } } }, f.out[0]);
    // Inverse video shows the foreground color as the background.
    try expectCell(.{ .cp = 0x2580, .style = .{ .fg = .{ .rgb = green_rgb }, .bg = .{ .palette = 4 } } }, f.out[1]);
    // ... and the default foreground, which has no name, as the default.
    try expectCell(.{ .cp = 0x2584, .style = .{ .fg = .{ .rgb = green_rgb } } }, f.out[2]);
}

test "two equal pixels make a blank in their color" {
    var f: Fixture = try .init(1, 1);
    defer f.deinit();
    f.grid.row(0)[0] = .{ .cp = 'a', .style = .{ .bg = .{ .palette = 1 } } };
    f.set(0, 0, red_rgb);
    f.set(0, 1, red_rgb);
    compose(f.out, &f.grid, &f.canvas);
    try expectCell(.{ .style = .{ .bg = .{ .rgb = red_rgb } } }, f.out[0]);
}

test "covering half of a wide character blanks the other half" {
    var f: Fixture = try .init(4, 1);
    defer f.deinit();
    const style: Grid.Style = .{ .fg = .{ .palette = 3 }, .bg = .{ .palette = 5 } };
    for (0..2) |i| {
        f.grid.row(0)[2 * i] = .{ .cp = 0x3042, .wide = .head, .style = style };
        f.grid.row(0)[2 * i + 1] = .{ .wide = .spacer, .style = style };
    }
    // The spacer of the first, the head of the second.
    f.set(1, 0, red_rgb);
    f.set(2, 1, red_rgb);
    compose(f.out, &f.grid, &f.canvas);
    try expectCell(.{ .style = .{ .bg = .{ .palette = 5 } } }, f.out[0]);
    try expectCell(.{ .cp = 0x2580, .style = .{ .fg = .{ .rgb = red_rgb }, .bg = .{ .palette = 5 } } }, f.out[1]);
    try expectCell(.{ .cp = 0x2584, .style = .{ .fg = .{ .rgb = red_rgb }, .bg = .{ .palette = 5 } } }, f.out[2]);
    try expectCell(.{ .style = .{ .bg = .{ .palette = 5 } } }, f.out[3]);
}
