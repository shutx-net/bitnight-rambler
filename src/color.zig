//! Colors as written in rambler palettes, and how they map onto terminals.

const std = @import("std");

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    /// Parses `#rrggbb`.
    pub fn parseHex(text: []const u8) ?Rgb {
        if (text.len != 7 or text[0] != '#') return null;
        var channels: [3]u8 = undefined;
        for (&channels, 0..) |*channel, i| {
            const hi = std.fmt.charToDigit(text[1 + 2 * i], 16) catch return null;
            const lo = std.fmt.charToDigit(text[2 + 2 * i], 16) catch return null;
            channel.* = hi * 16 + lo;
        }
        return .{ .r = channels[0], .g = channels[1], .b = channels[2] };
    }

    pub fn eql(a: Rgb, b: Rgb) bool {
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }

    /// The nearest entry of the xterm 256-color palette, picking between the
    /// 6×6×6 color cube and the 24-step gray ramp.
    pub fn to256(c: Rgb) u8 {
        const ri = cubeIndex(c.r);
        const gi = cubeIndex(c.g);
        const bi = cubeIndex(c.b);
        const cube: Rgb = .{ .r = cube_levels[ri], .g = cube_levels[gi], .b = cube_levels[bi] };

        const average = (@as(u16, c.r) + c.g + c.b) / 3;
        const gray_index: u8 = if (average < 8) 0 else @intCast(@min(23, (average - 3) / 10));
        const gray_level = 8 + 10 * gray_index;
        const gray: Rgb = .{ .r = gray_level, .g = gray_level, .b = gray_level };

        if (distance(c, gray) < distance(c, cube)) return 232 + gray_index;
        return 16 + 36 * ri + 6 * gi + bi;
    }

    const cube_levels = [6]u8{ 0, 95, 135, 175, 215, 255 };

    fn cubeIndex(v: u8) u8 {
        if (v < 48) return 0;
        if (v < 115) return 1;
        return (v - 35) / 40;
    }

    fn distance(a: Rgb, b: Rgb) u32 {
        const dr = @as(i32, a.r) - b.r;
        const dg = @as(i32, a.g) - b.g;
        const db = @as(i32, a.b) - b.b;
        return @intCast(dr * dr + dg * dg + db * db);
    }
};

/// How colors are written to the terminal.
pub const Mode = enum {
    truecolor,
    @"256",

    /// Terminals advertise 24-bit color through `COLORTERM`; anything else
    /// gets the 256-color palette, which practically every terminal supports.
    pub fn detect(colorterm: ?[]const u8) Mode {
        const value = colorterm orelse return .@"256";
        if (std.mem.eql(u8, value, "truecolor") or std.mem.eql(u8, value, "24bit")) return .truecolor;
        return .@"256";
    }
};

/// Maps the single-character symbols used in sprite files to colors.
pub const Palette = struct {
    colors: [128]?Rgb = @splat(null),

    pub fn get(p: *const Palette, symbol: u8) ?Rgb {
        return if (symbol < p.colors.len) p.colors[symbol] else null;
    }

    pub fn set(p: *Palette, symbol: u8, color: Rgb) void {
        p.colors[symbol] = color;
    }
};

test "Rgb.parseHex" {
    try std.testing.expectEqual(Rgb{ .r = 0xf2, .g = 0xa6, .b = 0x5a }, Rgb.parseHex("#f2a65a").?);
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 0, .b = 0xff }, Rgb.parseHex("#0000FF").?);
    try std.testing.expectEqual(null, Rgb.parseHex("f2a65a"));
    try std.testing.expectEqual(null, Rgb.parseHex("#f2a65"));
    try std.testing.expectEqual(null, Rgb.parseHex("#+f+f+f"));
    try std.testing.expectEqual(null, Rgb.parseHex("#gg0000"));
}

test "Rgb.to256" {
    try std.testing.expectEqual(16, Rgb.to256(.{ .r = 0, .g = 0, .b = 0 }));
    try std.testing.expectEqual(231, Rgb.to256(.{ .r = 255, .g = 255, .b = 255 }));
    try std.testing.expectEqual(196, Rgb.to256(.{ .r = 255, .g = 0, .b = 0 }));
    try std.testing.expectEqual(21, Rgb.to256(.{ .r = 0, .g = 0, .b = 255 }));
    // Mid grays are closer to the gray ramp than to the cube.
    try std.testing.expectEqual(244, Rgb.to256(.{ .r = 128, .g = 128, .b = 128 }));
}

test "Mode.detect" {
    try std.testing.expectEqual(.truecolor, Mode.detect("truecolor"));
    try std.testing.expectEqual(.truecolor, Mode.detect("24bit"));
    try std.testing.expectEqual(.@"256", Mode.detect(null));
    try std.testing.expectEqual(.@"256", Mode.detect("yes"));
}
