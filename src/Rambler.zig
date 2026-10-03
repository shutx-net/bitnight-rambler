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
//!   "description": "A tabby that strolls around the edges of your terminal.",
//!   "width": 16,
//!   "height": 12,
//!   "facing": "right",
//!   "palette": { "k": "#2b2233", "o": "#f2a65a" },
//!   "animations": {
//!     "idle": { "frames": ["idle-0", "idle-1"], "frame_ms": 600 },
//!     "walk": { "frames": ["walk-0", "walk-1"], "frame_ms": 140 }
//!   },
//!   "wall_animations": {
//!     "walk": { "frames": ["climb-0", "climb-1"], "frame_ms": 160 }
//!   },
//!   "ceiling_animations": {
//!     "walk": { "frames": ["ceiling-walk-0", "ceiling-walk-1"] }
//!   },
//!   "edges": ["bottom", "left", "right", "top"],
//!   "motion": { "speed": 9 }
//! }
//! ```
//!
//! Only `animations` is required among the sets. `wall_animations` are
//! drawn on the right-hand wall heading up, so their frames are `height`
//! wide and `width` tall; `ceiling_animations` are drawn as they look
//! against the top. `edges` defaults to every edge there are animations
//! for, so here it could be left out.

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
/// One set per surface, from `animations`, `wall_animations` and
/// `ceiling_animations`; only the floor's is required.
animations: std.EnumArray(Surface, Animations),
/// The edges the rambler walks along, from `edges`: always the bottom,
/// plus those it has the animations for and the manifest lists.
edges: std.EnumSet(Edge),
/// Movement speed in pixels (that is, terminal columns) per second.
speed: f32,
/// Speed while running, in pixels per second; only used with a `run`
/// animation.
run_speed: f32,
/// How high a jump goes, in pixels; only used with a `jump` animation.
jump_height: u16,

pub const Facing = enum { left, right };

/// An edge of the terminal that a rambler can walk along. Listed in the
/// order that previews and messages use.
pub const Edge = enum {
    bottom,
    left,
    right,
    top,

    /// The surface the rambler walks on along this edge.
    pub fn surface(e: Edge) Surface {
        return switch (e) {
            .bottom => .floor,
            .left, .right => .wall,
            .top => .ceiling,
        };
    }
};

/// What a rambler walks on, each with its own set of animations: the
/// floor along the bottom edge, a wall along either side, the ceiling
/// along the top.
pub const Surface = enum { floor, wall, ceiling };

/// The animations for one surface, by kind; those the rambler lacks are
/// null.
pub const Animations = std.EnumArray(Animation.Kind, ?Animation);

pub const Animation = struct {
    frames: []const Sprite,
    frame_ms: u32,

    /// At least one of `idle` and `walk` is required on every surface the
    /// rambler walks on. The actor only runs, sleeps or jumps if the
    /// rambler has the animation for it.
    pub const Kind = enum { idle, walk, run, sleep, jump };
};

/// Returns the animation for `kind` on `surface`, falling back to that
/// surface's `walk` or `idle`. Validation guarantees that at least one of
/// those two exists on every surface one of the rambler's edges uses.
pub fn animation(r: *const Rambler, surface: Surface, kind: Animation.Kind) Animation {
    const set = r.animations.get(surface);
    if (set.get(kind)) |a| return a;
    return set.get(.walk) orelse set.get(.idle).?;
}

