//! Movement, kept separate from animation: the actor decides where the
//! rambler goes and which kind of animation fits, and the rambler supplies
//! the frames. All randomness comes from a seeded generator and time only
//! advances in fixed steps, so the same seed always produces the same run.
//!
//! The rambler moves along a track (see Track) made of the edges it walks:
//! along the bottom, and up the walls and across the ceiling if it has the
//! frames for them. It always comes in from off screen along the bottom.
//! Every decision and every frame uses the animations for the surface it
//! is on, so it only rests, sleeps, runs or jumps where it can.
//!
//! Running, sleeping and jumping are up to the rambler: the actor only does
//! them with the animation for it, and draws no random numbers for them
//! otherwise, so that ramblers without them move as they always have.

const Actor = @This();

const std = @import("std");
const Canvas = @import("Canvas.zig");
const Rambler = @import("Rambler.zig");
const Track = @import("Track.zig");
const Sprite = @import("sprite.zig").Sprite;

rambler: *const Rambler,
mode: Mode,
prng: std.Random.DefaultPrng,
/// The size of the canvas, as of the last `init` or `resize`.
field: Field,
/// Where the rambler is along the track, in pixels (see Track): on the
/// bottom edge, the left x of the sprite. Fractional, so that slow
/// ramblers still move smoothly.
position: f32,
direction: Track.Direction,
state: State,
/// Time spent in the current state; selects the animation frame.
elapsed_us: u64 = 0,
/// Set in `once` mode when the rambler has left the screen.
done: bool = false,
/// Coming in from off screen along the bottom edge, whatever edges the
/// rambler walks; cleared on first arrival.
entering: bool = true,

pub const Field = Track.Field;

pub const Mode = enum {
    /// Wander back and forth, pausing now and then, until told to stop.
    roam,
    /// Cross the screen once and finish, like `sl`.
    once,
};

const Walking = struct {
    target: f32,
    /// At the run speed, with the `run` animation.
    running: bool = false,
    /// Time since takeoff while jumping; null on the ground.
    airborne_us: ?u64 = null,
};

const State = union(enum) {
    walking: Walking,
    resting: struct { remaining_us: u64 },
    sleeping: struct { remaining_us: u64 },
};

pub const Frame = struct {
    sprite: Sprite,
    /// The edge it is against.
    edge: Rambler.Edge,
    /// Top-left corner on the canvas.
    x: i32,
    y: i32,
    /// How far off its edge, toward the middle, in pixels.
    lift: u16,
    /// How to flip the sprite to face the direction of travel.
    flip: Canvas.Flip,
};

const rest_chance = 0.75;
const min_rest_us = 1500 * std.time.us_per_ms;
const max_rest_us = 5000 * std.time.us_per_ms;
/// How often a rambler that can run sets off at a run.
const run_chance = 0.25;
/// How often a rest ends in a nap, for ramblers that can sleep.
const sleep_chance = 0.25;
const min_sleep_us = 6000 * std.time.us_per_ms;
const max_sleep_us = 12000 * std.time.us_per_ms;
/// A rambler that can jump does so about this often while on the move.
const mean_jump_interval_us = 8000 * std.time.us_per_ms;
/// In pixels per second squared. Higher jumps take longer: one of 6 pixels
/// lasts about 0.63 s.
const gravity = 120;

pub fn init(rambler: *const Rambler, mode: Mode, seed: u64, field: Field) Actor {
    var a: Actor = .{
        .rambler = rambler,
        .mode = mode,
        .prng = .init(seed),
        .field = field,
        .position = 0,
        .direction = .forward,
        .state = .{ .resting = .{ .remaining_us = 0 } },
    };
    // Enter from just outside one of the edges.
    const from_left = a.prng.random().boolean();
    const width: f32 = @floatFromInt(rambler.width);
    const right: f32 = @floatFromInt(field.width);
    a.position = if (from_left) -width else right;
    switch (mode) {
        .roam => a.setOff(),
        .once => a.walkTo(if (from_left) right else -width, false),
    }
    return a;
}

pub fn update(a: *Actor, dt_us: u64) void {
    a.elapsed_us += dt_us;
    switch (a.state) {
        .walking => |*walking| {
            if (walking.airborne_us) |*airborne_us| {
                airborne_us.* += dt_us;
                if (airborne_us.* >= a.airtimeUs()) walking.airborne_us = null;
            } else if (a.takesOff(walking.target, walking.running, dt_us)) {
                walking.airborne_us = 0;
            }
            const speed = if (walking.running) a.rambler.run_speed else a.rambler.speed;
            const step = speed * @as(f32, @floatFromInt(dt_us)) / std.time.us_per_s;
            const distance = walking.target - a.position;
            const from = a.edge();
            if (@abs(distance) > step) {
                a.position += std.math.sign(distance) * step;
                if (a.edge() != from) a.turnCorner(walking);
                return;
            }
            a.position = walking.target;
            if (a.edge() != from) a.turnCorner(walking);
            // Land first if the target was reached in mid-jump.
            if (walking.airborne_us == null) a.arrive();
        },
        .resting => |resting| {
            if (resting.remaining_us > dt_us) {
                a.state.resting.remaining_us -= dt_us;
            } else if (a.can(.sleep) and a.prng.random().float(f32) < sleep_chance) {
                a.fallAsleep();
            } else {
                a.setOff();
            }
        },
        .sleeping => |sleeping| {
            if (sleeping.remaining_us > dt_us) {
                a.state.sleeping.remaining_us -= dt_us;
            } else {
                a.setOff();
            }
        },
    }
}

