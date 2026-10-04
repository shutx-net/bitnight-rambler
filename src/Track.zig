//! The edges a rambler walks along, unrolled into one line. Positions on
//! it are in pixels: the bottom edge runs from 0 to `floor`, and there a
//! position is simply the sprite's left x. Higher positions go
//! counterclockwise, up the right wall and then left along the ceiling;
//! lower ones go up the left wall and then right along the ceiling. With
//! all four edges the track is a loop, joined at the top-right corner.
//!
//! The sprite is `extent` pixels long along every edge, so each edge is
//! that much shorter than the side of the screen it runs along. All of
//! this is pure geometry: the actor decides where to go, the track says
//! where on screen that is.

const Track = @This();

const std = @import("std");
const Edge = @import("Rambler.zig").Edge;
const Sprite = @import("sprite.zig").Sprite;

/// The edges on the track. The ceiling only counts next to a wall, since
/// a rambler can only get there by climbing one.
edges: std.EnumSet(Edge),
/// How far the sprite can go along the bottom edge, and the ceiling: the
/// rightmost x at which it is still wholly on screen.
floor: f32,
/// How far the sprite can go along either wall: the lowest y at which it
/// is still wholly on screen.
wall: f32,

/// The size of the canvas in pixels: as many columns as the terminal has,
/// and twice as many rows.
pub const Field = struct { width: u16, height: u16 };

/// The way along the track. Forward is counterclockwise: right along the
/// bottom, up the right wall, left along the ceiling and down the left
/// wall.
pub const Direction = enum { backward, forward };

/// Where a position lies on screen.
pub const Spot = struct {
    edge: Edge,
    /// The sprite's left x along the bottom and the ceiling, its top y
    /// along the walls.
    along: f32,
};

/// A point on the canvas, in pixels.
pub const Point = struct { x: i32, y: i32 };

/// `extent` is the length of the sprite along every edge, that is the
/// rambler's width.
pub fn init(edges: std.EnumSet(Edge), field: Field, extent: u16) Track {
    return .{
        .edges = edges,
        .floor = @floatFromInt(@max(0, @as(i32, field.width) - extent)),
        .wall = @floatFromInt(@max(0, @as(i32, field.height) - extent)),
    };
}

/// Whether the ceiling comes after the left wall, below 0. With all four
/// edges it does, and the track is a loop.
fn ceilingOnTheLeft(t: Track) bool {
    return t.edges.contains(.top) and t.edges.contains(.left);
}

/// Whether the ceiling comes after the right wall, above `floor`.
fn ceilingOnTheRight(t: Track) bool {
    return t.edges.contains(.top) and t.edges.contains(.right) and !t.edges.contains(.left);
}

/// The lowest position on the track: where the last edge counting
/// clockwise from the bottom ends.
pub fn start(t: Track) f32 {
    if (t.ceilingOnTheLeft()) return -t.wall - t.floor;
    if (t.edges.contains(.left)) return -t.wall;
    return 0;
}

/// The highest position on the track: where the last edge counting
/// counterclockwise from the bottom ends.
pub fn end(t: Track) f32 {
    if (t.ceilingOnTheRight()) return 2 * t.floor + t.wall;
    if (t.edges.contains(.right)) return t.floor + t.wall;
    return t.floor;
}

/// Whether the track goes all the way round the screen, so that `end`
/// and `start` are the same place.
pub fn loops(t: Track) bool {
    return t.edges.eql(.initFull()) and t.end() > t.start();
}

/// Brings position `at` on a loop back into [`start`, `end`). Positions
/// in that range, and every position on an open track, stay as they are.
pub fn wrap(t: Track, at: f32) f32 {
    if (!t.loops() or (at >= t.start() and at < t.end())) return at;
    return t.start() + @mod(at - t.start(), t.end() - t.start());
}

/// Where position `at` lies on screen. Corners belong to the bottom and
/// the ceiling. Past an open end of the track a position lies on that
/// end's edge, off screen.
pub fn locate(t: Track, at: f32) Spot {
    const p = t.wrap(at);
    if (p < 0 and t.edges.contains(.left)) {
        if (p > -t.wall or !t.ceilingOnTheLeft()) return .{ .edge = .left, .along = t.wall + p };
        return .{ .edge = .top, .along = -t.wall - p };
    }
    if (p > t.floor and t.edges.contains(.right)) {
        if (p < t.floor + t.wall or !t.ceilingOnTheRight()) return .{ .edge = .right, .along = t.floor + t.wall - p };
        return .{ .edge = .top, .along = 2 * t.floor + t.wall - p };
    }
    // No arithmetic, so that positions along the bottom stay exact.
    return .{ .edge = .bottom, .along = p };
}