pub const limits = struct {
    pub const max_size = 64;
    pub const max_frames = 64;
    pub const min_frame_ms = 20;
    pub const max_frame_ms = 10_000;
    pub const min_speed = 1;
    pub const max_speed = 64;
    pub const max_jump_height = 64;
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

    try root.rejectUnknown(&.{ "id", "name", "description", "width", "height", "facing", "palette", "animations", "wall_animations", "ceiling_animations", "edges", "motion" });

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

    // Running defaults to twice the speed, and jumping to half the height.
    var speed: f64 = default_speed;
    var run_speed: f64 = 2 * default_speed;
    var jump_height: i64 = @max(1, @divFloor(height orelse 0, 2));
    if (try root.object("motion", false)) |motion| {
        try motion.rejectUnknown(&.{ "speed", "run_speed", "jump_height" });
        speed = try motion.number("speed", default_speed, limits.min_speed, limits.max_speed) orelse default_speed;
        const default_run_speed = @min(2 * speed, limits.max_speed);
        run_speed = try motion.number("run_speed", default_run_speed, limits.min_speed, limits.max_speed) orelse default_run_speed;
        jump_height = try motion.integer("jump_height", jump_height, 1, limits.max_jump_height) orelse jump_height;
        try warnIfUnused(root, motion, "run_speed", .run);
        try warnIfUnused(root, motion, "jump_height", .jump);
    }

    // Sprites can only be checked against a valid size, and their symbols
    // only against a valid palette.
    const geometry: ?Geometry = if (width != null and height != null) .{
        .width = @intCast(width.?),
        .height = @intCast(height.?),
        .palette = if (palette) |*p| p else null,
    } else null;

    var sprites: SpriteCache = .{ .source = source, .geometry = geometry, .diag = diag };
    var animations: std.EnumArray(Surface, Animations) = .initFill(.initFill(null));
    animations.set(.floor, try parseAnimations(root, "animations", .floor, &sprites));
    animations.set(.wall, try parseAnimations(root, "wall_animations", .wall, &sprites));
    animations.set(.ceiling, try parseAnimations(root, "ceiling_animations", .ceiling, &sprites));
    const edges = try parseEdges(root);

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
        .edges = edges,
        .speed = @floatCast(speed),
        .run_speed = @floatCast(run_speed),
        .jump_height = @intCast(jump_height),
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

/// Parses the set of animations under `key`, for `surface`. Only the
/// floor's is required.
fn parseAnimations(root: Fields, key: []const u8, surface: Surface, sprites: *SpriteCache) Allocator.Error!Animations {
    var animations: Animations = .initFill(null);
    const fields = try root.object(key, surface == .floor) orelse return animations;

    for (fields.members.keys()) |name| {
        const kind = std.meta.stringToEnum(Animation.Kind, name) orelse {
            try fields.fail(name, "unknown animation (expected one of: idle, walk, run, sleep, jump)", .{});
            continue;
        };
        const anim = try fields.object(name, true) orelse continue;
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
            if (try sprites.get(root.arena, frame_name, surface)) |s| frame.* = s else complete = false;
        }
        if (complete and frame_ms != null) {
            animations.set(kind, .{ .frames = frames, .frame_ms = @intCast(frame_ms.?) });
        }
    }
    if (fields.members.get("idle") == null and fields.members.get("walk") == null) {
        try root.fail(key, "must define at least \"idle\" or \"walk\"", .{});
    }
    return animations;
}

/// Parses `edges`, which defaults to every edge the rambler has the
/// animations for. Whether a set of animations is there is taken from the
/// JSON alone, so that a set with problems of its own does not also make
/// the edges that use it look wrong.
fn parseEdges(root: Fields) Allocator.Error!std.EnumSet(Edge) {
    const has_walls = root.members.contains("wall_animations");
    const has_ceiling = root.members.contains("ceiling_animations");
    var edges: std.EnumSet(Edge) = .initOne(.bottom);

    if (!root.members.contains("edges")) {
        if (has_walls) {
            edges.insert(.left);
            edges.insert(.right);
            if (has_ceiling) edges.insert(.top);
        } else if (has_ceiling) {
            try root.warn("ceiling_animations", "not used without \"wall_animations\" to reach the ceiling", .{});
        }
        return edges;
    }

    const items = try root.array("edges") orelse return edges;
    edges = .initEmpty();
    var all_known = true;
    for (items, 0..) |value, i| {
        const edge = switch (value) {
            .string => |s| std.meta.stringToEnum(Edge, s),
            else => null,
        } orelse {
            try root.failIndex("edges", i, "expected \"bottom\", \"left\", \"right\" or \"top\"", .{});
            all_known = false;
            continue;
        };
        if (edges.contains(edge)) {
            try root.failIndex("edges", i, "\"{t}\" is listed twice", .{edge});
            continue;
        }
        edges.insert(edge);
        switch (edge) {
            .bottom => {},
            .left, .right => if (!has_walls) try root.failIndex("edges", i, "\"{t}\" needs \"wall_animations\"", .{edge}),
            .top => if (!has_ceiling) try root.failIndex("edges", i, "\"top\" needs \"ceiling_animations\"", .{}),
        }
    }
    // An edge that is not recognized may be the one that seems missing.
    if (!all_known) return edges;

    const has_side = edges.contains(.left) or edges.contains(.right);
    if (!edges.contains(.bottom)) {
        try root.fail("edges", "must include \"bottom\", where ramblers come in", .{});
    }
    if (edges.contains(.top) and !has_side) {
        try root.fail("edges", "\"top\" is only reached by a wall: add \"left\" or \"right\"", .{});
    }
    if (has_walls and !has_side) {
        try root.warn("wall_animations", "not used without \"left\" or \"right\" in \"edges\"", .{});
    }
    if (has_ceiling and !edges.contains(.top)) {
        try root.warn("ceiling_animations", "not used without \"top\" in \"edges\"", .{});
    }
    return edges;
}