/// Keeps the rambler's plans in line with a resized terminal.
pub fn resize(a: *Actor, field: Field) void {
    const old = a.track();
    a.field = field;
    const t = a.track();
    switch (a.mode) {
        // Still head for the far edge, wherever that is now.
        .once => if (a.direction == .forward) {
            a.state.walking.target = @floatFromInt(field.width);
        },
        .roam => {
            // Stay at the same spot on the same edge, and keep heading for
            // the same spot, the same way round a loop.
            a.position = t.carry(old, a.position);
            switch (a.state) {
                .walking => |*walking| {
                    const target = t.carry(old, walking.target);
                    const length = t.end() - t.start();
                    walking.target = if (!t.loops()) target else switch (a.direction) {
                        .forward => a.position + @mod(target - a.position, length),
                        .backward => a.position - @mod(a.position - target, length),
                    };
                },
                .resting, .sleeping => {},
            }
            // Come back if the screen shrank under the rambler or its
            // target, past an open end of the track.
            const out_of_bounds = !t.loops() and switch (a.state) {
                .walking => |walking| walking.target < t.start() or walking.target > t.end(),
                .resting, .sleeping => a.position < t.start() or a.position > t.end(),
            };
            if (out_of_bounds) a.setOff();
        },
    }
}

pub fn frame(a: *const Actor) Frame {
    const kind: Rambler.Animation.Kind = switch (a.state) {
        .walking => |walking| if (walking.airborne_us != null) .jump else if (walking.running) .run else .walk,
        .resting => .idle,
        .sleeping => .sleep,
    };
    const spot = a.track().locate(a.position);
    const anim = a.rambler.animation(spot.edge.surface(), kind);
    const frame_us = @as(u64, anim.frame_ms) * std.time.us_per_ms;
    const index = switch (kind) {
        // A jump starts from its first frame at every takeoff, and holds its
        // last one until landing.
        .jump => @min(a.state.walking.airborne_us.? / frame_us, anim.frames.len - 1),
        else => (a.elapsed_us / frame_us) % anim.frames.len,
    };
    const sprite = anim.frames[index];
    const lifted = a.lift();
    const at = Track.place(a.field, spot.edge, @intFromFloat(@floor(spot.along)), lifted, sprite);
    return .{
        .sprite = sprite,
        .edge = spot.edge,
        .x = at.x,
        .y = at.y,
        .lift = lifted,
        .flip = a.flip(spot.edge),
    };
}

/// How to flip a frame against edge `on` to face the direction of travel.
/// Floor frames are drawn facing `facing`, ceiling frames upside down and
/// facing `facing`, and wall frames on the right wall heading up.
fn flip(a: *const Actor, on: Rambler.Edge) Canvas.Flip {
    const forward = a.direction == .forward;
    return switch (on) {
        .bottom => .{ .x = forward != (a.rambler.facing == .right) },
        // Forward is leftward on the ceiling.
        .top => .{ .x = forward != (a.rambler.facing == .left) },
        // Forward is up the right wall, and down the left one.
        .right => .{ .y = !forward },
        .left => .{ .x = true, .y = forward },
    };
}

/// The edges the rambler walks along as a track: just the bottom while
/// coming in and in `once` mode.
fn track(a: *const Actor) Track {
    const edges: std.EnumSet(Rambler.Edge) = if (a.mode == .once or a.entering) .initOne(.bottom) else a.rambler.edges;
    return .init(edges, a.field, a.rambler.width);
}

/// The edge the rambler is on.
fn edge(a: *const Actor) Rambler.Edge {
    return a.track().locate(a.position).edge;
}

/// Whether the rambler has the animation for `kind` on the surface it is
/// on, and so may do it there.
fn can(a: *const Actor, kind: Rambler.Animation.Kind) bool {
    return a.rambler.animations.get(a.edge().surface()).get(kind) != null;
}

/// On coming round a corner: lands any jump, and drops a run the new
/// surface has no frames for. Draws no random numbers.
fn turnCorner(a: *Actor, walking: *Walking) void {
    // A jump never goes round a corner (see `takesOff`); only a resize or
    // the last tick of a jump can bring one there.
    walking.airborne_us = null;
    if (walking.running and !a.can(.run)) {
        walking.running = false;
        a.elapsed_us = 0;
    }
}

fn arrive(a: *Actor) void {
    if (a.mode == .once) {
        a.done = true;
        return;
    }
    a.entering = false;
    // Keep positions on a loop within bounds; elsewhere this changes nothing.
    a.position = a.track().wrap(a.position);
    const random = a.prng.random();
    if (a.can(.idle)) {
        if (random.float(f32) < rest_chance) return a.rest(random.intRangeAtMost(u64, min_rest_us, max_rest_us));
    } else if (a.can(.sleep)) {
        // Ramblers without an idle animation, like a train, just keep going,
        // unless they can sleep: then they stop for a nap about as often as
        // others doze off during a rest.
        if (random.float(f32) < rest_chance * sleep_chance) return a.fallAsleep();
    }
    a.setOff();
}

fn rest(a: *Actor, duration_us: u64) void {
    a.state = .{ .resting = .{ .remaining_us = duration_us } };
    a.elapsed_us = 0;
}

fn fallAsleep(a: *Actor) void {
    a.state = .{ .sleeping = .{ .remaining_us = a.prng.random().intRangeAtMost(u64, min_sleep_us, max_sleep_us) } };
    a.elapsed_us = 0;
}

