//! A rambler: its manifest plus the sprites its animations refer to.
//!
//! `load` doubles as the validator. It reports every problem it finds to a
//! `Diagnostics` and only returns a `Rambler` when there were none, so the
//! engine never has to deal with malformed assets.
//!
//! ```json
//! {
//!   "id": "cat",
//!   "name": "Cat",
//!   "description": "A tabby that strolls along the bottom of your terminal.",
//!   "width": 16,
//!   "height": 12,
//!   "facing": "right",
//!   "palette": { "k": "#2b2233", "o": "#f2a65a" },
//!   "animations": {
//!     "idle": { "frames": ["idle-0", "idle-1"], "frame_ms": 600 },
//!     "walk": { "frames": ["walk-0", "walk-1"], "frame_ms": 140 }
//!   },
//!   "motion": { "speed": 9 }
//! }
//! ```

const Rambler = @This();

const std = @import("std");
const json = std.json;
const Allocator = std.mem.Allocator;
const Diagnostics = @import("Diagnostics.zig");
const Source = @import("Source.zig");
const color = @import("color.zig");
const sprite = @import("sprite.zig");
const Sprite = sprite.Sprite;

id: []const u8,
name: []const u8,
description: []const u8,
width: u16,
height: u16,
/// The direction the sprites are drawn facing. The renderer mirrors them
/// when the rambler moves the other way.
facing: Facing,
palette: color.Palette,
animations: std.EnumArray(Animation.Kind, ?Animation),
/// Movement speed in pixels (that is, terminal columns) per second.
speed: f32,

pub const Facing = enum { left, right };

pub const Animation = struct {
    frames: []const Sprite,
    frame_ms: u32,

    /// Only `idle` and `walk` are used by the engine so far; the others are
    /// accepted so that rambler packs can already provide them.
    pub const Kind = enum { idle, walk, run, sleep, jump };
};

/// Returns the animation for `kind`, falling back to `walk` or `idle`.
/// Validation guarantees that at least one of those two exists.
pub fn animation(r: *const Rambler, kind: Animation.Kind) Animation {
    if (r.animations.get(kind)) |a| return a;
    return r.animations.get(.walk) orelse r.animations.get(.idle).?;
}

pub const limits = struct {
    pub const max_size = 64;
    pub const max_frames = 64;
    pub const min_frame_ms = 20;
    pub const max_frame_ms = 10_000;
    pub const min_speed = 1;
    pub const max_speed = 64;
    pub const max_id_len = 32;
    pub const max_name_len = 64;
    pub const max_description_len = 200;
    pub const max_manifest_bytes = 64 * 1024;
    pub const max_sprite_bytes = 64 * 1024;
};

pub const default_frame_ms = 150;
pub const default_speed = 8;

/// Ids double as command-line arguments, so subcommand names are off limits.
pub const reserved_ids = [_][]const u8{ "list", "validate", "preview", "help", "version" };

pub const LoadError = error{ InvalidRambler, OutOfMemory };