/// Warns about a motion field that has no effect because there is no
/// animation to go with it on any surface, which may be a typo in the
/// animation's name.
fn warnIfUnused(root: Fields, motion: Fields, key: []const u8, kind: Animation.Kind) Allocator.Error!void {
    if (!motion.members.contains(key)) return;
    for ([_][]const u8{ "animations", "wall_animations", "ceiling_animations" }) |set_key| {
        const set = root.members.get(set_key) orelse continue;
        if (set == .object and set.object.contains(@tagName(kind))) return;
    }
    try motion.warn(key, "not used without a \"{t}\" animation", .{kind});
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

/// Reads each sprite file once, however many animations use it, and parses
/// it once for each way it is used: upright on the floor and the ceiling,
/// sideways on a wall, where frames are as wide as the rambler is tall.
const SpriteCache = struct {
    source: Source,
    /// Null when the manifest's size is invalid; sprite files are then only
    /// checked for existence.
    geometry: ?Geometry,
    diag: *Diagnostics,
    /// Keyed by frame name.
    loaded: std.StringHashMapUnmanaged(Entry) = .empty,

    const Entry = struct {
        path: []const u8,
        /// Null for files that are missing or unreadable, which have been
        /// reported once already.
        text: ?[]const u8,
        /// Null until parsed; then null inside if the sprite is invalid.
        upright: ??Sprite = null,
        sideways: ??Sprite = null,
    };

    fn get(c: *SpriteCache, arena: Allocator, frame_name: []const u8, surface: Surface) Allocator.Error!?Sprite {
        const result = try c.loaded.getOrPut(arena, frame_name);
        const entry = result.value_ptr;
        if (!result.found_existing) entry.* = try c.read(arena, frame_name);

        const text = entry.text orelse return null;
        const g = c.geometry orelse return null;
        // Square frames fit a wall as they are, so they are parsed only once.
        const sideways = surface == .wall and g.width != g.height;
        const parsed = if (sideways) &entry.sideways else &entry.upright;
        if (parsed.* == null) {
            parsed.* = if (sideways)
                try sprite.parse(arena, text, g.height, g.width, "the manifest's height, the width of wall frames,", g.palette, c.diag, entry.path)
            else
                try sprite.parse(arena, text, g.width, g.height, "the manifest's width", g.palette, c.diag, entry.path);
        }
        return parsed.*.?;
    }

    fn read(c: *SpriteCache, arena: Allocator, frame_name: []const u8) Allocator.Error!Entry {
        const file_name = try std.fmt.allocPrint(arena, "{s}.sprite", .{frame_name});
        const file_path = try c.source.path(arena, file_name);
        const text = c.source.read(arena, file_name, limits.max_sprite_bytes, c.diag) catch |err| switch (err) {
            error.FileNotFound => blk: {
                try c.diag.err(file_path, "missing sprite file (referenced as frame \"{s}\")", .{frame_name});
                break :blk null;
            },
            error.Unreadable => null,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .path = file_path, .text = text };
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

    fn warn(f: Fields, key: []const u8, comptime fmt: []const u8, args: anytype) Allocator.Error!void {
        try f.diag.warn(f.file, "{s}: " ++ fmt, .{try f.memberPath(key)} ++ args);
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
    try testing.expectEqual(@as(f32, 2 * default_speed), r.run_speed);
    try testing.expectEqual(1, r.jump_height);
    // `idle` falls back to `walk`.
    try testing.expectEqual(3, r.animation(.floor, .idle).frames.len);
    try testing.expectEqual(default_frame_ms, r.animation(.floor, .walk).frame_ms);
    try testing.expectEqual(1, r.edges.count());
    try testing.expect(r.edges.contains(.bottom));
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
        "speeed: unknown field (expected one of: id, name, description, width, height, facing, palette, animations, wall_animations, ceiling_animations, edges, motion)",
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

test "load reads how fast a rambler runs and how high it jumps" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);

    const r = try loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "test", "name": "Test", "width": 2, "height": 2,
        \\  "palette": { "k": "#000000" },
        \\  "animations": { "walk": { "frames": ["a"] }, "run": { "frames": ["a"] }, "jump": { "frames": ["a"] } },
        \\  "motion": { "speed": 9, "run_speed": 20.5, "jump_height": 5 } }
        },
        .{ .name = "a.sprite", .data = "k.\n.k\n" },
    }, &diag);
    try testing.expectEqual(0, diag.items.items.len);
    try testing.expectEqual(20.5, r.run_speed);
    try testing.expectEqual(5, r.jump_height);

    // By default, twice the speed (but no more than the maximum) and half
    // the height.
    const defaults = try loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "test", "name": "Test", "width": 2, "height": 13,
        \\  "palette": { "k": "#000000" },
        \\  "animations": { "walk": { "frames": ["a"] }, "run": { "frames": ["a"] }, "jump": { "frames": ["a"] } },
        \\  "motion": { "speed": 40 } }
        },
        .{ .name = "a.sprite", .data = "k.\n" ** 13 },
    }, &diag);
    try testing.expectEqual(0, diag.items.items.len);
    try testing.expectEqual(64, defaults.run_speed);
    try testing.expectEqual(6, defaults.jump_height);

    // A rambler one pixel tall still jumps: a jump of 0 pixels would take
    // no time at all.
    const flat = try loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "test", "name": "Test", "width": 2, "height": 1,
        \\  "palette": { "k": "#000000" },
        \\  "animations": { "walk": { "frames": ["a"] }, "jump": { "frames": ["a"] } } }
        },
        .{ .name = "a.sprite", .data = "k.\n" },
    }, &diag);
    try testing.expectEqual(0, diag.items.items.len);
    try testing.expectEqual(1, flat.jump_height);
}

