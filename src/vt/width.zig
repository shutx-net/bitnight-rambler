//! How many cells a code point takes up on the screen, from the table that
//! tools/width_table.py generates. Combining marks, format characters and
//! Hangul medial vowels and final consonants take up none, as they join the
//! character before them; East Asian wide and fullwidth characters take up
//! two; everything else, ambiguous-width characters included, takes up one.
//! Control characters never get here: the parser executes them.

const std = @import("std");
const table = @import("width_table.zig");

/// The Unicode version the table was generated from.
pub const unicode_version = table.unicode_version;

/// The number of cells `cp` takes up: 0, 1 or 2.
pub fn codepointWidth(cp: u21) u2 {
    if (cp < 0x300) return 1;
    if (inRanges(&table.wide, cp)) return 2;
    if (inRanges(&table.zero, cp)) return 0;
    return 1;
}

/// Whether `cp` is in one of `ranges`, which are sorted, disjoint and
/// inclusive at both ends.
fn inRanges(ranges: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

test codepointWidth {
    const cases = [_]struct { u21, u2 }{
        .{ 'A', 1 },
        .{ 0x00E9, 1 }, // e with acute, precomposed
        .{ 0x00AD, 1 }, // soft hyphen
        .{ 0x0301, 0 }, // combining acute accent
        .{ 0x200B, 0 }, // zero width space
        .{ 0x200D, 0 }, // zero width joiner
        .{ 0xFE0F, 0 }, // variation selector 16
        .{ 0x1160, 0 }, // Hangul jungseong filler
        .{ 0x3042, 2 }, // hiragana a
        .{ 0x6F22, 2 }, // CJK ideograph
        .{ 0xAC00, 2 }, // Hangul syllable ga
        .{ 0xFF21, 2 }, // fullwidth A
        .{ 0xFF71, 1 }, // halfwidth katakana a
        .{ 0x3000, 2 }, // ideographic space
        .{ 0x1F600, 2 }, // grinning face
        .{ 0x20000, 2 }, // CJK extension B
        .{ 0x2FFFD, 2 }, // unassigned, default wide
        .{ 0x2500, 1 }, // box drawing, ambiguous
        .{ 0xE000, 1 }, // private use
        .{ 0x0600, 1 }, // Arabic number sign
        .{ 0x302A, 0 }, // ideographic level tone mark
        .{ 0x3099, 0 }, // combining katakana-hiragana voiced sound mark
        .{ 0x10FFFF, 1 },
    };
    for (cases) |case| {
        try std.testing.expectEqual(case[1], codepointWidth(case[0]));
    }
}

test "the tables are sorted and disjoint" {
    for ([_][]const [2]u21{ &table.zero, &table.wide }) |ranges| {
        for (ranges, 0..) |range, i| {
            try std.testing.expect(range[0] <= range[1]);
            if (i + 1 < ranges.len) try std.testing.expect(range[1] < ranges[i + 1][0]);
        }
    }
    var i: usize = 0;
    var j: usize = 0;
    while (i < table.zero.len and j < table.wide.len) {
        const zero = table.zero[i];
        const wide = table.wide[j];
        try std.testing.expect(zero[1] < wide[0] or wide[1] < zero[0]);
        if (zero[1] < wide[1]) i += 1 else j += 1;
    }
}
