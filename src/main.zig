//! rambit: tiny pixel-art ramblers that roam your terminal.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Writer = Io.Writer;
const builtin_ramblers = @import("builtin_ramblers");
const Actor = @import("Actor.zig");
const Canvas = @import("Canvas.zig");
const Diagnostics = @import("Diagnostics.zig");
const Rambler = @import("Rambler.zig");
const Screen = @import("Screen.zig");
const Source = @import("Source.zig");
const Sprite = @import("sprite.zig").Sprite;
const Terminal = @import("Terminal.zig");
const color = @import("color.zig");
const play = @import("play.zig");

const version = "0.1.0";

const usage =
    \\Usage: rambit <rambler> [options]     let a rambler roam the bottom of your terminal
    \\       rambit <path> [options]        the same, loading the rambler from a directory
    \\       rambit list                    list the built-in ramblers
    \\       rambit preview <rambler|path>  print every animation frame
    \\       rambit validate [path...]      check rambler directories (default: built-ins)
    \\
    \\Options:
    \\  --once          cross the screen once and exit, like sl
    \\  --seed <n>      seed the movement, for a reproducible run
    \\  --color <mode>  auto (default), truecolor or 256
    \\  -h, --help      show this help
    \\  -V, --version   show the version
    \\
    \\A <path> is anything containing a '/', e.g. ./ramblers/cat.
    \\Press q, Esc or Ctrl-C to send the rambler home.
    \\
;

/// Makes sure a crash does not leave the terminal in raw mode on the
/// alternate screen.
pub const panic = std.debug.FullPanic(panicRestoringTerminal);

fn panicRestoringTerminal(msg: []const u8, first_trace_addr: ?usize) noreturn {
    Terminal.emergencyRestore();
    std.debug.defaultPanic(msg, first_trace_addr);
}

const Command = union(enum) {
    help,
    version,
    list,
    preview: []const u8,
    validate: []const [:0]const u8,
    play: []const u8,
};

const Cli = struct {
    command: Command,
    once: bool = false,
    seed: ?u64 = null,
    /// Null means detect.
    color_mode: ?color.Mode = null,
};

const UsageError = error{Usage};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    const args = try init.minimal.args.toSlice(arena);
    const cli = parseArgs(args[1..], stderr) catch |err| switch (err) {
        error.Usage => {
            try stderr.writeAll("\n" ++ usage);
            return 2;
        },
        else => |e| return e,
    };
    const color_mode = cli.color_mode orelse color.Mode.detect(init.environ_map.get("COLORTERM"));

    switch (cli.command) {
        .help => try stdout.writeAll(usage),
        .version => try stdout.writeAll("rambit " ++ version ++ "\n"),
        .list => try list(arena, stdout),
        .validate => |paths| return if (try validate(arena, io, paths, stdout)) 0 else 1,
        .preview => |spec| {
            const rambler = try resolve(arena, io, spec, stderr) orelse return 1;
            try preview(arena, io, &rambler, color_mode, stdout);
        },
        .play => |spec| {
            const rambler = try resolve(arena, io, spec, stderr) orelse return 1;
            if (!try Io.File.stdout().isTty(io)) {
                try stderr.print("rambit: stdout is not a terminal; try `rambit preview {s}`\n", .{spec});
                return 1;
            }
            const seed = cli.seed orelse seed: {
                var bytes: [8]u8 = undefined;
                io.random(&bytes);
                break :seed std.mem.readInt(u64, &bytes, .little);
            };
            try play.play(init.gpa, io, &rambler, .{
                .mode = if (cli.once) .once else .roam,
                .seed = seed,
                .color_mode = color_mode,
            });
        },
    }
    return 0;
}