/// The position of the spot `along` an edge: the inverse of `locate`.
pub fn position(t: Track, edge: Edge, along: f32) f32 {
    return switch (edge) {
        .bottom => along,
        .right => t.floor + t.wall - along,
        .left => along - t.wall,
        .top => if (t.ceilingOnTheLeft()) -t.wall - along else 2 * t.floor + t.wall - along,
    };
}

/// The position on this track of position `at` on `old`, the same track
/// before the screen was resized: the same spot on the same edge, pulled
/// back from any corner the edge has become too short to reach. Open ends
/// are left alone, so a rambler past one stays there.
pub fn carry(t: Track, old: Track, at: f32) f32 {
    const spot = old.locate(at);
    var along = spot.along;
    switch (spot.edge) {
        .bottom, .top => {
            if (t.edges.contains(.left)) along = @max(along, 0);
            if (t.edges.contains(.right)) along = @min(along, t.floor);
        },
        .left, .right => {
            if (t.edges.contains(.top)) along = @max(along, 0);
            along = @min(along, t.wall);
        },
    }
    return t.position(spot.edge, along);
}

/// How far it is from position `at` to the nearest corner at or ahead of it
/// in `direction`, where the rambler would go round onto another edge.
/// Null without one, as on a track along the bottom alone.
pub fn cornerAhead(t: Track, at: f32, direction: Direction) ?f32 {
    const p = t.wrap(at);
    const loop = t.loops();
    // On a loop the seam at `start` and `end` is the top-right corner, so
    // the way ahead always meets one of them.
    const corners = [_]?f32{
        if (t.edges.contains(.left)) 0 else null,
        if (t.edges.contains(.right)) t.floor else null,
        if (t.ceilingOnTheLeft()) -t.wall else null,
        if (t.ceilingOnTheRight()) t.floor + t.wall else null,
        if (loop) t.start() else null,
        if (loop) t.end() else null,
    };
    var nearest: ?f32 = null;
    for (corners) |maybe_corner| {
        const corner = maybe_corner orelse continue;
        const distance = switch (direction) {
            .forward => corner - p,
            .backward => p - corner,
        };
        if (distance >= 0 and (nearest == null or distance < nearest.?)) nearest = distance;
    }
    return nearest;
}

/// The top-left corner on the canvas at which to draw `sprite` against
/// `edge`, `along` it, and `lift` pixels away from it toward the middle
/// of the screen.
pub fn place(field: Field, edge: Edge, along: i32, lift: u16, sprite: Sprite) Point {
    return switch (edge) {
        .bottom => .{ .x = along, .y = @as(i32, field.height) - sprite.height - lift },
        .top => .{ .x = along, .y = lift },
        .left => .{ .x = lift, .y = along },
        .right => .{ .x = @as(i32, field.width) - sprite.width - lift, .y = along },
    };
}

const testing = std.testing;

/// The worked example: a 60x40 field and a sprite 4 pixels long, so the
/// floor is 56 pixels long, the walls 36, and the loop 184 all round.
const test_field: Field = .{ .width = 60, .height = 40 };

/// A track along the bottom and `edges`.
fn testTrack(edges: []const Edge, field: Field) Track {
    var set: std.EnumSet(Edge) = .initOne(.bottom);
    for (edges) |e| set.insert(e);
    return .init(set, field, 4);
}

const all_round = [_]Edge{ .left, .right, .top };

test place {
    const flat: Sprite = .{ .width = 4, .height = 2, .pixels = "kkkkkkkk" };
    // Wall frames are as wide as the rambler is tall, and as tall as it
    // is wide.
    const upright: Sprite = .{ .width = 2, .height = 4, .pixels = "kkkkkkkk" };
    try testing.expectEqual(Point{ .x = 10, .y = 38 }, place(test_field, .bottom, 10, 0, flat));
    try testing.expectEqual(Point{ .x = 10, .y = 35 }, place(test_field, .bottom, 10, 3, flat));
    try testing.expectEqual(Point{ .x = -3, .y = 38 }, place(test_field, .bottom, -3, 0, flat));
    try testing.expectEqual(Point{ .x = 10, .y = 0 }, place(test_field, .top, 10, 0, flat));
    try testing.expectEqual(Point{ .x = 10, .y = 3 }, place(test_field, .top, 10, 3, flat));
    try testing.expectEqual(Point{ .x = 0, .y = 7 }, place(test_field, .left, 7, 0, upright));
    try testing.expectEqual(Point{ .x = 3, .y = 7 }, place(test_field, .left, 7, 3, upright));
    try testing.expectEqual(Point{ .x = 58, .y = 7 }, place(test_field, .right, 7, 0, upright));
    try testing.expectEqual(Point{ .x = 55, .y = 7 }, place(test_field, .right, 7, 3, upright));
}

