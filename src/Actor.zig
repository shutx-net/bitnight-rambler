//! Movement, kept separate from animation: the actor decides where the
//! rambler goes and which kind of animation fits, and the rambler supplies
//! the frames. All randomness comes from a seeded generator and time only
//! advances in fixed steps, so the same seed always produces the same run.

const Actor = @This();

const std = @import("std");
const Rambler = @import("Rambler.zig");
const Sprite = @import("sprite.zig").Sprite;

rambler: *const Rambler,
mode: Mode,
prng: std.Random.DefaultPrng,
/// Left edge of the sprite in pixels. Fractional, so that slow ramblers
/// still move smoothly.
x: f32,
direction: Rambler.Facing,
state: State,
/// Time spent in the current state; selects the animation frame.
elapsed_us: u64 = 0,
/// Set in `once` mode when the rambler has left the screen.
done: bool = false,

pub const Mode = enum {
    /// Wander back and forth, pausing now and then, until told to stop.
    roam,
    /// Cross the screen once and finish, like `sl`.
    once,
};

const State = union(enum) {
    walking: struct { target: f32 },
    resting: struct { remaining_us: u64 },
};

pub const Frame = struct {
    sprite: Sprite,
    x: i32,
    /// Whether the sprite must be flipped to face the direction of travel.
    mirror: bool,
};

const rest_chance = 0.75;
const min_rest_us = 1500 * std.time.us_per_ms;
const max_rest_us = 5000 * std.time.us_per_ms;

pub fn init(rambler: *const Rambler, mode: Mode, seed: u64, field_width: u16) Actor {
    var a: Actor = .{
        .rambler = rambler,
        .mode = mode,
        .prng = .init(seed),
        .x = 0,
        .direction = .right,
        .state = .{ .resting = .{ .remaining_us = 0 } },
    };
    // Enter from just outside one of the edges.
    const from_left = a.prng.random().boolean();
    const width: f32 = @floatFromInt(rambler.width);
    const field: f32 = @floatFromInt(field_width);
    a.x = if (from_left) -width else field;
    switch (mode) {
        .roam => a.walkTo(a.randomTarget(field_width)),
        .once => a.walkTo(if (from_left) field else -width),
    }
    return a;
}

pub fn update(a: *Actor, dt_us: u64, field_width: u16) void {
    a.elapsed_us += dt_us;
    switch (a.state) {
        .walking => |walking| {
            const step = a.rambler.speed * @as(f32, @floatFromInt(dt_us)) / std.time.us_per_s;
            const distance = walking.target - a.x;
            if (@abs(distance) > step) {
                a.x += std.math.sign(distance) * step;
                return;
            }
            a.x = walking.target;
            a.arrive(field_width);
        },
        .resting => |resting| {
            if (resting.remaining_us > dt_us) {
                a.state.resting.remaining_us -= dt_us;
            } else {
                a.walkTo(a.randomTarget(field_width));
            }
        },
    }
}

/// Keeps the rambler's plans in line with a resized terminal.
pub fn resize(a: *Actor, field_width: u16) void {
    switch (a.mode) {
        // Still head for the far edge, wherever that is now.
        .once => if (a.direction == .right) {
            a.state.walking.target = @floatFromInt(field_width);
        },
        // Come back if the screen shrank under the rambler or its target.
        .roam => {
            const max_x = maxX(a.rambler, field_width);
            const out_of_bounds = switch (a.state) {
                .walking => |walking| walking.target > max_x,
                .resting => a.x > max_x,
            };
            if (out_of_bounds) a.walkTo(a.randomTarget(field_width));
        },
    }
}

pub fn frame(a: *const Actor) Frame {
    const anim = a.rambler.animation(switch (a.state) {
        .walking => .walk,
        .resting => .idle,
    });
    const index = (a.elapsed_us / (@as(u64, anim.frame_ms) * std.time.us_per_ms)) % anim.frames.len;
    return .{
        .sprite = anim.frames[index],
        .x = @intFromFloat(@floor(a.x)),
        .mirror = a.direction != a.rambler.facing,
    };
}

fn arrive(a: *Actor, field_width: u16) void {
    if (a.mode == .once) {
        a.done = true;
        return;
    }
    const random = a.prng.random();
    // Ramblers without an idle animation, like a train, just keep going.
    if (a.rambler.animations.get(.idle) != null and random.float(f32) < rest_chance) {
        a.state = .{ .resting = .{ .remaining_us = random.intRangeAtMost(u64, min_rest_us, max_rest_us) } };
        a.elapsed_us = 0;
    } else {
        a.walkTo(a.randomTarget(field_width));
    }
}

fn walkTo(a: *Actor, target: f32) void {
    if (target != a.x) a.direction = if (target > a.x) .right else .left;
    if (a.state != .walking) a.elapsed_us = 0;
    a.state = .{ .walking = .{ .target = target } };
}

