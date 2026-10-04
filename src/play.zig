//! The animation loop: advance the actor in fixed time steps, draw it into
//! the canvas, and write whatever changed to the terminal.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Actor = @import("Actor.zig");
const Canvas = @import("Canvas.zig");
const Rambler = @import("Rambler.zig");
const Screen = @import("Screen.zig");
const Terminal = @import("Terminal.zig");
const color = @import("color.zig");

pub const Options = struct {
    mode: Actor.Mode = .roam,
    seed: u64,
    color_mode: color.Mode,
};

/// About 30 frames per second.
const tick_us = 33_333;
/// After a stall, such as the process being suspended, skip ahead instead
/// of fast-forwarding through everything that was missed.
const max_catch_up_ticks = 10;

pub fn play(gpa: Allocator, io: Io, rambler: *const Rambler, options: Options) !void {
    var out_buffer: [64 * 1024]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &out_buffer);
    const out = &stdout_writer.interface;

    var terminal: Terminal = try .enter(io, out);
    defer terminal.leave(out);

    var size = Terminal.size(io);
    var canvas: Canvas = try .init(gpa, size.cols, 2 * size.rows);
    defer canvas.deinit(gpa);
    var screen: Screen = try .init(gpa, size.cols, size.rows, options.color_mode);
    defer screen.deinit(gpa);
    var actor: Actor = .init(rambler, options.mode, options.seed, .{ .width = canvas.width, .height = canvas.height });

    const tick: Io.Duration = .fromMicroseconds(tick_us);
    var next_tick = Io.Clock.awake.now(io);
    while (!actor.done and !Terminal.interrupted.load(.acquire)) {
        if (Terminal.resized.swap(false, .acq_rel)) {
            size = Terminal.size(io);
            try canvas.resize(gpa, size.cols, 2 * size.rows);
            try screen.resize(gpa, size.cols, size.rows);
            try out.writeAll(Terminal.clear_sequence);
            actor.resize(.{ .width = canvas.width, .height = canvas.height });
        }

        const now = Io.Clock.awake.now(io);
        var ticks: u32 = 0;
        while (next_tick.nanoseconds <= now.nanoseconds) : (ticks += 1) {
            if (ticks == max_catch_up_ticks) {
                next_tick = now;
                break;
            }
            actor.update(tick_us);
            next_tick = next_tick.addDuration(tick);
        }

        const frame = actor.frame();
        canvas.clear();
        canvas.drawSprite(frame.sprite, &rambler.palette, frame.x, frame.y, frame.flip);
        screen.compose(&canvas);
        try screen.flush(out);
        try out.flush();

        const wait = now.durationTo(next_tick).toMilliseconds();
        if (terminal.waitForKey(@intCast(std.math.clamp(wait, 1, 1000))) == .quit) break;
    }
}