fn parseArgs(args: []const [:0]const u8, stderr: *Writer) (UsageError || Writer.Error)!Cli {
    var positionals: [2][]const u8 = undefined;
    var positional_count: usize = 0;
    var rest: []const [:0]const u8 = &.{};
    var cli: Cli = .{ .command = .help };

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg: []const u8 = args[i];
        const is_option = arg.len > 1 and arg[0] == '-';
        if (positional_count == 1 and eql(positionals[0], "validate") and !is_option) {
            // Everything after `validate` is a path.
            rest = args[i..];
            break;
        }
        if (!is_option) {
            if (positional_count == positionals.len) {
                try stderr.print("rambit: unexpected argument '{s}'\n", .{arg});
                return error.Usage;
            }
            positionals[positional_count] = arg;
            positional_count += 1;
        } else if (eql(arg, "-h") or eql(arg, "--help")) {
            return .{ .command = .help };
        } else if (eql(arg, "-V") or eql(arg, "--version")) {
            return .{ .command = .version };
        } else if (eql(arg, "--once")) {
            cli.once = true;
        } else if (optionValue(args, &i, "--seed")) |value| {
            cli.seed = std.fmt.parseInt(u64, value, 0) catch {
                try stderr.print("rambit: --seed expects a non-negative integer, got '{s}'\n", .{value});
                return error.Usage;
            };
        } else if (optionValue(args, &i, "--color")) |value| {
            cli.color_mode = if (eql(value, "auto")) null else std.meta.stringToEnum(color.Mode, value) orelse {
                try stderr.print("rambit: --color expects auto, truecolor or 256, got '{s}'\n", .{value});
                return error.Usage;
            };
        } else {
            try stderr.print("rambit: unknown option '{s}'\n", .{arg});
            return error.Usage;
        }
    }

    if (positional_count == 0) {
        try stderr.writeAll("rambit: which rambler? Try `rambit list`.\n");
        return error.Usage;
    }
    const first = positionals[0];
    const second: ?[]const u8 = if (positional_count > 1) positionals[1] else null;
    if (eql(first, "help")) {
        cli.command = .help;
    } else if (eql(first, "version")) {
        cli.command = .version;
    } else if (eql(first, "list")) {
        cli.command = .list;
    } else if (eql(first, "validate")) {
        cli.command = .{ .validate = rest };
    } else if (eql(first, "preview")) {
        cli.command = .{ .preview = second orelse {
            try stderr.writeAll("rambit: preview which rambler?\n");
            return error.Usage;
        } };
        return cli;
    } else {
        cli.command = .{ .play = first };
    }
    if (second) |arg| {
        try stderr.print("rambit: unexpected argument '{s}'\n", .{arg});
        return error.Usage;
    }
    return cli;
}