/// Heads for a random spot, at a run now and then.
fn setOff(a: *Actor) void {
    const target = a.randomTarget();
    a.walkTo(target, a.can(.run) and a.prng.random().float(f32) < run_chance);
}

fn walkTo(a: *Actor, target: f32, running: bool) void {
    if (target != a.position) a.direction = if (target > a.position) .forward else .backward;
    var airborne_us: ?u64 = null;
    switch (a.state) {
        // Keep the animation going, and any jump in progress.
        .walking => |walking| {
            if (walking.running != running) a.elapsed_us = 0;
            airborne_us = walking.airborne_us;
        },
        else => a.elapsed_us = 0,
    }
    a.state = .{ .walking = .{ .target = target, .running = running, .airborne_us = airborne_us } };
}

/// Whether to jump now: while roaming, now and then, and only with room to
/// land before the target and before the next corner.
fn takesOff(a: *Actor, target: f32, running: bool, dt_us: u64) bool {
    if (a.mode != .roam or !a.can(.jump)) return false;
    const speed = if (running) a.rambler.run_speed else a.rambler.speed;
    const reach = speed * @as(f32, @floatFromInt(a.airtimeUs())) / std.time.us_per_s;
    if (@abs(target - a.position) < reach) return false;
    // None along the bottom alone, so this changes nothing there.
    if (a.track().cornerAhead(a.position, a.direction)) |room| if (room < reach) return false;
    return a.prng.random().uintLessThan(u64, mean_jump_interval_us) < dt_us;
}

/// How long a jump lasts: as long as something thrown `jump_height` pixels
/// up takes to fall back down.
fn airtimeUs(a: *const Actor) u64 {
    const height: f32 = @floatFromInt(a.rambler.jump_height);
    return @intFromFloat(2 * @sqrt(2 * height / gravity) * std.time.us_per_s);
}

/// The height of a jump at this moment: a parabola that peaks at the jump
/// height halfway through.
fn lift(a: *const Actor) u16 {
    const airborne_us = switch (a.state) {
        .walking => |walking| walking.airborne_us orelse return 0,
        else => return 0,
    };
    const t = @as(f32, @floatFromInt(airborne_us)) / @as(f32, @floatFromInt(a.airtimeUs()));
    const height: f32 = @floatFromInt(a.rambler.jump_height);
    return @intFromFloat(@round(4 * height * t * (1 - t)));
}

/// Picks a spot on the track, preferably a good stroll away from the
/// current one. On a loop it is the shorter way round, and the target is
/// not wrapped: it lies that far ahead of or behind the current position.
fn randomTarget(a: *Actor) f32 {
    const t = a.track();
    const random = a.prng.random();
    const start = t.start();
    if (!t.loops()) {
        const span = t.end() - start;
        const min_distance = @min(span / 3, 24);
        var target: f32 = 0;
        for (0..8) |_| {
            target = start + @min(span, @floor(random.float(f32) * (span + 1)));
            if (@abs(target - a.position) >= min_distance) break;
        }
        return target;
    }
    // Half the loop is the longest stroll, so a third of that is as far
    // as a stroll should at least go.
    const length = t.end() - start;
    const min_distance = @min(length / 6, 24);
    var offset: f32 = 0;
    for (0..8) |_| {
        const spot = start + @floor(random.float(f32) * length);
        offset = @mod(spot - a.position + length / 2, length) - length / 2;
        if (@abs(offset) >= min_distance) break;
    }
    return a.position + offset;
}

const testing = std.testing;

const test_frames = [_]Sprite{
    .{ .width = 4, .height = 1, .pixels = "kk.." },
    .{ .width = 4, .height = 1, .pixels = "..kk" },
};

fn testRambler(with_idle: bool) Rambler {
    var animations: Rambler.Animations = .initFill(null);
    animations.set(.walk, .{ .frames = &test_frames, .frame_ms = 100 });
    if (with_idle) animations.set(.idle, .{ .frames = test_frames[0..1], .frame_ms = 500 });
    return .{
        .id = "test",
        .name = "Test",
        .description = "",
        .width = 4,
        .height = 1,
        .facing = .right,
        .palette = .{},
        .animations = .init(.{ .floor = animations, .wall = .initFill(null), .ceiling = .initFill(null) }),
        .edges = .initOne(.bottom),
        .speed = 10,
        .run_speed = 25,
        .jump_height = 3,
    };
}

/// A frame for each of the optional animations, so that tests can tell
/// them apart.
const run_frames = [_]Sprite{.{ .width = 4, .height = 1, .pixels = "k.k." }};
const sleep_frames = [_]Sprite{.{ .width = 4, .height = 1, .pixels = "kkkk" }};
const jump_frames = [_]Sprite{
    .{ .width = 4, .height = 1, .pixels = "k..k" },
    .{ .width = 4, .height = 1, .pixels = ".kk." },
};

/// `testRambler`, plus the animations for `kinds` (some of run, sleep and
/// jump).
fn testRamblerWith(with_idle: bool, kinds: []const Rambler.Animation.Kind) Rambler {
    var r = testRambler(with_idle);
    for (kinds) |kind| {
        const frames: []const Sprite = switch (kind) {
            .run => &run_frames,
            .sleep => &sleep_frames,
            .jump => &jump_frames,
            .idle, .walk => unreachable,
        };
        r.animations.getPtr(.floor).set(kind, .{ .frames = frames, .frame_ms = 100 });
    }
    return r;
}