test "load warns about motion that no animation uses" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);

    _ = try loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "test", "name": "Test", "width": 2, "height": 2,
        \\  "palette": { "k": "#000000" },
        \\  "animations": { "walk": { "frames": ["a"] } },
        \\  "motion": { "run_speed": 20, "jump_height": 4 } }
        },
        .{ .name = "a.sprite", .data = "k.\n.k\n" },
    }, &diag);
    const expected = [_][]const u8{
        "motion.run_speed: not used without a \"run\" animation",
        "motion.jump_height: not used without a \"jump\" animation",
    };
    try testing.expectEqual(expected.len, diag.items.items.len);
    for (expected, diag.items.items) |message, item| {
        try testing.expectEqual(.warning, item.severity);
        try testing.expectEqualStrings(message, item.message);
    }

    // A "run" animation with problems of its own is still there: its errors
    // say what is wrong, without a warning that suggests it is missing.
    diag = .init(arena);
    try testing.expectError(error.InvalidRambler, loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "test", "name": "Test", "width": 2, "height": 2,
        \\  "palette": { "k": "#000000" },
        \\  "animations": { "walk": { "frames": ["a"] }, "run": { "frames": ["missing"] } },
        \\  "motion": { "run_speed": 20 } }
        },
        .{ .name = "a.sprite", .data = "k.\n.k\n" },
    }, &diag));
    try testing.expectEqual(1, diag.errorCount());
    try testing.expectEqual(0, diag.count(.warning));
}

test "load reports invalid motion" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);

    try testing.expectError(error.InvalidRambler, loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "test", "name": "Test", "width": 2, "height": 2,
        \\  "palette": { "k": "#000000" },
        \\  "animations": { "walk": { "frames": ["a"] }, "run": { "frames": ["a"] }, "jump": { "frames": ["a"] } },
        \\  "motion": { "run_speed": 0, "jump_height": 2.5, "jump": 3 } }
        },
        .{ .name = "a.sprite", .data = "k.\n.k\n" },
    }, &diag));
    const expected = [_][]const u8{
        "motion.jump: unknown field (expected one of: speed, run_speed, jump_height)",
        "motion.run_speed: expected a number from 1 to 64",
        "motion.jump_height: expected an integer from 1 to 64",
    };
    try testing.expectEqual(expected.len, diag.items.items.len);
    for (expected, diag.items.items) |message, item| try testing.expectEqualStrings(message, item.message);
}