pub fn load(arena: Allocator, source: Source, diag: *Diagnostics) LoadError!Rambler {
    const errors_before = diag.errorCount();
    const manifest_path = try source.path(arena, "manifest.json");
    const text = source.read(arena, "manifest.json", limits.max_manifest_bytes, diag) catch |err| switch (err) {
        error.FileNotFound => {
            try diag.err(manifest_path, "missing manifest.json", .{});
            return error.InvalidRambler;
        },
        error.Unreadable => return error.InvalidRambler,
        error.OutOfMemory => return error.OutOfMemory,
    };
    const root_object = try parseJson(arena, text, manifest_path, diag) orelse return error.InvalidRambler;
    const root: Fields = .{ .members = root_object, .path = "", .file = manifest_path, .diag = diag, .arena = arena };

    try root.rejectUnknown(&.{ "id", "name", "description", "width", "height", "facing", "palette", "animations", "motion" });

    const id = try root.string("id", null, limits.max_id_len) orelse "";
    if (id.len != 0) try checkId(root, id, source.id);
    const name = try root.string("name", null, limits.max_name_len) orelse "";
    const description = try root.string("description", "", limits.max_description_len) orelse "";
    const width = try root.integer("width", null, 1, limits.max_size);
    const height = try root.integer("height", null, 1, limits.max_size);

    const facing_text = try root.string("facing", "right", 5) orelse "right";
    const facing = std.meta.stringToEnum(Facing, facing_text) orelse blk: {
        try root.fail("facing", "expected \"left\" or \"right\"", .{});
        break :blk .right;
    };

    const palette = try parsePalette(root);

    var speed: f64 = default_speed;
    if (try root.object("motion", false)) |motion| {
        try motion.rejectUnknown(&.{"speed"});
        speed = try motion.number("speed", default_speed, limits.min_speed, limits.max_speed) orelse default_speed;
    }

    // Sprites can only be checked against a valid size, and their symbols
    // only against a valid palette.
    const geometry: ?Geometry = if (width != null and height != null) .{
        .width = @intCast(width.?),
        .height = @intCast(height.?),
        .palette = if (palette) |*p| p else null,
    } else null;

    var sprites: SpriteCache = .{ .source = source, .geometry = geometry, .diag = diag };
    const animations = try parseAnimations(root, &sprites);

    if (geometry != null) {
        for (try source.fileNames(arena)) |file_name| {
            const stem = std.mem.cutSuffix(u8, file_name, ".sprite") orelse continue;
            if (!sprites.loaded.contains(stem)) {
                try diag.warn(try source.path(arena, file_name), "not used by any animation", .{});
            }
        }
    }

    if (diag.errorCount() != errors_before) return error.InvalidRambler;
    return .{
        .id = id,
        .name = name,
        .description = description,
        .width = geometry.?.width,
        .height = geometry.?.height,
        .facing = facing,
        .palette = palette.?,
        .animations = animations,
        .speed = @floatCast(speed),
    };
}

fn parseJson(arena: Allocator, text: []const u8, file: []const u8, diag: *Diagnostics) Allocator.Error!?json.ObjectMap {
    var scanner: json.Scanner = .initCompleteInput(arena, text);
    var position: json.Diagnostics = .{};
    scanner.enableDiagnostics(&position);
    const value = json.parseFromTokenSourceLeaky(json.Value, arena, &scanner, .{}) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        const reason = switch (err) {
            error.DuplicateField => "duplicate field",
            error.UnexpectedEndOfInput => "unexpected end of input",
            else => "syntax error",
        };
        try diag.errAt(file, @intCast(position.getLine()), @intCast(position.getColumn()), "invalid JSON: {s}", .{reason});
        return null;
    };
    if (value != .object) {
        try diag.err(file, "expected a JSON object at the top level", .{});
        return null;
    }
    return value.object;
}

fn checkId(root: Fields, id: []const u8, directory_name: []const u8) Allocator.Error!void {
    const well_formed = for (id, 0..) |c, i| {
        switch (c) {
            'a'...'z', '0'...'9' => {},
            '-' => if (i == 0) break false,
            else => break false,
        }
    } else true;
    if (!well_formed) {
        return root.fail("id", "must consist of lowercase letters, digits and '-', and must not start with '-'", .{});
    }
    for (reserved_ids) |reserved| {
        if (std.mem.eql(u8, id, reserved)) return root.fail("id", "\"{s}\" is reserved for a rambit command", .{id});
    }
    if (!std.mem.eql(u8, id, directory_name)) {
        return root.fail("id", "\"{s}\" does not match the directory name \"{s}\"", .{ id, directory_name });
    }
}