/// The one frame of animation `kind` on `surface` for `testClimber`, with
/// pixels of its own so that tests can tell which set a frame came from.
/// Wall frames stand on end: as wide as the rambler is tall, and as tall
/// as it is wide.
fn climberFrames(comptime surface: Rambler.Surface, comptime kind: Rambler.Animation.Kind) []const Sprite {
    const frames = struct {
        const number = @intFromEnum(surface) * std.meta.fields(Rambler.Animation.Kind).len + @intFromEnum(kind) + 1;
        const pixels: [4]u8 = blk: {
            var p: [4]u8 = undefined;
            for (&p, 0..) |*pixel, i| pixel.* = if (number >> i & 1 != 0) 'k' else '.';
            break :blk p;
        };
        const list = [_]Sprite{if (surface == .wall)
            .{ .width = 1, .height = 4, .pixels = &pixels }
        else
            .{ .width = 4, .height = 1, .pixels = &pixels }};
    };
    return &frames.list;
}

/// A rambler that walks along the bottom and `edges`, with the animations
/// for `floor`, `wall` and `ceiling` on each surface.
fn testClimber(
    edges: []const Rambler.Edge,
    floor: []const Rambler.Animation.Kind,
    wall: []const Rambler.Animation.Kind,
    ceiling: []const Rambler.Animation.Kind,
) Rambler {
    var r = testRambler(false);
    r.animations = .initFill(.initFill(null));
    for (edges) |e| r.edges.insert(e);
    inline for (comptime std.enums.values(Rambler.Surface)) |surface| {
        const kinds = switch (surface) {
            .floor => floor,
            .wall => wall,
            .ceiling => ceiling,
        };
        for (kinds) |kind| switch (kind) {
            inline else => |k| r.animations.getPtr(surface).set(k, .{ .frames = climberFrames(surface, k), .frame_ms = 100 }),
        };
    }
    return r;
}

const every_kind = std.enums.values(Rambler.Animation.Kind);
const all_round = [_]Rambler.Edge{ .left, .right, .top };

/// Whether `f` lies wholly on a canvas of `field`, and is drawn from the
/// animations for the surface of its edge, standing on end on a wall.
fn expectPlaced(rambler: *const Rambler, field: Field, f: Frame) !void {
    try testing.expect(f.x >= 0 and f.y >= 0);
    try testing.expect(f.x + f.sprite.width <= field.width and f.y + f.sprite.height <= field.height);
    const upright = f.edge.surface() == .wall;
    try testing.expectEqual(if (upright) rambler.width else rambler.height, f.sprite.height);
    try testing.expectEqual(if (upright) rambler.height else rambler.width, f.sprite.width);
    for (rambler.animations.get(f.edge.surface()).values) |maybe_anim| {
        const anim = maybe_anim orelse continue;
        for (anim.frames) |s| if (s.pixels.ptr == f.sprite.pixels.ptr) return;
    }
    return error.TestUnexpectedResult;
}

const tick_us = 33_333;
const test_field: Field = .{ .width = 60, .height = 40 };

test "the same seed produces the same run" {
    for ([_]Rambler{
        testRambler(true),
        testRamblerWith(true, &.{ .run, .sleep, .jump }),
        testClimber(&all_round, every_kind, every_kind, every_kind),
    }) |rambler| {
        var a: Actor = .init(&rambler, .roam, 42, test_field);
        var b: Actor = .init(&rambler, .roam, 42, test_field);
        for (0..3000) |_| {
            a.update(tick_us);
            b.update(tick_us);
            try testing.expectEqual(a.position, b.position);
            try testing.expectEqual(a.frame(), b.frame());
        }
    }
}

test "roaming stays on screen once entered" {
    for ([_]Rambler{ testRambler(true), testRamblerWith(true, &.{ .run, .sleep, .jump }) }) |rambler| {
        var a: Actor = .init(&rambler, .roam, 7, test_field);
        // Walk in first.
        while (a.state == .walking) a.update(tick_us);
        var rested = false;
        for (0..20_000) |_| {
            a.update(tick_us);
            try testing.expect(a.position >= 0 and a.position <= 56);
            if (a.state == .resting) rested = true;
        }
        try testing.expect(rested);
        try testing.expect(!a.done);
    }
}

test "once crosses the screen and finishes" {
    const rambler = testRambler(false);
    var a: Actor = .init(&rambler, .once, 1, .{ .width = 40, .height = 40 });
    const start = a.position;
    var ticks: usize = 0;
    while (!a.done) : (ticks += 1) {
        a.update(tick_us);
        try testing.expect(ticks < 1000);
    }
    // 44 pixels at 10 pixels per second.
    try testing.expectApproxEqAbs(4.4, @as(f32, @floatFromInt(ticks)) * tick_us / std.time.us_per_s, 0.1);
    try testing.expect(a.position != start);
}

test "frames follow the direction of travel" {
    const rambler = testRambler(false);
    var a: Actor = .init(&rambler, .once, 1, .{ .width = 40, .height = 40 });
    try testing.expectEqual(a.direction != .forward, a.frame().flip.x);
    const first = a.frame().sprite.pixels;
    for (0..4) |_| a.update(tick_us);
    try testing.expect(first.ptr != a.frame().sprite.pixels.ptr);
}