test "load wall and ceiling animations" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);

    // Wall frames are turned on their side: as wide as the rambler is tall.
    const r = try loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "test", "name": "Test", "width": 3, "height": 2,
        \\  "palette": { "k": "#000000" },
        \\  "animations": { "walk": { "frames": ["floor"] } },
        \\  "wall_animations": { "walk": { "frames": ["wall", "wall"] } },
        \\  "ceiling_animations": { "idle": { "frames": ["ceiling"] } } }
        },
        .{ .name = "floor.sprite", .data = "kk.\n.kk\n" },
        .{ .name = "wall.sprite", .data = "k.\n.k\nk.\n" },
        .{ .name = "ceiling.sprite", .data = "kkk\n...\n" },
    }, &diag);
    try testing.expectEqual(0, diag.items.items.len);
    try testing.expectEqual(4, r.edges.count());
    // `idle` falls back to `walk` on a wall too, and `walk` to `idle` on the
    // ceiling.
    const wall = r.animation(.wall, .idle);
    try testing.expectEqual(2, wall.frames.len);
    try testing.expectEqual(2, wall.frames[0].width);
    try testing.expectEqual(3, wall.frames[0].height);
    const ceiling = r.animation(.ceiling, .walk);
    try testing.expectEqual(3, ceiling.frames[0].width);
    try testing.expectEqual(2, ceiling.frames[0].height);
    try testing.expectEqual('k', ceiling.frames[0].at(2, 0));

    // A square frame fits every surface as it is, and is parsed only once.
    const square = try loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "test", "name": "Test", "width": 2, "height": 2,
        \\  "palette": { "k": "#000000" },
        \\  "animations": { "walk": { "frames": ["a"] } },
        \\  "wall_animations": { "walk": { "frames": ["a"] } } }
        },
        .{ .name = "a.sprite", .data = "k.\n.k\n" },
    }, &diag);
    try testing.expectEqual(0, diag.items.items.len);
    try testing.expectEqual(
        square.animation(.floor, .walk).frames[0].pixels.ptr,
        square.animation(.wall, .walk).frames[0].pixels.ptr,
    );
    try testing.expectEqual(3, square.edges.count());
    try testing.expect(!square.edges.contains(.top));
}

test "wall frames are as wide as the manifest's height" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);

    try testing.expectError(error.InvalidRambler, loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "test", "name": "Test", "width": 3, "height": 2,
        \\  "palette": { "k": "#000000" },
        \\  "animations": { "walk": { "frames": ["floor"] }, "idle": { "frames": ["missing"] } },
        \\  "wall_animations": { "walk": { "frames": ["floor", "missing"] } } }
        },
        .{ .name = "floor.sprite", .data = "kk.\n.kk\n" },
    }, &diag));
    // The missing file is reported once, however many sets refer to it.
    const expected = [_][]const u8{
        "missing sprite file (referenced as frame \"missing\")",
        "every row is 3 pixels wide, but the manifest's height, the width of wall frames, is 2",
        "expected 3 rows, found 2",
    };
    try testing.expectEqual(expected.len, diag.items.items.len);
    for (expected, diag.items.items) |message, item| try testing.expectEqualStrings(message, item.message);
    try testing.expect(std.mem.endsWith(u8, diag.items.items[1].file, "floor.sprite"));
}