fn parsePalette(root: Fields) Allocator.Error!?color.Palette {
    const fields = try root.object("palette", true) orelse return null;
    if (fields.members.count() == 0) {
        try root.fail("palette", "must define at least one color", .{});
        return null;
    }
    var palette: color.Palette = .{};
    var ok = true;
    for (fields.members.keys(), fields.members.values()) |symbol, value| {
        if (symbol.len != 1 or !std.ascii.isPrint(symbol[0]) or symbol[0] == ' ' or symbol[0] == sprite.transparent) {
            try fields.fail(symbol, "palette symbols must be a single printable character other than space and '.'", .{});
            ok = false;
            continue;
        }
        const rgb = switch (value) {
            .string => |hex| color.Rgb.parseHex(hex),
            else => null,
        } orelse {
            try fields.fail(symbol, "expected a color such as \"#f2a65a\"", .{});
            ok = false;
            continue;
        };
        palette.set(symbol[0], rgb);
    }
    return if (ok) palette else null;
}

fn parseAnimations(root: Fields, sprites: *SpriteCache) Allocator.Error!std.EnumArray(Animation.Kind, ?Animation) {
    var animations: std.EnumArray(Animation.Kind, ?Animation) = .initFill(null);
    const fields = try root.object("animations", true) orelse return animations;

    for (fields.members.keys()) |key| {
        const kind = std.meta.stringToEnum(Animation.Kind, key) orelse {
            try fields.fail(key, "unknown animation (expected one of: idle, walk, run, sleep, jump)", .{});
            continue;
        };
        const anim = try fields.object(key, true) orelse continue;
        try anim.rejectUnknown(&.{ "frames", "frame_ms" });
        const frame_ms = try anim.integer("frame_ms", default_frame_ms, limits.min_frame_ms, limits.max_frame_ms);
        const names = try anim.array("frames") orelse continue;
        if (names.len == 0 or names.len > limits.max_frames) {
            try anim.fail("frames", "must list 1 to {d} frames", .{limits.max_frames});
            continue;
        }

        const frames = try root.arena.alloc(Sprite, names.len);
        var complete = true;
        for (names, frames, 0..) |value, *frame, i| {
            const frame_name = switch (value) {
                .string => |s| s,
                else => {
                    try anim.failIndex("frames", i, "expected the name of a sprite file, without \".sprite\"", .{});
                    complete = false;
                    continue;
                },
            };
            if (!isValidFrameName(frame_name)) {
                try anim.failIndex("frames", i, "\"{s}\": frame names may only contain letters, digits, '-' and '_'", .{frame_name});
                complete = false;
                continue;
            }
            if (try sprites.get(root.arena, frame_name)) |s| frame.* = s else complete = false;
        }
        if (complete and frame_ms != null) {
            animations.set(kind, .{ .frames = frames, .frame_ms = @intCast(frame_ms.?) });
        }
    }
    if (fields.members.get("idle") == null and fields.members.get("walk") == null) {
        try root.fail("animations", "must define at least \"idle\" or \"walk\"", .{});
    }
    return animations;
}

fn isValidFrameName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => {},
        else => return false,
    };
    return true;
}

const Geometry = struct {
    width: u16,
    height: u16,
    /// Null when the palette is invalid.
    palette: ?*const color.Palette,
};

/// Loads each sprite file once, however many animations use it.
const SpriteCache = struct {
    source: Source,
    /// Null when the manifest's size is invalid; sprite files are then only
    /// checked for existence.
    geometry: ?Geometry,
    diag: *Diagnostics,
    /// Keyed by frame name; null for files that failed to load.
    loaded: std.StringHashMapUnmanaged(?Sprite) = .empty,

    fn get(c: *SpriteCache, arena: Allocator, frame_name: []const u8) Allocator.Error!?Sprite {
        const entry = try c.loaded.getOrPut(arena, frame_name);
        if (entry.found_existing) return entry.value_ptr.*;
        entry.value_ptr.* = null;

        const file_name = try std.fmt.allocPrint(arena, "{s}.sprite", .{frame_name});
        const file_path = try c.source.path(arena, file_name);
        const text = c.source.read(arena, file_name, limits.max_sprite_bytes, c.diag) catch |err| switch (err) {
            error.FileNotFound => {
                try c.diag.err(file_path, "missing sprite file (referenced as frame \"{s}\")", .{frame_name});
                return null;
            },
            error.Unreadable => return null,
            error.OutOfMemory => return error.OutOfMemory,
        };
        const g = c.geometry orelse return null;
        entry.value_ptr.* = try sprite.parse(arena, text, g.width, g.height, g.palette, c.diag, file_path);
        return entry.value_ptr.*;
    }
};