test "positions map onto the edges and back" {
    const Case = struct { edges: []const Edge, start: f32, end: f32 };
    const cases = [_]Case{
        .{ .edges = &.{}, .start = 0, .end = 56 },
        .{ .edges = &.{.right}, .start = 0, .end = 92 },
        .{ .edges = &.{.left}, .start = -36, .end = 56 },
        .{ .edges = &.{ .left, .top }, .start = -92, .end = 56 },
        .{ .edges = &.{ .right, .top }, .start = 0, .end = 148 },
        .{ .edges = &all_round, .start = -92, .end = 92 },
    };
    for (cases) |case| {
        const t = testTrack(case.edges, test_field);
        try testing.expectEqual(case.start, t.start());
        try testing.expectEqual(case.end, t.end());
        var it = t.edges.iterator();
        while (it.next()) |edge| {
            const length = if (edge.surface() == .wall) t.wall else t.floor;
            var along: f32 = 0;
            while (along <= length) : (along += 0.5) {
                const p = t.position(edge, along);
                try testing.expect(p >= t.start() and p <= t.end());
                const spot = t.locate(p);
                if (spot.edge == edge) {
                    try testing.expectEqual(along, spot.along);
                } else {
                    // Only the ends of the walls, which are corners, go
                    // to another edge: the bottom or the ceiling.
                    try testing.expect(edge.surface() == .wall);
                    try testing.expect(along == 0 or along == length);
                    try testing.expect(spot.edge == .bottom or spot.edge == .top);
                    try testing.expectEqual(t.wrap(p), t.position(spot.edge, spot.along));
                }
            }
        }
    }

    // Along the bottom a position is the sprite's x, exactly, even off
    // screen.
    const bottom = testTrack(&.{}, test_field);
    for ([_]f32{ -7.25, 0, 0.1, 31.7, 56, 70.5 }) |p| {
        try testing.expectEqual(Spot{ .edge = .bottom, .along = p }, bottom.locate(p));
    }

    // Corners belong to the bottom and the ceiling.
    const all = testTrack(&all_round, test_field);
    try testing.expectEqual(Spot{ .edge = .bottom, .along = 0 }, all.locate(0));
    try testing.expectEqual(Spot{ .edge = .bottom, .along = 56 }, all.locate(56));
    try testing.expectEqual(Spot{ .edge = .top, .along = 0 }, all.locate(-36));
    try testing.expectEqual(Spot{ .edge = .top, .along = 56 }, all.locate(92));
    try testing.expectEqual(Spot{ .edge = .top, .along = 56 }, all.locate(-92));
    try testing.expectEqual(Spot{ .edge = .right, .along = 35 }, all.locate(57));
    try testing.expectEqual(Spot{ .edge = .right, .along = 1 }, all.locate(91));
    try testing.expectEqual(Spot{ .edge = .left, .along = 35 }, all.locate(-1));
    try testing.expectEqual(Spot{ .edge = .left, .along = 1 }, all.locate(-35));
    try testing.expectEqual(Spot{ .edge = .top, .along = 1 }, all.locate(-37));
    const right_top = testTrack(&.{ .right, .top }, test_field);
    try testing.expectEqual(Spot{ .edge = .top, .along = 56 }, right_top.locate(92));
    try testing.expectEqual(Spot{ .edge = .top, .along = 0 }, right_top.locate(148));

    // Past an open end a position lies on that end's edge, off screen.
    const left_top = testTrack(&.{ .left, .top }, test_field);
    try testing.expectEqual(Spot{ .edge = .top, .along = 60 }, left_top.locate(-96));
    try testing.expectEqual(Spot{ .edge = .bottom, .along = 60 }, left_top.locate(60));
    const right = testTrack(&.{.right}, test_field);
    try testing.expectEqual(Spot{ .edge = .right, .along = -4 }, right.locate(96));
    try testing.expectEqual(Spot{ .edge = .bottom, .along = -4 }, right.locate(-4));
    const left = testTrack(&.{.left}, test_field);
    try testing.expectEqual(Spot{ .edge = .left, .along = -4 }, left.locate(-40));

    // A ceiling with no wall up to it is not on the track.
    const top = testTrack(&.{.top}, test_field);
    try testing.expectEqual(0, top.start());
    try testing.expectEqual(56, top.end());
    try testing.expectEqual(Spot{ .edge = .bottom, .along = 70 }, top.locate(70));
}

