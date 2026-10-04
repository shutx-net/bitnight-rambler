//! Waits for file descriptors to become readable or writable.
//!
//! Uses poll(2), except on macOS, whose poll does not work with terminal
//! devices (it reports them as invalid), so select(2) is used there instead.
//! A signal interrupts the wait and returns with nothing ready, so that the
//! caller notices flags set by signal handlers straight away.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const is_darwin = builtin.os.tag.isDarwin();

/// Most interests a single `wait` accepts.
pub const max_interests = 4;

pub const Interest = struct {
    fd: posix.fd_t,
    read: bool = false,
    write: bool = false,
};

pub const Ready = struct {
    read: bool = false,
    write: bool = false,
};

/// Waits until one of `interests` is ready, `timeout_ms` passes (-1 waits
/// indefinitely) or a signal arrives. `ready[i]` is set for `interests[i]`.
/// End of file, a hang-up and errors count as readable: the caller finds
/// out what happened by reading.
pub fn wait(interests: []const Interest, ready: []Ready, timeout_ms: i32) error{Unexpected}!void {
    std.debug.assert(interests.len <= max_interests);
    std.debug.assert(ready.len >= interests.len);
    for (ready[0..interests.len]) |*r| r.* = .{};
    if (is_darwin) return waitSelect(interests, ready, timeout_ms);
    return waitPoll(interests, ready, timeout_ms);
}

fn waitPoll(interests: []const Interest, ready: []Ready, timeout_ms: i32) error{Unexpected}!void {
    const read_events = posix.POLL.IN | posix.POLL.HUP | posix.POLL.ERR | posix.POLL.NVAL;
    const write_events = posix.POLL.OUT | posix.POLL.ERR;
    var fds: [max_interests]posix.pollfd = undefined;
    for (interests, fds[0..interests.len]) |interest, *pfd| {
        pfd.* = .{ .fd = interest.fd, .events = 0, .revents = 0 };
        if (interest.read) pfd.events |= posix.POLL.IN;
        if (interest.write) pfd.events |= posix.POLL.OUT;
    }
    const rc = posix.system.poll(&fds, @intCast(interests.len), timeout_ms);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .INTR, .AGAIN => return,
        else => return error.Unexpected,
    }
    for (interests, fds[0..interests.len], ready[0..interests.len]) |interest, pfd, *r| {
        r.read = interest.read and pfd.revents & read_events != 0;
        r.write = interest.write and pfd.revents & write_events != 0;
    }
}

const darwin = struct {
    /// Room for descriptors below FD_SETSIZE, 1024.
    const fd_set = extern struct { bits: [32]i32 = @splat(0) };
    extern "c" fn select(nfds: c_int, r: ?*fd_set, w: ?*fd_set, e: ?*fd_set, timeout: ?*posix.timeval) c_int;

    fn bit(fd: posix.fd_t) i32 {
        const i: u32 = @intCast(fd);
        return @bitCast(@as(u32, 1) << @intCast(i % 32));
    }

    fn set(s: *fd_set, fd: posix.fd_t) void {
        s.bits[@as(usize, @intCast(fd)) / 32] |= bit(fd);
    }

    fn isSet(s: *const fd_set, fd: posix.fd_t) bool {
        return s.bits[@as(usize, @intCast(fd)) / 32] & bit(fd) != 0;
    }
};

fn waitSelect(interests: []const Interest, ready: []Ready, timeout_ms: i32) error{Unexpected}!void {
    var readable: darwin.fd_set = .{};
    var writable: darwin.fd_set = .{};
    var nfds: posix.fd_t = 0;
    for (interests) |interest| {
        std.debug.assert(interest.fd >= 0 and interest.fd < 1024);
        if (interest.read) darwin.set(&readable, interest.fd);
        if (interest.write) darwin.set(&writable, interest.fd);
        nfds = @max(nfds, interest.fd + 1);
    }
    var tv: posix.timeval = .{
        .sec = @intCast(@divTrunc(@max(timeout_ms, 0), 1000)),
        .usec = @intCast(@mod(@max(timeout_ms, 0), 1000) * 1000),
    };
    const rc = darwin.select(nfds, &readable, &writable, null, if (timeout_ms < 0) null else &tv);
    switch (posix.errno(rc)) {
        .SUCCESS => {},
        .INTR, .AGAIN => return,
        else => return error.Unexpected,
    }
    for (interests, ready[0..interests.len]) |interest, *r| {
        r.read = interest.read and darwin.isSet(&readable, interest.fd);
        r.write = interest.write and darwin.isSet(&writable, interest.fd);
    }
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

test "an empty pipe times out" {
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer for (fds) |fd| closeFd(fd);
    var ready: [1]Ready = undefined;
    try wait(&.{.{ .fd = fds[0], .read = true }}, &ready, 10);
    try std.testing.expectEqual(Ready{}, ready[0]);
}

test "a pipe with data is readable, and its write end writable" {
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer for (fds) |fd| closeFd(fd);
    try std.testing.expectEqual(1, posix.system.write(fds[1], "x", 1));
    var ready: [2]Ready = undefined;
    try wait(&.{ .{ .fd = fds[0], .read = true }, .{ .fd = fds[1], .write = true } }, &ready, 1000);
    try std.testing.expectEqual(Ready{ .read = true }, ready[0]);
    try std.testing.expectEqual(Ready{ .write = true }, ready[1]);
}

test "a pipe whose write end is closed is readable" {
    const fds = try std.Io.Threaded.pipe2(.{ .CLOEXEC = true });
    defer closeFd(fds[0]);
    closeFd(fds[1]);
    var ready: [1]Ready = undefined;
    try wait(&.{.{ .fd = fds[0], .read = true }}, &ready, 1000);
    try std.testing.expect(ready[0].read);
}