/// Typed access to the members of a JSON object that reports what is wrong
/// with them, along with where, as a JSON path such as `animations.walk`.
const Fields = struct {
    members: json.ObjectMap,
    /// Empty for the root object.
    path: []const u8,
    file: []const u8,
    diag: *Diagnostics,
    arena: Allocator,

    fn memberPath(f: Fields, key: []const u8) Allocator.Error![]const u8 {
        if (f.path.len == 0) return key;
        return std.fmt.allocPrint(f.arena, "{s}.{s}", .{ f.path, key });
    }

    fn fail(f: Fields, key: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try f.diag.err(f.file, "{s}: " ++ fmt, .{try f.memberPath(key)} ++ args);
    }

    fn failIndex(f: Fields, key: []const u8, index: usize, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try f.diag.err(f.file, "{s}[{d}]: " ++ fmt, .{ try f.memberPath(key), index } ++ args);
    }

    fn rejectUnknown(f: Fields, comptime known: []const []const u8) Allocator.Error!void {
        const expected = comptime blk: {
            var list: []const u8 = "";
            for (known, 0..) |k, i| list = list ++ (if (i == 0) "" else ", ") ++ k;
            break :blk list;
        };
        for (f.members.keys()) |key| {
            for (known) |k| {
                if (std.mem.eql(u8, key, k)) break;
            } else try f.fail(key, "unknown field (expected one of: " ++ expected ++ ")", .{});
        }
    }

    /// Returns `default` when the member is absent; a null `default` makes
    /// the member required. Returns null when it is invalid.
    fn string(f: Fields, key: []const u8, default: ?[]const u8, max_len: usize) Allocator.Error!?[]const u8 {
        const value = f.members.get(key) orelse return f.missing(key, default);
        switch (value) {
            .string => |s| {
                if (s.len == 0 or s.len > max_len) {
                    try f.fail(key, "must be 1 to {d} characters long", .{max_len});
                    return null;
                }
                return s;
            },
            else => {
                try f.fail(key, "expected a string", .{});
                return null;
            },
        }
    }

    fn integer(f: Fields, key: []const u8, default: ?i64, min: i64, max: i64) Allocator.Error!?i64 {
        const value = f.members.get(key) orelse return f.missing(key, default);
        switch (value) {
            .integer => |n| if (n >= min and n <= max) return n,
            else => {},
        }
        try f.fail(key, "expected an integer from {d} to {d}", .{ min, max });
        return null;
    }

    fn number(f: Fields, key: []const u8, default: ?f64, min: f64, max: f64) Allocator.Error!?f64 {
        const value = f.members.get(key) orelse return f.missing(key, default);
        const n: f64 = switch (value) {
            .integer => |n| @floatFromInt(n),
            .float => |n| n,
            else => min - 1,
        };
        if (n >= min and n <= max) return n;
        try f.fail(key, "expected a number from {d} to {d}", .{ min, max });
        return null;
    }

    fn object(f: Fields, key: []const u8, required: bool) Allocator.Error!?Fields {
        const value = f.members.get(key) orelse {
            if (required) try f.fail(key, "required field is missing", .{});
            return null;
        };
        if (value != .object) {
            try f.fail(key, "expected an object", .{});
            return null;
        }
        return .{ .members = value.object, .path = try f.memberPath(key), .file = f.file, .diag = f.diag, .arena = f.arena };
    }

    fn array(f: Fields, key: []const u8) Allocator.Error!?[]const json.Value {
        const value = f.members.get(key) orelse {
            try f.fail(key, "required field is missing", .{});
            return null;
        };
        if (value != .array) {
            try f.fail(key, "expected an array", .{});
            return null;
        }
        return value.array.items;
    }

    fn missing(f: Fields, key: []const u8, default: anytype) Allocator.Error!@TypeOf(default) {
        if (default == null) try f.fail(key, "required field is missing", .{});
        return default;
    }
};