/// Picks a spot on screen, preferably a good stroll away from the current one.
fn randomTarget(a: *Actor, field_width: u16) f32 {
    const max_x = maxX(a.rambler, field_width);
    const random = a.prng.random();
    const min_distance = @min(max_x / 3, 24);
    var target: f32 = 0;
    for (0..8) |_| {
        target = @min(max_x, @floor(random.float(f32) * (max_x + 1)));
        if (@abs(target - a.x) >= min_distance) break;
    }
    return target;
}

/// The rightmost position at which the whole sprite is still on screen.
fn maxX(rambler: *const Rambler, field_width: u16) f32 {
    return @floatFromInt(@max(0, @as(i32, field_width) - rambler.width));
}

const testing = std.testing;

const test_frames = [_]Sprite{
    .{ .width = 4, .height = 1, .pixels = "kk.." },
    .{ .width = 4, .height = 1, .pixels = "..kk" },
};

fn testRambler(with_idle: bool) Rambler {
    var animations: std.EnumArray(Rambler.Animation.Kind, ?Rambler.Animation) = .initFill(null);
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
        .animations = animations,
        .speed = 10,
    };
}

const tick_us = 33_333;

test "the same seed produces the same run" {
    const rambler = testRambler(true);
    var a: Actor = .init(&rambler, .roam, 42, 60);
    var b: Actor = .init(&rambler, .roam, 42, 60);
    for (0..3000) |_| {
        a.update(tick_us, 60);
        b.update(tick_us, 60);
        try testing.expectEqual(a.x, b.x);
        try testing.expectEqual(a.frame().mirror, b.frame().mirror);
    }
}

test "roaming stays on screen once entered" {
    const rambler = testRambler(true);
    var a: Actor = .init(&rambler, .roam, 7, 60);
    // Walk in first.
    while (a.state == .walking) a.update(tick_us, 60);
    var rested = false;
    for (0..20_000) |_| {
        a.update(tick_us, 60);
        try testing.expect(a.x >= 0 and a.x <= 56);
        if (a.state == .resting) rested = true;
    }
    try testing.expect(rested);
    try testing.expect(!a.done);
}

test "once crosses the screen and finishes" {
    const rambler = testRambler(false);
    var a: Actor = .init(&rambler, .once, 1, 40);
    const start = a.x;
    var ticks: usize = 0;
    while (!a.done) : (ticks += 1) {
        a.update(tick_us, 40);
        try testing.expect(ticks < 1000);
    }
    // 44 pixels at 10 pixels per second.
    try testing.expectApproxEqAbs(4.4, @as(f32, @floatFromInt(ticks)) * tick_us / std.time.us_per_s, 0.1);
    try testing.expect(a.x != start);
}

test "frames follow the direction of travel" {
    const rambler = testRambler(false);
    var a: Actor = .init(&rambler, .once, 1, 40);
    try testing.expectEqual(a.direction != .right, a.frame().mirror);
    const first = a.frame().sprite.pixels;
    for (0..4) |_| a.update(tick_us, 40);
    try testing.expect(first.ptr != a.frame().sprite.pixels.ptr);
}

test "ramblers without run, sleep or jump move as they always have" {
    // Fingerprints of the exact position, the frame and its direction on
    // every tick, recorded before the actor could run, sleep or jump. If
    // one changes, existing ramblers no longer take the same stroll for
    // the same --seed.
    const cases = [_]struct { idle: bool, mode: Mode, seed: u64, ticks: usize, fingerprint: u64 }{
        .{ .idle = true, .mode = .roam, .seed = 42, .ticks = 9000, .fingerprint = 0xd31b78aefaa5e895 },
        .{ .idle = false, .mode = .roam, .seed = 7, .ticks = 9000, .fingerprint = 0x1afb2c5fdcb130b6 },
        .{ .idle = false, .mode = .once, .seed = 1, .ticks = 600, .fingerprint = 0x187de2d4991f9ec4 },
        .{ .idle = false, .mode = .once, .seed = 2, .ticks = 600, .fingerprint = 0x310615ac71d64aac },
    };
    for (cases) |case| {
        const rambler = testRambler(case.idle);
        var cols: u16 = 60;
        var a: Actor = .init(&rambler, case.mode, case.seed, cols);
        var hasher: std.hash.Wyhash = .init(0);
        for (0..case.ticks) |tick| {
            // Every 6 seconds, widen the screen or narrow it under the rambler.
            if (tick % 180 == 179) {
                cols = if (cols == 90) 30 else 90;
                a.resize(cols);
            }
            a.update(tick_us, cols);
            const f = a.frame();
            hasher.update(std.mem.asBytes(&a.x));
            hasher.update(f.sprite.pixels);
            hasher.update(&.{ @intFromBool(f.mirror), @intFromBool(a.done) });
            if (a.done) break;
        }
        try testing.expect(a.done == (case.mode == .once));
        try testing.expectEqual(case.fingerprint, hasher.final());
    }
}