test "ramblers without run, sleep or jump move as they always have" {
    // Fingerprints of the exact position, the frame and its direction on
    // every tick, recorded before the actor could run, sleep or jump. If
    // one changes, existing ramblers no longer take the same stroll for
    // the same --seed. The height of the screen makes no difference to
    // ramblers that only walk along the bottom.
    const cases = [_]struct { idle: bool, mode: Mode, seed: u64, ticks: usize, fingerprint: u64 }{
        .{ .idle = true, .mode = .roam, .seed = 42, .ticks = 9000, .fingerprint = 0xd31b78aefaa5e895 },
        .{ .idle = false, .mode = .roam, .seed = 7, .ticks = 9000, .fingerprint = 0x1afb2c5fdcb130b6 },
        .{ .idle = false, .mode = .once, .seed = 1, .ticks = 600, .fingerprint = 0x187de2d4991f9ec4 },
        .{ .idle = false, .mode = .once, .seed = 2, .ticks = 600, .fingerprint = 0x310615ac71d64aac },
    };
    for (cases) |case| for ([_]u16{ 12, 200 }) |height| {
        const rambler = testRambler(case.idle);
        var cols: u16 = 60;
        var a: Actor = .init(&rambler, case.mode, case.seed, .{ .width = cols, .height = height });
        var hasher: std.hash.Wyhash = .init(0);
        for (0..case.ticks) |tick| {
            // Every 6 seconds, widen the screen or narrow it under the rambler.
            if (tick % 180 == 179) {
                cols = if (cols == 90) 30 else 90;
                a.resize(.{ .width = cols, .height = height });
            }
            a.update(tick_us);
            const f = a.frame();
            try testing.expectEqual(0, f.lift);
            try testing.expectEqual(.bottom, f.edge);
            try testing.expectEqual(@as(i32, height) - f.sprite.height, f.y);
            hasher.update(std.mem.asBytes(&a.position));
            hasher.update(f.sprite.pixels);
            hasher.update(&.{ @intFromBool(f.flip.x), @intFromBool(a.done) });
            if (a.done) break;
        }
        try testing.expect(a.done == (case.mode == .once));
        try testing.expectEqual(case.fingerprint, hasher.final());
    };
}

test "ramblers run, sleep and jump with the animations for it" {
    const rambler = testRamblerWith(true, &.{ .run, .sleep, .jump });
    var a: Actor = .init(&rambler, .roam, 1, test_field);
    var ran = false;
    var slept = false;
    var jumped = false;
    for (0..20_000) |_| {
        a.update(tick_us);
        const pixels = a.frame().sprite.pixels;
        switch (a.state) {
            .walking => |walking| if (walking.airborne_us) |airborne_us| {
                jumped = true;
                // Whether running or not.
                const index = @min(airborne_us / (100 * std.time.us_per_ms), jump_frames.len - 1);
                try testing.expectEqualStrings(jump_frames[index].pixels, pixels);
            } else if (walking.running) {
                ran = true;
                try testing.expectEqualStrings(run_frames[0].pixels, pixels);
            },
            .sleeping => {
                slept = true;
                try testing.expectEqualStrings(sleep_frames[0].pixels, pixels);
            },
            .resting => {},
        }
    }
    try testing.expect(ran and slept and jumped);
}

test "running moves at the run speed" {
    const rambler = testRamblerWith(true, &.{.run});
    var a: Actor = .init(&rambler, .roam, 1, test_field);
    var runs: usize = 0;
    for (0..20_000) |_| {
        const before = a;
        a.update(tick_us);
        // Only compare steps within one stroll that did not reach its target.
        if (before.state != .walking or a.state != .walking) continue;
        const target = before.state.walking.target;
        if (a.state.walking.target != target or a.position == target) continue;
        const speed = if (before.state.walking.running) rambler.run_speed else rambler.speed;
        try testing.expectApproxEqAbs(speed * tick_us / std.time.us_per_s, @abs(a.position - before.position), 1e-3);
        if (before.state.walking.running) runs += 1;
    }
    try testing.expect(runs > 0);
}

test "a jump rises to the jump height and lands" {
    const rambler = testRamblerWith(true, &.{.jump});
    var a: Actor = .init(&rambler, .roam, 1, test_field);
    var jumps: usize = 0;
    var highest: u16 = 0;
    var was_airborne = false;
    for (0..20_000) |_| {
        a.update(tick_us);
        const f = a.frame();
        try testing.expect(f.lift <= rambler.jump_height);
        highest = @max(highest, f.lift);
        const airborne_us: ?u64 = switch (a.state) {
            .walking => |walking| walking.airborne_us,
            .resting, .sleeping => null,
        };
        if (airborne_us) |us| {
            // Played once from takeoff, then held.
            const index = @min(us / (100 * std.time.us_per_ms), jump_frames.len - 1);
            try testing.expectEqualStrings(jump_frames[index].pixels, f.sprite.pixels);
            if (!was_airborne) jumps += 1;
        } else {
            try testing.expectEqual(0, f.lift);
        }
        was_airborne = airborne_us != null;
    }
    try testing.expect(jumps > 0);
    try testing.expectEqual(rambler.jump_height, highest);
}

test "a jump only starts with room to land before the target" {
    const rambler = testRamblerWith(true, &.{ .run, .jump });
    var walking_takeoffs: usize = 0;
    var running_takeoffs: usize = 0;
    for (0..10) |seed| {
        var a: Actor = .init(&rambler, .roam, seed, test_field);
        for (0..20_000) |_| {
            const before = a;
            a.update(tick_us);
            // Only look at the ticks that take off.
            if (before.state != .walking or before.state.walking.airborne_us != null) continue;
            if (a.state != .walking or a.state.walking.airborne_us == null) continue;
            const walking = before.state.walking;
            const speed = if (walking.running) rambler.run_speed else rambler.speed;
            // The distance a jump covers at this pace.
            const reach = speed * @as(f32, @floatFromInt(a.airtimeUs())) / std.time.us_per_s;
            try testing.expect(@abs(walking.target - before.position) >= reach);
            if (walking.running) running_takeoffs += 1 else walking_takeoffs += 1;
        }
    }
    // A run needs more room, so check both.
    try testing.expect(walking_takeoffs > 0 and running_takeoffs > 0);
}

