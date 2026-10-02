//! Where a rambler's files come from: the copies embedded into the binary at
//! build time, or a directory on disk (for development and `rambit validate`).

const Source = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Diagnostics = @import("Diagnostics.zig");
const builtin_ramblers = @import("builtin_ramblers");

/// The id the manifest must declare: the name of the rambler's directory.
id: []const u8,
/// Prefix for file paths in messages, e.g. `ramblers/cat`.
label: []const u8,
backing: union(enum) {
    embedded: []const builtin_ramblers.File,
    dir: struct { io: Io, dir: Io.Dir },
},

pub fn embedded(entry: builtin_ramblers.Entry) Source {
    return .{ .id = entry.id, .label = entry.id, .backing = .{ .embedded = entry.files } };
}

/// `dir` must be opened with `.iterate = true` and stay open while the
/// source is in use.
pub fn directory(arena: Allocator, io: Io, dir: Io.Dir, dir_path: []const u8) Allocator.Error!Source {
    // Resolve the real path so that `.` and `..` still yield the directory name.
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const real = if (dir.realPath(io, &buffer)) |len| buffer[0..len] else |_| dir_path;
    return .{
        .id = try arena.dupe(u8, std.fs.path.basename(real)),
        .label = std.mem.trimEnd(u8, dir_path, "/"),
        .backing = .{ .dir = .{ .io = io, .dir = dir } },
    };
}

/// The path of `name` as shown in messages.
pub fn path(s: Source, arena: Allocator, name: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ s.label, name });
}

pub const ReadError = error{
    FileNotFound,
    /// The problem has already been reported to the diagnostics.
    Unreadable,
    OutOfMemory,
};

/// Reads the file `name`, which may be at most `limit` bytes long.
pub fn read(s: Source, arena: Allocator, name: []const u8, limit: usize, diag: *Diagnostics) ReadError![]const u8 {
    const data = switch (s.backing) {
        .embedded => |files| for (files) |file| {
            if (std.mem.eql(u8, file.name, name)) break file.data;
        } else return error.FileNotFound,
        .dir => |d| d.dir.readFileAlloc(d.io, name, arena, .limited(limit + 1)) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            error.OutOfMemory => return error.OutOfMemory,
            error.StreamTooLong => return tooLarge(s, arena, name, limit, diag),
            else => {
                try diag.err(try s.path(arena, name), "unable to read: {t}", .{err});
                return error.Unreadable;
            },
        },
    };
    if (data.len > limit) return tooLarge(s, arena, name, limit, diag);
    return data;
}

fn tooLarge(s: Source, arena: Allocator, name: []const u8, limit: usize, diag: *Diagnostics) ReadError {
    try diag.err(try s.path(arena, name), "file is larger than {d} bytes", .{limit});
    return error.Unreadable;
}

/// Names of the regular files in the source, in no particular order.
pub fn fileNames(s: Source, arena: Allocator) error{OutOfMemory}![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    switch (s.backing) {
        .embedded => |files| for (files) |file| try names.append(arena, file.name),
        .dir => |d| {
            var it = d.dir.iterate();
            while (it.next(d.io) catch null) |entry| {
                if (entry.kind == .file) try names.append(arena, try arena.dupe(u8, entry.name));
            }
        },
    }
    return names.items;
}
