//! A framebuffer of logical pixels. Every terminal cell shows two of them
//! stacked vertically, so a canvas is twice as tall as the terminal is.

const Canvas = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const color = @import("color.zig");
const Rgb = color.Rgb;
const sprite = @import("sprite.zig");

width: u16,
height: u16,
/// Row-major. Null is transparent, i.e. the terminal's own background.
pixels: []?Rgb,

pub fn init(gpa: Allocator, width: u16, height: u16) Allocator.Error!Canvas {
    const pixels = try gpa.alloc(?Rgb, @as(usize, width) * height);
    @memset(pixels, null);
    return .{ .width = width, .height = height, .pixels = pixels };
}

pub fn deinit(c: *Canvas, gpa: Allocator) void {
    gpa.free(c.pixels);
    c.* = undefined;
}

/// Resizes and clears the canvas.
pub fn resize(c: *Canvas, gpa: Allocator, width: u16, height: u16) Allocator.Error!void {
    const resized = try init(gpa, width, height);
    c.deinit(gpa);
    c.* = resized;
}

pub fn clear(c: *Canvas) void {
    @memset(c.pixels, null);
}

pub fn get(c: *const Canvas, x: usize, y: usize) ?Rgb {
    return c.pixels[y * c.width + x];
}

/// Which ways to flip a sprite when drawing it. Flips let contributors draw
/// only one direction: a rambler heading left or onto the left wall is
/// mirrored, and one heading down a wall is turned upside down.
pub const Flip = struct {
    /// Mirror left to right.
    x: bool = false,
    /// Turn upside down.
    y: bool = false,
};

/// Draws `s` with its top-left corner at (`x`, `y`), clipped to the canvas,
/// flipped as `flip` says.
pub fn drawSprite(c: *Canvas, s: sprite.Sprite, palette: *const color.Palette, x: i32, y: i32, flip: Flip) void {
    for (0..s.height) |sy| {
        const cy = y + @as(i32, @intCast(sy));
        if (cy < 0 or cy >= c.height) continue;
        for (0..s.width) |sx| {
            const cx = x + @as(i32, @intCast(sx));
            if (cx < 0 or cx >= c.width) continue;
            const symbol = s.at(
                if (flip.x) s.width - 1 - sx else sx,
                if (flip.y) s.height - 1 - sy else sy,
            );
            if (symbol == sprite.transparent) continue;
            c.pixels[@as(usize, @intCast(cy)) * c.width + @as(usize, @intCast(cx))] = palette.get(symbol);
        }
    }
}

test drawSprite {
    const gpa = std.testing.allocator;
    var canvas: Canvas = try .init(gpa, 4, 2);
    defer canvas.deinit(gpa);

    var palette: color.Palette = .{};
    const red: Rgb = .{ .r = 255, .g = 0, .b = 0 };
    palette.set('r', red);
    const s: sprite.Sprite = .{ .width = 2, .height = 2, .pixels = "r..r" };

    canvas.drawSprite(s, &palette, 3, 0, .{});
    try std.testing.expectEqual(red, canvas.get(3, 0).?);
    try std.testing.expectEqual(null, canvas.get(3, 1));

    canvas.clear();
    canvas.drawSprite(s, &palette, 0, -1, .{ .x = true });
    try std.testing.expectEqual(red, canvas.get(0, 0).?);
    try std.testing.expectEqual(null, canvas.get(1, 0));
    try std.testing.expectEqual(null, canvas.get(0, 1));

    canvas.clear();
    canvas.drawSprite(s, &palette, 0, 0, .{ .y = true });
    try std.testing.expectEqual(null, canvas.get(0, 0));
    try std.testing.expectEqual(red, canvas.get(1, 0).?);
    try std.testing.expectEqual(red, canvas.get(0, 1).?);
    try std.testing.expectEqual(null, canvas.get(1, 1));

    canvas.clear();
    canvas.drawSprite(s, &palette, 0, 0, .{ .x = true, .y = true });
    try std.testing.expectEqual(red, canvas.get(0, 0).?);
    try std.testing.expectEqual(null, canvas.get(1, 0));
    try std.testing.expectEqual(null, canvas.get(0, 1));
    try std.testing.expectEqual(red, canvas.get(1, 1).?);
}

test "drawSprite flips left to right and upside down independently" {
    const gpa = std.testing.allocator;
    var canvas: Canvas = try .init(gpa, 2, 2);
    defer canvas.deinit(gpa);

    var palette: color.Palette = .{};
    const red: Rgb = .{ .r = 255, .g = 0, .b = 0 };
    palette.set('r', red);
    // rr
    // .r
    const s: sprite.Sprite = .{ .width = 2, .height = 2, .pixels = "rr.r" };
    const Case = struct { flip: Flip, empty_x: usize, empty_y: usize };
    const cases = [_]Case{
        .{ .flip = .{}, .empty_x = 0, .empty_y = 1 },
        .{ .flip = .{ .x = true }, .empty_x = 1, .empty_y = 1 },
        .{ .flip = .{ .y = true }, .empty_x = 0, .empty_y = 0 },
        .{ .flip = .{ .x = true, .y = true }, .empty_x = 1, .empty_y = 0 },
    };
    for (cases) |case| {
        canvas.clear();
        canvas.drawSprite(s, &palette, 0, 0, case.flip);
        for (0..2) |y| for (0..2) |x| {
            const expected: ?Rgb = if (x == case.empty_x and y == case.empty_y) null else red;
            try std.testing.expectEqual(expected, canvas.get(x, y));
        };
    }
}