test "a loop wraps around" {
    const t = testTrack(&all_round, test_field);
    try testing.expect(t.loops());
    try testing.expectEqual(-92, t.wrap(92));
    try testing.expectEqual(-91.5, t.wrap(92.5));
    try testing.expectEqual(91.5, t.wrap(-92.5));
    try testing.expectEqual(10, t.wrap(10 + 3 * 184));
    try testing.expectEqual(10, t.wrap(10 - 2 * 184));
    var p: f32 = -92;
    while (p < 92) : (p += 0.75) {
        try testing.expectEqual(p, t.wrap(p));
        try testing.expectEqual(t.locate(p), t.locate(p + 184));
        try testing.expectEqual(t.locate(p), t.locate(p - 184));
    }

    // Open tracks do not wrap.
    for ([_][]const Edge{ &.{}, &.{.right}, &.{ .left, .top }, &.{ .left, .right }, &.{ .right, .top } }) |edges| {
        const open = testTrack(edges, test_field);
        try testing.expect(!open.loops());
        try testing.expectEqual(500, open.wrap(500));
        try testing.expectEqual(-500, open.wrap(-500));
    }
}

test "corners ahead" {
    const bottom = testTrack(&.{}, test_field);
    for ([_]f32{ -20, 0, 10, 56, 80 }) |p| {
        try testing.expectEqual(null, bottom.cornerAhead(p, .forward));
        try testing.expectEqual(null, bottom.cornerAhead(p, .backward));
    }

    const right = testTrack(&.{.right}, test_field);
    try testing.expectEqual(46, right.cornerAhead(10, .forward).?);
    try testing.expectEqual(null, right.cornerAhead(10, .backward));
    try testing.expectEqual(10, right.cornerAhead(66, .backward).?);
    try testing.expectEqual(null, right.cornerAhead(66, .forward));

    // Up the left wall onto the ceiling, open at both ends.
    const open = testTrack(&.{ .left, .top }, test_field);
    try testing.expectEqual(10, open.cornerAhead(10, .backward).?);
    try testing.expectEqual(null, open.cornerAhead(10, .forward));
    try testing.expectEqual(0, open.cornerAhead(0, .forward).?);
    try testing.expectEqual(0, open.cornerAhead(0, .backward).?);
    try testing.expectEqual(5, open.cornerAhead(-5, .forward).?);
    try testing.expectEqual(31, open.cornerAhead(-5, .backward).?);
    try testing.expectEqual(4, open.cornerAhead(-40, .forward).?);
    try testing.expectEqual(null, open.cornerAhead(-40, .backward));
    try testing.expectEqual(64, open.cornerAhead(-100, .forward).?);

    const loop = testTrack(&all_round, test_field);
    try testing.expectEqual(46, loop.cornerAhead(10, .forward).?);
    try testing.expectEqual(10, loop.cornerAhead(10, .backward).?);
    try testing.expectEqual(10, loop.cornerAhead(82, .forward).?);
    try testing.expectEqual(20, loop.cornerAhead(-56, .forward).?);
    try testing.expectEqual(36, loop.cornerAhead(-56, .backward).?);
    try testing.expectEqual(0, loop.cornerAhead(56, .forward).?);
    try testing.expectEqual(0, loop.cornerAhead(-36, .backward).?);
    // Across the seam at the top-right corner.
    try testing.expectEqual(2, loop.cornerAhead(90, .forward).?);
    try testing.expectEqual(2, loop.cornerAhead(-90, .backward).?);
    try testing.expectEqual(0, loop.cornerAhead(92, .forward).?);
    try testing.expectEqual(0, loop.cornerAhead(92, .backward).?);
    try testing.expectEqual(10, loop.cornerAhead(10 + 184, .backward).?);
}