const testing = std.testing;
const builtin_ramblers = @import("builtin_ramblers");

fn loadTest(arena: Allocator, files: []const builtin_ramblers.File, diag: *Diagnostics) LoadError!Rambler {
    return load(arena, Source.embedded(.{ .id = "test", .files = files }), diag);
}

test "load a minimal rambler" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);

    const r = try loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "test", "name": "Test", "width": 2, "height": 2,
        \\  "palette": { "k": "#000000" },
        \\  "animations": { "walk": { "frames": ["a", "b", "a"] } } }
        },
        .{ .name = "a.sprite", .data = "k.\n.k\n" },
        .{ .name = "b.sprite", .data = ".k\nk.\n" },
    }, &diag);

    try testing.expectEqual(0, diag.items.items.len);
    try testing.expectEqual(.right, r.facing);
    try testing.expectEqual(@as(f32, default_speed), r.speed);
    // `idle` falls back to `walk`.
    try testing.expectEqual(3, r.animation(.idle).frames.len);
    try testing.expectEqual(default_frame_ms, r.animation(.walk).frame_ms);
}

test "load reports every problem" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);

    try testing.expectError(error.InvalidRambler, loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "Other", "name": "Test", "width": 2, "height": 99, "speeed": 3,
        \\  "palette": { "k": "#000000", "..": "red" },
        \\  "animations": { "wlak": { "frames": ["a"] }, "idle": { "frames": ["../a", "missing"] } } }
        },
        .{ .name = "a.sprite", .data = "k.\n.k\n" },
    }, &diag));

    const expected = [_][]const u8{
        "speeed: unknown field (expected one of: id, name, description, width, height, facing, palette, animations, motion)",
        "id: must consist of lowercase letters, digits and '-', and must not start with '-'",
        "height: expected an integer from 1 to 64",
        "palette...: palette symbols must be a single printable character other than space and '.'",
        "animations.wlak: unknown animation (expected one of: idle, walk, run, sleep, jump)",
        "animations.idle.frames[0]: \"../a\": frame names may only contain letters, digits, '-' and '_'",
        "missing sprite file (referenced as frame \"missing\")",
    };
    try testing.expectEqual(expected.len, diag.items.items.len);
    for (expected, diag.items.items) |message, item| try testing.expectEqualStrings(message, item.message);
}

test "load reports invalid JSON with its position" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);

    try testing.expectError(error.InvalidRambler, loadTest(arena, &.{
        .{ .name = "manifest.json", .data = "{\n  \"id\": \"test\",\n  \"name\": \"Test\"\n  \"width\": 2\n}\n" },
    }, &diag));
    try testing.expectEqual(1, diag.items.items.len);
    try testing.expectEqual(4, diag.items.items[0].line);
}

test "every built-in rambler is valid" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (builtin_ramblers.entries) |entry| {
        var diag: Diagnostics = .init(arena);
        _ = load(arena, Source.embedded(entry), &diag) catch |err| {
            var buf: [4096]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            diag.render(&w) catch {};
            std.debug.print("{s}", .{w.buffered()});
            return err;
        };
        try testing.expectEqual(0, diag.items.items.len);
    }
}