test "a jump that reaches the target lands before arriving" {
    const rambler = testRamblerWith(true, &.{.jump});
    var a: Actor = .init(&rambler, .roam, 1, test_field);
    // Just taken off, a pixel short of the target.
    a.position = 20;
    a.state = .{ .walking = .{ .target = 21, .airborne_us = 0 } };
    // `b` takes the same jump with its target far away.
    var b = a;
    b.state.walking.target = 50;
    var ticks: usize = 0;
    while (true) : (ticks += 1) {
        a.update(tick_us);
        b.update(tick_us);
        if (b.state.walking.airborne_us == null) break;
        // No further than the target, and in the air like `b`.
        try testing.expect(a.state == .walking and a.state.walking.airborne_us != null);
        try testing.expect(a.position <= 21);
        try testing.expectEqual(b.frame().lift, a.frame().lift);
        try testing.expect(ticks < 100);
    }
    try testing.expectEqual(21, a.position);
    // Landed along with `b`, and only then arrived: resting, or off to
    // somewhere else.
    try testing.expectEqual(0, a.frame().lift);
    try testing.expect(a.state != .walking or a.state.walking.target != 21);
}

test "ramblers without an idle animation only stop to sleep" {
    const rambler = testRamblerWith(false, &.{.sleep});
    var a: Actor = .init(&rambler, .roam, 1, test_field);
    var slept = false;
    for (0..20_000) |_| {
        a.update(tick_us);
        try testing.expect(a.state != .resting);
        if (a.state == .sleeping) slept = true;
    }
    try testing.expect(slept);
}

test "once only walks, whatever the rambler can do" {
    const rambler = testRamblerWith(false, &.{ .run, .sleep, .jump });
    for (0..10) |seed| {
        var a: Actor = .init(&rambler, .once, seed, .{ .width = 40, .height = 40 });
        var ticks: usize = 0;
        while (!a.done) : (ticks += 1) {
            a.update(tick_us);
            try testing.expect(!a.state.walking.running);
            try testing.expect(a.state.walking.airborne_us == null);
            try testing.expectEqual(0, a.frame().lift);
            try testing.expect(ticks < 1000);
        }
        // 44 pixels at the walking speed of 10 pixels per second.
        try testing.expectApproxEqAbs(4.4, @as(f32, @floatFromInt(ticks)) * tick_us / std.time.us_per_s, 0.1);
    }
}

test "a resize wakes a rambler left off screen, and lets a jump finish" {
    const rambler = testRamblerWith(true, &.{ .sleep, .jump });
    var a: Actor = .init(&rambler, .roam, 3, .{ .width = 90, .height = 40 });
    // Fall asleep too far right to fit on a 30-column screen.
    var ticks: usize = 0;
    while (!(a.state == .sleeping and a.position > 26)) : (ticks += 1) {
        a.update(tick_us);
        try testing.expect(ticks < 20_000);
    }
    a.resize(.{ .width = 30, .height = 40 });
    try testing.expect(a.state == .walking);
    // Narrow the screen further in mid-air: the jump goes on, and lands.
    ticks = 0;
    while (!(a.state == .walking and a.state.walking.airborne_us != null and a.frame().lift > 0)) : (ticks += 1) {
        a.update(tick_us);
        try testing.expect(ticks < 20_000);
    }
    a.resize(.{ .width = 10, .height = 40 });
    try testing.expect(a.state.walking.airborne_us != null);
    ticks = 0;
    while (a.state == .walking and a.state.walking.airborne_us != null) : (ticks += 1) {
        a.update(tick_us);
        try testing.expect(ticks < 100);
    }
    try testing.expectEqual(0, a.frame().lift);
}

test "climbers go round every edge and stay on screen" {
    const rambler = testClimber(&all_round, every_kind, every_kind, every_kind);
    for (0..5) |seed| {
        var a: Actor = .init(&rambler, .roam, seed, test_field);
        while (a.entering) a.update(tick_us);
        var visited: std.EnumSet(Rambler.Edge) = .initEmpty();
        for (0..20_000) |_| {
            a.update(tick_us);
            const f = a.frame();
            try expectPlaced(&rambler, test_field, f);
            visited.insert(f.edge);
            const forward = a.direction == .forward;
            const expected: Canvas.Flip = switch (f.edge) {
                .bottom => .{ .x = !forward },
                .top => .{ .x = forward },
                .right => .{ .y = !forward },
                .left => .{ .x = true, .y = forward },
            };
            try testing.expectEqual(expected, f.flip);
        }
        try testing.expect(visited.eql(.initFull()));
    }
}