/// Loads a 2×2 rambler that walks on the floor with frame "a", plus the
/// manifest members in `members`, each preceded by a comma.
fn loadWithMembers(arena: Allocator, comptime members: []const u8, diag: *Diagnostics) LoadError!Rambler {
    return loadTest(arena, &.{
        .{ .name = "manifest.json", .data =
        \\{ "id": "test", "name": "Test", "width": 2, "height": 2,
        \\  "palette": { "k": "#000000" },
        \\  "animations": { "walk": { "frames": ["a"] } }
        ++ members ++ " }" },
        .{ .name = "a.sprite", .data = "k.\n.k\n" },
    }, diag);
}

const test_walls = ", \"wall_animations\": { \"walk\": { \"frames\": [\"a\"] } }";
const test_ceiling = ", \"ceiling_animations\": { \"idle\": { \"frames\": [\"a\"] } }";

test "load checks edges" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);

    const cases = .{
        .{ test_walls ++ ", \"edges\": \"bottom\"", .{
            "edges: expected an array",
        } },
        // An edge that is not recognized may be the one that seems missing.
        .{ test_walls ++ test_ceiling ++ ", \"edges\": [3, \"side\", \"left\"]", .{
            "edges[0]: expected \"bottom\", \"left\", \"right\" or \"top\"",
            "edges[1]: expected \"bottom\", \"left\", \"right\" or \"top\"",
        } },
        .{ ", \"edges\": [\"bottom\", \"bottom\"]", .{
            "edges[1]: \"bottom\" is listed twice",
        } },
        .{ ", \"edges\": [\"bottom\", \"left\", \"right\"]", .{
            "edges[1]: \"left\" needs \"wall_animations\"",
            "edges[2]: \"right\" needs \"wall_animations\"",
        } },
        .{ test_walls ++ ", \"edges\": [\"bottom\", \"left\", \"top\"]", .{
            "edges[2]: \"top\" needs \"ceiling_animations\"",
        } },
        .{ test_walls ++ ", \"edges\": [\"left\", \"right\"]", .{
            "edges: must include \"bottom\", where ramblers come in",
        } },
        .{ ", \"edges\": []", .{
            "edges: must include \"bottom\", where ramblers come in",
        } },
        .{ test_walls ++ test_ceiling ++ ", \"edges\": [\"bottom\", \"top\"]", .{
            "edges: \"top\" is only reached by a wall: add \"left\" or \"right\"",
            "wall_animations: not used without \"left\" or \"right\" in \"edges\"",
        } },
    };
    inline for (cases) |case| {
        diag = .init(arena);
        try testing.expectError(error.InvalidRambler, loadWithMembers(arena, case[0], &diag));
        try testing.expectEqual(case[1].len, diag.items.items.len);
        inline for (case[1], 0..) |message, i| try testing.expectEqualStrings(message, diag.items.items[i].message);
    }

    diag = .init(arena);
    const listed = try loadWithMembers(arena, test_walls ++ ", \"edges\": [\"bottom\", \"right\"]", &diag);
    try testing.expectEqual(0, diag.items.items.len);
    try testing.expectEqual(2, listed.edges.count());
    try testing.expect(listed.edges.contains(.bottom) and listed.edges.contains(.right));

    // By default, every edge there are animations for.
    const walls = try loadWithMembers(arena, test_walls, &diag);
    try testing.expectEqual(0, diag.items.items.len);
    try testing.expectEqual(3, walls.edges.count());
    try testing.expect(!walls.edges.contains(.top));

    const ceiling = try loadWithMembers(arena, test_ceiling, &diag);
    try testing.expectEqual(1, diag.items.items.len);
    try testing.expectEqual(.warning, diag.items.items[0].severity);
    try testing.expectEqualStrings(
        "ceiling_animations: not used without \"wall_animations\" to reach the ceiling",
        diag.items.items[0].message,
    );
    try testing.expectEqual(1, ceiling.edges.count());
    try testing.expect(ceiling.edges.contains(.bottom));
}

test "load warns about animations that no edge uses" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var diag: Diagnostics = .init(arena);

    _ = try loadWithMembers(arena, test_walls ++ test_ceiling ++ ", \"edges\": [\"bottom\"]", &diag);
    const expected = [_][]const u8{
        "wall_animations: not used without \"left\" or \"right\" in \"edges\"",
        "ceiling_animations: not used without \"top\" in \"edges\"",
    };
    try testing.expectEqual(expected.len, diag.items.items.len);
    for (expected, diag.items.items) |message, item| {
        try testing.expectEqual(.warning, item.severity);
        try testing.expectEqualStrings(message, item.message);
    }

    diag = .init(arena);
    _ = try loadWithMembers(arena, test_walls ++ test_ceiling ++ ", \"edges\": [\"bottom\", \"left\"]", &diag);
    try testing.expectEqual(1, diag.items.items.len);
    try testing.expectEqualStrings(expected[1], diag.items.items[0].message);

    // A run up the wall is enough for a run speed.
    diag = .init(arena);
    const r = try loadWithMembers(arena,
        \\, "wall_animations": { "walk": { "frames": ["a"] }, "run": { "frames": ["a"] } },
        \\  "motion": { "run_speed": 20 }
    , &diag);
    try testing.expectEqual(0, diag.items.items.len);
    try testing.expectEqual(20, r.run_speed);
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