/// Matches `--name value` and `--name=value`, advancing `i` past the value.
fn optionValue(args: []const [:0]const u8, i: *usize, comptime name: []const u8) ?[]const u8 {
    const arg: []const u8 = args[i.*];
    if (std.mem.cutPrefix(u8, arg, name ++ "=")) |value| return value;
    if (!eql(arg, name)) return null;
    if (i.* + 1 >= args.len) return "";
    i.* += 1;
    return args[i.*];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Loads the rambler named by `spec`: a built-in one, or a directory when
/// `spec` contains a slash. Problems are reported to `stderr`.
fn resolve(arena: Allocator, io: Io, spec: []const u8, stderr: *Writer) !?Rambler {
    var diag: Diagnostics = .init(arena);
    const result = if (std.mem.indexOfScalar(u8, spec, '/') != null) result: {
        var dir = Io.Dir.cwd().openDir(io, spec, .{ .iterate = true }) catch |err| {
            try stderr.print("rambit: unable to open '{s}': {t}\n", .{ spec, err });
            return null;
        };
        defer dir.close(io);
        break :result Rambler.load(arena, try Source.directory(arena, io, dir, spec), &diag);
    } else for (builtin_ramblers.entries) |entry| {
        if (eql(entry.id, spec)) break Rambler.load(arena, Source.embedded(entry), &diag);
    } else {
        try stderr.print("rambit: there is no rambler called '{s}'; `rambit list` shows them all\n", .{spec});
        return null;
    };
    return result catch |err| switch (err) {
        error.InvalidRambler => {
            try diag.render(stderr);
            try stderr.print("rambit: '{s}' is not a valid rambler\n", .{spec});
            return null;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn list(arena: Allocator, stdout: *Writer) !void {
    var width: usize = 0;
    for (builtin_ramblers.entries) |entry| width = @max(width, entry.id.len);
    for (builtin_ramblers.entries) |entry| {
        var diag: Diagnostics = .init(arena);
        try stdout.writeAll(entry.id);
        try stdout.splatByteAll(' ', width + 2 - entry.id.len);
        if (Rambler.load(arena, Source.embedded(entry), &diag)) |r| {
            try stdout.print("{s}\n", .{if (r.description.len != 0) r.description else r.name});
        } else |err| switch (err) {
            error.InvalidRambler => try stdout.writeAll("(invalid; see `rambit validate`)\n"),
            error.OutOfMemory => return error.OutOfMemory,
        }
    }
}

/// Validates the built-in ramblers, or the given directories. A directory
/// without a manifest is treated as a collection of ramblers, so that
/// `rambit validate ramblers` checks all of them. Returns whether all of
/// them were valid.
fn validate(arena: Allocator, io: Io, paths: []const [:0]const u8, stdout: *Writer) !bool {
    var v: Validation = .{ .arena = arena, .stdout = stdout };
    if (paths.len == 0) {
        for (builtin_ramblers.entries) |entry| {
            var source = Source.embedded(entry);
            source.label = try std.fmt.allocPrint(arena, "builtin:{s}", .{entry.id});
            try v.check(source);
        }
    }
    for (paths) |path| {
        var dir = Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| {
            try stdout.print("error: {s}: unable to open: {t}\n", .{ path, err });
            v.checked += 1;
            v.invalid += 1;
            continue;
        };
        defer dir.close(io);
        if (dir.access(io, "manifest.json", .{})) |_| {
            try v.check(try Source.directory(arena, io, dir, path));
            continue;
        } else |_| {}

        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(io)) |entry| {
            if (entry.kind == .directory and entry.name[0] != '.') try names.append(arena, try arena.dupe(u8, entry.name));
        }
        if (names.items.len == 0) {
            try stdout.print("error: {s}: neither a rambler (no manifest.json) nor a directory of ramblers\n", .{path});
            v.checked += 1;
            v.invalid += 1;
            continue;
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);
        for (names.items) |name| {
            var sub = try dir.openDir(io, name, .{ .iterate = true });
            defer sub.close(io);
            const sub_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, path, "/"), name });
            try v.check(try Source.directory(arena, io, sub, sub_path));
        }
    }
    try stdout.print("\n{d} rambler{s} checked, {d} invalid\n", .{ v.checked, if (v.checked == 1) "" else "s", v.invalid });
    return v.invalid == 0;
}