test "climbers only walk their edges" {
    const Case = struct { edges: []const Rambler.Edge, never: Rambler.Edge };
    const cases = [_]Case{
        .{ .edges = &.{.right}, .never = .left },
        .{ .edges = &.{.right}, .never = .top },
        .{ .edges = &.{ .left, .top }, .never = .right },
    };
    for (cases) |case| {
        const rambler = testClimber(case.edges, every_kind, every_kind, every_kind);
        for (0..5) |seed| {
            var a: Actor = .init(&rambler, .roam, seed, test_field);
            var visited: std.EnumSet(Rambler.Edge) = .initEmpty();
            for (0..20_000) |_| {
                a.update(tick_us);
                const f = a.frame();
                try testing.expect(f.edge != case.never);
                if (!a.entering) try expectPlaced(&rambler, test_field, f);
                visited.insert(f.edge);
            }
            try testing.expect(visited.eql(rambler.edges));
        }
    }
}

test "climbers come in along the bottom" {
    const rambler = testClimber(&all_round, every_kind, every_kind, every_kind);
    var from_left = false;
    var from_right = false;
    for (0..10) |seed| {
        var a: Actor = .init(&rambler, .roam, seed, test_field);
        const target = a.state.walking.target;
        try testing.expect(target >= 0 and target <= 56);
        if (a.position < 0) from_left = true else from_right = true;
        var ticks: usize = 0;
        while (a.entering) : (ticks += 1) {
            try testing.expectEqual(.bottom, a.edge());
            try testing.expectEqual(.bottom, a.frame().edge);
            try testing.expect(ticks < 1000);
            a.update(tick_us);
        }
        try testing.expectEqual(target, a.position);
    }
    try testing.expect(from_left and from_right);
}

test "a loop goes the shorter way round" {
    const rambler = testClimber(&all_round, every_kind, every_kind, every_kind);
    const length = 184;
    var crossed = false;
    for (0..5) |seed| {
        var a: Actor = .init(&rambler, .roam, seed, test_field);
        while (a.entering) a.update(tick_us);
        for (0..20_000) |_| {
            const before = a;
            a.update(tick_us);
            if (a.state != .walking) continue;
            // Only look at the ticks that set off.
            if (before.state == .walking and before.state.walking.target == a.state.walking.target) continue;
            const target = a.state.walking.target;
            try testing.expect(a.position >= -length / 2 and a.position < length / 2);
            try testing.expect(@abs(target - a.position) <= length / 2);
            // Round the top-right corner, where the loop is joined.
            if (target < -length / 2 or target >= length / 2) crossed = true;
        }
    }
    try testing.expect(crossed);
}

test "ramblers only rest where they have idle frames" {
    const rambler = testClimber(&all_round, &.{ .idle, .walk, .sleep }, &.{ .idle, .walk, .sleep }, &.{.walk});
    var stopped: std.EnumSet(Rambler.Edge) = .initEmpty();
    var visited: std.EnumSet(Rambler.Edge) = .initEmpty();
    for (0..5) |seed| {
        var a: Actor = .init(&rambler, .roam, seed, test_field);
        for (0..20_000) |_| {
            a.update(tick_us);
            const on = a.frame().edge;
            visited.insert(on);
            if (a.state != .walking) stopped.insert(on);
        }
    }
    try testing.expect(visited.contains(.top));
    try testing.expect(!stopped.contains(.top));
    try testing.expect(stopped.contains(.bottom) and stopped.contains(.left) and stopped.contains(.right));
}

test "a jump never goes round a corner" {
    const rambler = testClimber(&all_round, every_kind, every_kind, every_kind);
    var jumped: std.EnumSet(Rambler.Edge) = .initEmpty();
    for (0..5) |seed| {
        var a: Actor = .init(&rambler, .roam, seed, test_field);
        for (0..20_000) |_| {
            const before = a;
            a.update(tick_us);
            const was_airborne = before.state == .walking and before.state.walking.airborne_us != null;
            const airborne = a.state == .walking and a.state.walking.airborne_us != null;
            // In the air the rambler stays on its edge, and lands on
            // reaching another.
            if (airborne) try testing.expectEqual(before.edge(), a.edge());
            if (was_airborne or !airborne) continue;
            // Taken off with room to land before the next corner.
            const walking = before.state.walking;
            const speed = if (walking.running) rambler.run_speed else rambler.speed;
            const reach = speed * @as(f32, @floatFromInt(a.airtimeUs())) / std.time.us_per_s;
            if (before.track().cornerAhead(before.position, before.direction)) |room| try testing.expect(room >= reach);
            jumped.insert(before.edge());
        }
    }
    try testing.expect(jumped.eql(.initFull()));

    // Brought to a corner in mid-air, as by a resize, it lands there and
    // walks on.
    var a: Actor = .init(&rambler, .roam, 1, test_field);
    while (a.entering) a.update(tick_us);
    a.position = 55;
    a.direction = .forward;
    a.state = .{ .walking = .{ .target = 70, .airborne_us = 0 } };
    var ticks: usize = 0;
    while (a.edge() == .bottom) : (ticks += 1) {
        try testing.expect(a.state.walking.airborne_us != null);
        try testing.expect(ticks < 10);
        a.update(tick_us);
    }
    try testing.expectEqual(Walking{ .target = 70 }, a.state.walking);
    try testing.expectEqual(0, a.frame().lift);
}

test "running turns to walking where the rambler cannot run" {
    const rambler = testClimber(&all_round, &.{ .idle, .walk, .run }, &.{ .idle, .walk }, &.{ .idle, .walk });
    var ran = false;
    var turned = false;
    for (0..5) |seed| {
        var a: Actor = .init(&rambler, .roam, seed, test_field);
        for (0..20_000) |_| {
            const before = a;
            a.update(tick_us);
            if (a.state != .walking) continue;
            if (a.state.walking.running) {
                ran = true;
                try testing.expectEqual(.bottom, a.edge());
            } else if (before.state == .walking and before.state.walking.running and a.state.walking.target == before.state.walking.target) {
                // Went round a corner at a run, and walks on from there,
                // with the walk cycle from its start.
                turned = true;
                try testing.expect(a.edge() != .bottom);
                try testing.expectEqual(0, a.elapsed_us);
            }
        }
    }
    try testing.expect(ran and turned);
}

