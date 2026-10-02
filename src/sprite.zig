//! Sprite files: a grid of palette symbols, one text line per pixel row.
//!
//! ```text
//! ....kk....kk....
//! ...kook..kook...
//! ```
//!
//! `.` is transparent; every other symbol must be defined in the rambler's
//! palette. Trailing empty lines and `\r\n` line endings are tolerated so that
//! editors do not get in the way.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Diagnostics = @import("Diagnostics.zig");
const Palette = @import("color.zig").Palette;

pub const transparent = '.';

pub const Sprite = struct {
    width: u16,
    height: u16,
    /// Row-major palette symbols; `transparent` marks empty pixels.
    pixels: []const u8,

    pub fn at(s: Sprite, x: usize, y: usize) u8 {
        return s.pixels[y * s.width + x];
    }
};

/// Stop reporting after this many problems in one file; a sprite drawn with
/// the wrong palette would otherwise produce one error per pixel.
const max_reported = 8;

/// Parses `text` as a `width`×`height` sprite. Problems are reported to
/// `diag` against `file`; returns null if there were any. Without a
/// `palette` (because the manifest's is invalid), any printable symbol is
/// accepted, so that the other checks still run.
pub fn parse(
    arena: Allocator,
    text: []const u8,
    width: u16,
    height: u16,
    palette: ?*const Palette,
    diag: *Diagnostics,
    file: []const u8,
) Allocator.Error!?Sprite {
    const pixels = try arena.alloc(u8, @as(usize, width) * height);
    var problems: usize = 0;

    const body = std.mem.trimEnd(u8, text, "\r\n");
    if (body.len == 0) {
        try diag.err(file, "sprite is empty", .{});
        return null;
    }
    var lines = std.mem.splitScalar(u8, body, '\n');
    var y: u32 = 0;
    while (lines.next()) |raw_line| : (y += 1) {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (y >= height) {
            const rows = y + 1 + countRemaining(&lines);
            try diag.errAt(file, y + 1, 0, "expected {d} rows, found {d}", .{ height, rows });
            return null;
        }
        if (line.len != width) {
            try diag.errAt(file, y + 1, 0, "expected {d} pixels in this row, found {d}", .{ width, line.len });
            problems += 1;
            if (problems >= max_reported) return null;
            continue;
        }
        for (line, 0..) |symbol, x| {
            const column: u32 = @intCast(x + 1);
            if (symbol == ' ') {
                try diag.errAt(file, y + 1, column, "use '.' rather than a space for transparent pixels", .{});
            } else if (!std.ascii.isPrint(symbol)) {
                try diag.errAt(file, y + 1, column, "unsupported byte 0x{x:0>2}; use palette symbols and '.'", .{symbol});
            } else if (symbol != transparent and palette != null and palette.?.get(symbol) == null) {
                try diag.errAt(file, y + 1, column, "'{c}' is not defined in the palette", .{symbol});
            } else {
                pixels[y * @as(usize, width) + x] = symbol;
                continue;
            }
            problems += 1;
            if (problems >= max_reported) return null;
        }
    }
    if (y < height) {
        try diag.errAt(file, 0, 0, "expected {d} rows, found {d}", .{ height, y });
        return null;
    }
    if (problems != 0) return null;
    return .{ .width = width, .height = height, .pixels = pixels };
}

fn countRemaining(lines: *std.mem.SplitIterator(u8, .scalar)) u32 {
    var n: u32 = 0;
    while (lines.next()) |_| n += 1;
    return n;
}

const testing = std.testing;

fn testPalette() Palette {
    var palette: Palette = .{};
    palette.set('k', .{ .r = 0, .g = 0, .b = 0 });
    palette.set('o', .{ .r = 255, .g = 160, .b = 80 });
    return palette;
}

test "parse a valid sprite" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);
    const palette = testPalette();

    const sprite = (try parse(arena, ".k.\r\nkok\n.k.\n\n", 3, 3, &palette, &diag, "t.sprite")).?;
    try testing.expectEqual(0, diag.items.items.len);
    try testing.expectEqual('o', sprite.at(1, 1));
    try testing.expectEqual(transparent, sprite.at(0, 0));
}

test "parse reports every kind of problem" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const palette = testPalette();

    var diag: Diagnostics = .init(arena);
    try testing.expectEqual(null, try parse(arena, ".k.\nkxk\n.k\n", 3, 3, &palette, &diag, "t.sprite"));
    try testing.expectEqual(2, diag.errorCount());
    try testing.expectEqual(2, diag.items.items[0].line);
    try testing.expectEqual(2, diag.items.items[0].column);
    try testing.expectEqual(3, diag.items.items[1].line);

    diag = .init(arena);
    try testing.expectEqual(null, try parse(arena, "...\n...\n...\n...\n", 3, 3, &palette, &diag, "t.sprite"));
    try testing.expectEqualStrings("expected 3 rows, found 4", diag.items.items[0].message);

    diag = .init(arena);
    try testing.expectEqual(null, try parse(arena, "...\n", 3, 3, &palette, &diag, "t.sprite"));
    try testing.expectEqualStrings("expected 3 rows, found 1", diag.items.items[0].message);

    diag = .init(arena);
    try testing.expectEqual(null, try parse(arena, ". .\n", 3, 1, &palette, &diag, "t.sprite"));
    try testing.expectEqualStrings("use '.' rather than a space for transparent pixels", diag.items.items[0].message);
}

test "parse without a palette still checks the shape" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);

    try testing.expect(try parse(arena, "xy\nzw\n", 2, 2, null, &diag, "t.sprite") != null);
    try testing.expectEqual(null, try parse(arena, "xy\nz\n", 2, 2, null, &diag, "t.sprite"));
    try testing.expectEqual(1, diag.errorCount());
}