const Validation = struct {
    arena: Allocator,
    stdout: *Writer,
    checked: usize = 0,
    invalid: usize = 0,
    /// Rambler ids seen so far, mapped to where they were seen.
    ids: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn check(v: *Validation, source: Source) !void {
        v.checked += 1;
        var diag: Diagnostics = .init(v.arena);
        const valid = if (Rambler.load(v.arena, source, &diag)) |r| valid: {
            const seen = try v.ids.getOrPut(v.arena, r.id);
            if (seen.found_existing) {
                try diag.err(try source.path(v.arena, "manifest.json"), "duplicate rambler id \"{s}\", also used by {s}", .{ r.id, seen.value_ptr.* });
                break :valid false;
            }
            seen.value_ptr.* = source.label;
            break :valid true;
        } else |err| switch (err) {
            error.InvalidRambler => false,
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (!valid) v.invalid += 1;

        try v.stdout.print("{s} {s}", .{ if (valid) "ok  " else "FAIL", source.label });
        const warnings = diag.count(.warning);
        if (warnings != 0) try v.stdout.print(" ({d} warning{s})", .{ warnings, if (warnings == 1) "" else "s" });
        try v.stdout.writeByte('\n');
        try diag.render(v.stdout);
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Prints every animation as a row of frames, for reviewing sprites without
/// running the animation (in a pull request, say).
fn preview(arena: Allocator, io: Io, r: *const Rambler, mode: color.Mode, stdout: *Writer) !void {
    try stdout.print("{s} ({s}){s}{s}\n", .{ r.name, r.id, if (r.description.len != 0) ": " else "", r.description });
    try stdout.print("{d}x{d} pixels, facing {t}, {d} px/s", .{ r.width, r.height, r.facing, r.speed });
    const floor = r.animations.get(.floor);
    if (floor.get(.run) != null) try stdout.print(", running {d} px/s", .{r.run_speed});
    if (floor.get(.jump) != null) try stdout.print(", jumping {d} px", .{r.jump_height});
    try stdout.writeByte('\n');

    const gap = 2;
    const term_cols: usize = if (try Io.File.stdout().isTty(io)) Terminal.size(io).cols else 80;
    const per_line = @max(1, (term_cols + gap) / (r.width + gap));
    // Cells hold two pixel rows, so round odd heights up.
    const height = r.height + r.height % 2;

    for (std.enums.values(Rambler.Animation.Kind)) |kind| {
        const anim = floor.get(kind) orelse continue;
        try stdout.print("\n{t}: {d} frame{s}, {d} ms each\n", .{ kind, anim.frames.len, if (anim.frames.len == 1) "" else "s", anim.frame_ms });
        var frames = std.mem.window(Sprite, anim.frames, per_line, per_line);
        while (frames.next()) |line| {
            const width: u16 = @intCast(line.len * r.width + (line.len - 1) * gap);
            var canvas: Canvas = try .init(arena, width, height);
            for (line, 0..) |frame, i| {
                canvas.drawSprite(frame, &r.palette, @intCast(i * (r.width + gap)), 0, .{});
            }
            const cells = try arena.alloc(Screen.Cell, @as(usize, width) * (height / 2));
            Screen.cellsFromCanvas(cells, &canvas);
            try Screen.writeLines(stdout, cells, width, mode);
        }
    }
}

test {
    _ = @import("Actor.zig");
    _ = @import("Canvas.zig");
    _ = @import("Diagnostics.zig");
    _ = @import("Rambler.zig");
    _ = @import("Screen.zig");
    _ = @import("Source.zig");
    _ = @import("Terminal.zig");
    _ = @import("Track.zig");
    _ = @import("color.zig");
    _ = @import("sprite.zig");
}

test parseArgs {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);

    const play_cli = try parseArgs(&.{ "cat", "--once", "--seed=7", "--color", "256" }, &w);
    try std.testing.expectEqualStrings("cat", play_cli.command.play);
    try std.testing.expect(play_cli.once);
    try std.testing.expectEqual(7, play_cli.seed.?);
    try std.testing.expectEqual(.@"256", play_cli.color_mode.?);

    const validate_cli = try parseArgs(&.{ "validate", "a", "b" }, &w);
    try std.testing.expectEqual(2, validate_cli.command.validate.len);
    try std.testing.expectEqual(1, (try parseArgs(&.{ "validate", "" }, &w)).command.validate.len);
    try std.testing.expectEqual(0, (try parseArgs(&.{"validate"}, &w)).command.validate.len);

    try std.testing.expectEqualStrings("./x", (try parseArgs(&.{ "preview", "./x" }, &w)).command.preview);
    try std.testing.expectEqual(.list, (try parseArgs(&.{"list"}, &w)).command);
    try std.testing.expectEqual(.help, (try parseArgs(&.{ "cat", "-h" }, &w)).command);

    try std.testing.expectError(error.Usage, parseArgs(&.{}, &w));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "cat", "dog" }, &w));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "cat", "--speed" }, &w));
    try std.testing.expectError(error.Usage, parseArgs(&.{ "cat", "--seed", "x" }, &w));
    try std.testing.expectError(error.Usage, parseArgs(&.{"preview"}, &w));
}