test "a resize keeps a climber on its edge" {
    const rambler = testClimber(&all_round, every_kind, every_kind, every_kind);
    var a: Actor = .init(&rambler, .roam, 1, test_field);
    while (a.entering) a.update(tick_us);
    // Resting against the right wall, 10 pixels from the top.
    a.position = a.track().position(.right, 10);
    a.state = .{ .resting = .{ .remaining_us = std.time.us_per_min } };
    for ([_]Field{ .{ .width = 80, .height = 40 }, .{ .width = 30, .height = 40 }, test_field }) |field| {
        a.resize(field);
        try testing.expect(a.state == .resting);
        const f = a.frame();
        try expectPlaced(&rambler, field, f);
        try testing.expectEqual(.right, f.edge);
        try testing.expectEqual(@as(i32, field.width) - f.sprite.width, f.x);
        try testing.expectEqual(10, f.y);
    }
    // A screen too short for that pulls it down to the foot of the wall,
    // a corner, which belongs to the floor.
    const short: Field = .{ .width = 60, .height = 12 };
    a.resize(short);
    try testing.expect(a.state == .resting);
    try expectPlaced(&rambler, short, a.frame());
    try testing.expectEqual(a.track().position(.right, 8), a.position);
    try testing.expectEqual(Track.Spot{ .edge = .bottom, .along = 56 }, a.track().locate(a.position));

    // On a loop a stroll keeps going the same way round, even across the
    // top-right corner where the loop is joined.
    for ([_]Track.Direction{ .forward, .backward }) |direction| {
        var b: Actor = .init(&rambler, .roam, 1, test_field);
        while (b.entering) b.update(tick_us);
        // 20 pixels from a spot on the ceiling, or on the right wall.
        const t = b.track();
        b.position = switch (direction) {
            .forward => t.position(.right, 5),
            .backward => t.position(.top, 51),
        };
        b.direction = direction;
        b.state = .{ .walking = .{ .target = if (direction == .forward) b.position + 20 else b.position - 20 } };
        const wide: Field = .{ .width = 80, .height = 48 };
        b.resize(wide);
        try testing.expectEqual(direction, b.direction);
        // 5 pixels down the wall and 35 along the ceiling, or the other
        // way round.
        try testing.expectEqual(40, @abs(b.state.walking.target - b.position));
        try testing.expectEqual(direction == .forward, b.state.walking.target > b.position);
        const target = b.track().locate(b.state.walking.target);
        try testing.expectEqual(Track.Spot{ .edge = if (direction == .forward) .top else .right, .along = if (direction == .forward) 41 else 15 }, target);
        // Walks there, all the way the same way.
        const goal = b.state.walking.target;
        var ticks: usize = 0;
        while (b.state == .walking and b.state.walking.target == goal) : (ticks += 1) {
            const before = b.position;
            b.update(tick_us);
            try expectPlaced(&rambler, wide, b.frame());
            try testing.expect(ticks < 1000);
            if (b.state == .walking and b.state.walking.target == goal) try testing.expectEqual(direction == .forward, b.position > before);
        }
        // Arriving brings the position back within the loop.
        try testing.expectEqual(b.track().wrap(goal), b.position);
    }
}

test "a resize calls a climber back past an open end" {
    const rambler = testClimber(&.{.left}, every_kind, every_kind, every_kind);
    var a: Actor = .init(&rambler, .roam, 1, test_field);
    while (a.entering) a.update(tick_us);
    // Resting too far right to fit on a 30-column screen.
    a.position = 50;
    a.state = .{ .resting = .{ .remaining_us = std.time.us_per_min } };
    a.resize(.{ .width = 30, .height = 40 });
    // Walks back on screen, like a rambler along the bottom alone.
    try testing.expect(a.state == .walking);
    try testing.expectEqual(.backward, a.direction);
    try testing.expectEqual(50, a.position);
    try testing.expect(a.state.walking.target >= a.track().start() and a.state.walking.target <= 26);
}

const Diagnostics = @import("Diagnostics.zig");
const Source = @import("Source.zig");
const builtin_ramblers = @import("builtin_ramblers");

test "every built-in rambler roams on screen" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (builtin_ramblers.entries) |entry| {
        var diag: Diagnostics = .init(arena);
        const rambler = try Rambler.load(arena, Source.embedded(entry), &diag);
        for ([_]Field{ .{ .width = 80, .height = 48 }, .{ .width = 40, .height = 20 } }) |first| {
            var field = first;
            var a: Actor = .init(&rambler, .roam, 5, field);
            // Off screen until it has come in, and after a resize until it
            // has come back from wherever that left it.
            var away = true;
            for (0..20_000) |tick| {
                if (tick == 10_000) {
                    field = if (field.width == 80) .{ .width = 40, .height = 20 } else .{ .width = 80, .height = 48 };
                    a.resize(field);
                    away = true;
                }
                const before = a;
                a.update(tick_us);
                if (!a.entering and before.state == .walking and (a.state != .walking or a.state.walking.target != before.state.walking.target)) away = false;
                if (!away) try expectPlaced(&rambler, field, a.frame());
            }
        }
    }
}