test "carry keeps the spot on its edge" {
    const wide: Field = .{ .width = 80, .height = 40 };
    const small: Field = .{ .width = 30, .height = 20 };

    // Along the bottom alone it changes nothing, even past the end.
    const bottom = testTrack(&.{}, test_field);
    const narrow_bottom = testTrack(&.{}, small);
    for ([_]f32{ -10, 0, 12.5, 26, 45.25, 56, 70 }) |p| {
        try testing.expectEqual(p, narrow_bottom.carry(bottom, p));
        try testing.expectEqual(p, bottom.carry(narrow_bottom, p));
    }

    // A wider screen keeps the height on a wall, and the spot on the
    // ceiling.
    const loop = testTrack(&all_round, test_field);
    const wide_loop = testTrack(&all_round, wide);
    try testing.expectEqual(Spot{ .edge = .right, .along = 10 }, wide_loop.locate(wide_loop.carry(loop, loop.position(.right, 10))));
    try testing.expectEqual(Spot{ .edge = .left, .along = 10 }, wide_loop.locate(wide_loop.carry(loop, loop.position(.left, 10))));
    try testing.expectEqual(Spot{ .edge = .top, .along = 20 }, wide_loop.locate(wide_loop.carry(loop, loop.position(.top, 20))));
    try testing.expectEqual(Spot{ .edge = .bottom, .along = 30 }, wide_loop.locate(wide_loop.carry(loop, 30)));
    try testing.expectEqual(Spot{ .edge = .right, .along = 10 }, loop.locate(loop.carry(wide_loop, wide_loop.position(.right, 10))));

    // A smaller one pulls spots back from the corners it moved in past.
    const small_loop = testTrack(&all_round, small);
    try testing.expectEqual(Spot{ .edge = .bottom, .along = 26 }, small_loop.locate(small_loop.carry(loop, 45)));
    try testing.expectEqual(Spot{ .edge = .right, .along = 10 }, small_loop.locate(small_loop.carry(loop, loop.position(.right, 10))));
    try testing.expectEqual(Spot{ .edge = .right, .along = 15 }, small_loop.locate(small_loop.carry(loop, loop.position(.right, 15))));
    try testing.expectEqual(small_loop.position(.right, 16), small_loop.carry(loop, loop.position(.right, 30)));
    try testing.expectEqual(small_loop.position(.left, 16), small_loop.carry(loop, loop.position(.left, 30)));
    try testing.expectEqual(Spot{ .edge = .top, .along = 26 }, small_loop.locate(small_loop.carry(loop, loop.position(.top, 50))));

    // Open ends are left alone, so what is past one stays there.
    const left_top = testTrack(&.{ .left, .top }, test_field);
    const narrow_left_top = testTrack(&.{ .left, .top }, .{ .width = 30, .height = 40 });
    try testing.expectEqual(45, narrow_left_top.carry(left_top, 45));
    try testing.expectEqual(Spot{ .edge = .top, .along = 50 }, narrow_left_top.locate(narrow_left_top.carry(left_top, left_top.position(.top, 50))));
    const right = testTrack(&.{.right}, test_field);
    const short_right = testTrack(&.{.right}, .{ .width = 60, .height = 20 });
    try testing.expectEqual(Spot{ .edge = .right, .along = -5 }, short_right.locate(short_right.carry(right, right.position(.right, -5))));
    try testing.expectEqual(Spot{ .edge = .right, .along = 10 }, short_right.locate(short_right.carry(right, right.position(.right, 10))));
    try testing.expectEqual(short_right.position(.right, 16), short_right.carry(right, right.position(.right, 30)));
    try testing.expectEqual(-8, short_right.carry(right, -8));
}

test "tracks on screens no bigger than the rambler" {
    // No room to walk: every edge has length 0, and the loop with it.
    const tiny = testTrack(&all_round, .{ .width = 3, .height = 4 });
    try testing.expectEqual(0, tiny.floor);
    try testing.expectEqual(0, tiny.wall);
    try testing.expect(!tiny.loops());
    try testing.expectEqual(0, tiny.start());
    try testing.expectEqual(0, tiny.end());
    try testing.expectEqual(7, tiny.wrap(7));
    try testing.expectEqual(Spot{ .edge = .bottom, .along = 0 }, tiny.locate(0));
    try testing.expectEqual(0, tiny.cornerAhead(0, .forward).?);
    try testing.expectEqual(0, tiny.carry(testTrack(&all_round, test_field), 30));

    // Walls of length 0: still a loop, round the floor and the ceiling.
    const flat = testTrack(&all_round, .{ .width = 60, .height = 2 });
    try testing.expect(flat.loops());
    try testing.expectEqual(-56, flat.start());
    try testing.expectEqual(56, flat.end());
    try testing.expectEqual(Spot{ .edge = .top, .along = 1 }, flat.locate(-1));
    try testing.expectEqual(Spot{ .edge = .top, .along = 55 }, flat.locate(57));
    try testing.expectEqual(1, flat.cornerAhead(-1, .forward).?);
    try testing.expectEqual(10, flat.wrap(10 + 112));
    for ([_]f32{ -60, -1, 0, 30, 56, 70 }) |p| {
        const along = flat.locate(p).along;
        try testing.expect(!std.math.isNan(along) and along >= 0 and along <= 56);
    }
}
