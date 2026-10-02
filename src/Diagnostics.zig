//! Collects every problem found while loading ramblers, so that a single
//! `rambit validate` run reports all of them instead of stopping at the first.

const Diagnostics = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Owns the messages. Expected to be an arena.
arena: Allocator,
items: std.ArrayList(Item) = .empty,

pub const Severity = enum { @"error", warning };

pub const Item = struct {
    severity: Severity,
    /// Path of the offending file, as shown to the user.
    file: []const u8,
    /// 1-based; 0 when the problem is not tied to a line.
    line: u32 = 0,
    /// 1-based; 0 when the problem is not tied to a column.
    column: u32 = 0,
    message: []const u8,
};

pub fn init(arena: Allocator) Diagnostics {
    return .{ .arena = arena };
}

pub fn add(
    d: *Diagnostics,
    severity: Severity,
    file: []const u8,
    line: u32,
    column: u32,
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    try d.items.append(d.arena, .{
        .severity = severity,
        .file = file,
        .line = line,
        .column = column,
        .message = try std.fmt.allocPrint(d.arena, fmt, args),
    });
}

pub fn err(d: *Diagnostics, file: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    return d.add(.@"error", file, 0, 0, fmt, args);
}

pub fn errAt(d: *Diagnostics, file: []const u8, line: u32, column: u32, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    return d.add(.@"error", file, line, column, fmt, args);
}

pub fn warn(d: *Diagnostics, file: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
    return d.add(.warning, file, 0, 0, fmt, args);
}

pub fn count(d: *const Diagnostics, severity: Severity) usize {
    var n: usize = 0;
    for (d.items.items) |item| {
        if (item.severity == severity) n += 1;
    }
    return n;
}

pub fn errorCount(d: *const Diagnostics) usize {
    return d.count(.@"error");
}

/// Writes each item as `severity: file:line:column: message`, the format
/// most editors and CI log viewers can link back to the source.
pub fn render(d: *const Diagnostics, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (d.items.items) |item| {
        try w.print("{t}: {s}", .{ item.severity, item.file });
        if (item.line != 0) {
            try w.print(":{d}", .{item.line});
            if (item.column != 0) try w.print(":{d}", .{item.column});
        }
        try w.print(": {s}\n", .{item.message});
    }
}

test render {
    var arena_state: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_state.deinit();
    var d: Diagnostics = .init(arena_state.allocator());

    try d.errAt("cat/walk-0.sprite", 3, 7, "'{c}' is not in the palette", .{'x'});
    try d.warn("cat/old.sprite", "not used by any animation", .{});
    try std.testing.expectEqual(1, d.errorCount());

    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try d.render(&w);
    try std.testing.expectEqualStrings(
        \\error: cat/walk-0.sprite:3:7: 'x' is not in the palette
        \\warning: cat/old.sprite: not used by any animation
        \\
    , w.buffered());
}
