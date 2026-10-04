//! A pseudo-terminal with a child process on its other end, for rambit
//! shell. The child runs as a session leader with the pty as its
//! controlling terminal, the way a terminal emulator starts a shell, so job
//! control, Ctrl-C and SIGWINCH work inside it.
//!
//! std.process.spawn cannot start a new session or set a controlling
//! terminal, so the fork and exec are done here; the error pipe and the PATH
//! search follow std.Io.Threaded's spawn. Linux needs no libc: /dev/ptmx is
//! driven with ioctls. macOS always links libSystem, which provides
//! posix_openpt and friends.

const Pty = @This();

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;
const poll = @import("poll.zig");

const is_darwin = builtin.os.tag.isDarwin();

/// The pty's master side, nonblocking; -1 once closed.
master: posix.fd_t,
/// The child process.
pid: posix.pid_t,
/// Set once the child has been waited for, after which its pid may belong
/// to another process.
reaped: ?Status = null,

pub const Size = struct { cols: u16, rows: u16 };

pub const SpawnOptions = struct {
    /// The program and its arguments. A program without a slash is looked
    /// up in the PATH of `environ`.
    argv: []const []const u8,
    environ: *const std.process.Environ.Map,
    size: Size,
    /// Terminal settings for the pty, typically the user's own, so that
    /// things like the erase key and IUTF8 carry over.
    termios: ?posix.termios = null,
};

pub const SpawnError = error{
    /// No pseudo-terminals here, as in some sandboxes.
    PtyUnavailable,
    FileNotFound,
    AccessDenied,
    ExecFailed,
    SystemResources,
    OutOfMemory,
};

pub const ReadResult = union(enum) {
    data: usize,
    /// Nothing to read yet.
    would_block,
    /// The child side is gone: every process holding the pty has exited.
    closed,
};

pub const Status = union(enum) {
    exited: u8,
    signaled: u8,

    /// The exit code a shell would report: 128 plus the signal's number for
    /// a process killed by a signal.
    pub fn exitCode(s: Status) u8 {
        return switch (s) {
            .exited => |code| code,
            .signaled => |sig| 128 +| sig,
        };
    }
};

const tiocsctty: u32 = if (is_darwin) 0x20007461 else posix.T.IOCSCTTY;
// std.c.T only has IOCGWINSZ for Darwin.
const tiocswinsz: u32 = if (is_darwin) 0x80087467 else posix.T.IOCSWINSZ;

const default_path = "/usr/local/bin:/usr/bin:/bin";

const darwin = struct {
    extern "c" fn posix_openpt(oflag: c_int) c_int;
    extern "c" fn grantpt(fd: c_int) c_int;
    extern "c" fn unlockpt(fd: c_int) c_int;
    extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;
};

/// What the child reports through the error pipe when it cannot exec.
const ChildFailure = extern struct {
    stage: enum(u32) { controlling_terminal, exec },
    errno: u32,
};

fn ioctl(fd: posix.fd_t, code: u32, arg: usize) posix.E {
    return posix.errno(posix.system.ioctl(fd, @bitCast(code), arg));
}

fn closeFd(fd: posix.fd_t) void {
    _ = posix.system.close(fd);
}

/// Starts `options.argv` on a new pty. Allocates from `arena` before
/// forking; nothing is allocated in the child.
pub fn spawn(arena: Allocator, io: Io, options: SpawnOptions) SpawnError!Pty {
    std.debug.assert(options.argv.len > 0);
    var path_buf: [128]u8 = undefined;
    const master = try openMaster(io, &path_buf);
    errdefer closeFd(master);
    setNonblocking(master) catch return error.PtyUnavailable;
    setSize(master, options.size);

    const slave_path = std.mem.sliceTo(&path_buf, 0);
    const slave = Io.Dir.openFileAbsolute(io, slave_path, .{ .mode = .read_write }) catch
        return error.PtyUnavailable;
    defer slave.close(io);
    if (options.termios) |termios| posix.tcsetattr(slave.handle, .NOW, termios) catch {};

    const argv = try arena.allocSentinel(?[*:0]const u8, options.argv.len, null);
    for (options.argv, argv) |arg, *dest| dest.* = (try arena.dupeZ(u8, arg)).ptr;
    const envp = try options.environ.createPosixBlock(arena, .{});
    const candidates = try execCandidates(arena, options.argv[0], options.environ.get("PATH") orelse default_path);

    const err_pipe = Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return error.SystemResources;
    defer closeFd(err_pipe[0]);

    const rc = posix.system.fork();
    if (posix.errno(rc) != .SUCCESS) {
        closeFd(err_pipe[1]);
        return error.SystemResources;
    }
    if (rc == 0) execChild(slave.handle, err_pipe[1], argv.ptr, envp.slice.ptr, candidates);

    const pid: posix.pid_t = @intCast(rc);
    closeFd(err_pipe[1]);
    var failure: ChildFailure = undefined;
    const len = readFull(err_pipe[0], std.mem.asBytes(&failure));
    if (len < @sizeOf(ChildFailure)) return .{ .master = master, .pid = pid };

    var p: Pty = .{ .master = master, .pid = pid };
    _ = p.wait();
    return switch (failure.stage) {
        .controlling_terminal => error.PtyUnavailable,
        .exec => switch (@as(posix.E, @enumFromInt(failure.errno))) {
            .NOENT, .NOTDIR => error.FileNotFound,
            .ACCES, .PERM => error.AccessDenied,
            .NOMEM, .AGAIN => error.SystemResources,
            else => error.ExecFailed,
        },
    };
}

/// Opens a pty's master side and writes the path of its slave side to
/// `path_buf`, null-terminated.
fn openMaster(io: Io, path_buf: *[128]u8) error{PtyUnavailable}!posix.fd_t {
    if (is_darwin) {
        const flags: posix.O = .{ .ACCMODE = .RDWR, .NOCTTY = true };
        const fd = darwin.posix_openpt(@bitCast(flags));
        if (fd < 0) return error.PtyUnavailable;
        errdefer closeFd(fd);
        if (darwin.grantpt(fd) != 0 or darwin.unlockpt(fd) != 0 or
            darwin.ptsname_r(fd, path_buf, path_buf.len) != 0)
            return error.PtyUnavailable;
        if (posix.errno(posix.system.fcntl(fd, posix.F.SETFD, @as(usize, posix.FD_CLOEXEC))) != .SUCCESS)
            return error.PtyUnavailable;
        return fd;
    }
    // Opened with O_CLOEXEC and O_NOCTTY.
    const file = Io.Dir.openFileAbsolute(io, "/dev/ptmx", .{ .mode = .read_write }) catch
        return error.PtyUnavailable;
    errdefer file.close(io);
    var unlock: c_int = 0;
    if (ioctl(file.handle, posix.T.IOCSPTLCK, @intFromPtr(&unlock)) != .SUCCESS) return error.PtyUnavailable;
    var number: c_uint = 0;
    if (ioctl(file.handle, posix.T.IOCGPTN, @intFromPtr(&number)) != .SUCCESS) return error.PtyUnavailable;
    _ = std.fmt.bufPrintSentinel(path_buf, "/dev/pts/{d}", .{number}, 0) catch return error.PtyUnavailable;
    return file.handle;
}

fn setNonblocking(fd: posix.fd_t) error{Unexpected}!void {
    const rc = posix.system.fcntl(fd, posix.F.GETFL, @as(usize, 0));
    if (posix.errno(rc) != .SUCCESS) return error.Unexpected;
    var flags: posix.O = @bitCast(@as(u32, @intCast(rc)));
    flags.NONBLOCK = true;
    const arg: usize = @as(u32, @bitCast(flags));
    if (posix.errno(posix.system.fcntl(fd, posix.F.SETFL, arg)) != .SUCCESS) return error.Unexpected;
}

fn setSize(fd: posix.fd_t, size: Size) void {
    var ws: posix.winsize = .{ .row = size.rows, .col = size.cols, .xpixel = 0, .ypixel = 0 };
    _ = ioctl(fd, tiocswinsz, @intFromPtr(&ws));
}

/// The paths to try executing for `program`: itself when it contains a
/// slash, otherwise the program in each directory of `path`, where an empty
/// entry means the current directory.
fn execCandidates(arena: Allocator, program: []const u8, path: []const u8) Allocator.Error![]const [*:0]const u8 {
    if (std.mem.findScalar(u8, program, '/') != null) {
        const only = try arena.alloc([*:0]const u8, 1);
        only[0] = (try arena.dupeZ(u8, program)).ptr;
        return only;
    }
    var list: std.ArrayList([*:0]const u8) = .empty;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        const full = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ if (dir.len == 0) "." else dir, program }, 0);
        try list.append(arena, full.ptr);
    }
    return list.items;
}

/// Signals whose disposition is put back to the default in the child, in
/// case rambit itself was started with them ignored.
const reset_signals = [_]posix.SIG{ .HUP, .INT, .QUIT, .PIPE, .TERM, .TSTP, .TTIN, .TTOU };

/// Runs in the forked child: only system calls, no allocation and no Io.
fn execChild(
    slave: posix.fd_t,
    err_fd: posix.fd_t,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    candidates: []const [*:0]const u8,
) noreturn {
    const default_action: posix.Sigaction = .{
        .handler = .{ .handler = posix.SIG.DFL },
        .mask = posix.sigemptyset(),
        .flags = 0,
    };
    for (reset_signals) |sig| posix.sigaction(sig, &default_action, null);
    const no_signals = posix.sigemptyset();
    posix.sigprocmask(posix.SIG.SETMASK, &no_signals, null);

    _ = posix.system.setsid();
    const ctty = ioctl(slave, tiocsctty, 0);
    if (ctty != .SUCCESS) childFail(err_fd, .controlling_terminal, ctty);
    // dup2 clears FD_CLOEXEC on the copies, but leaves the descriptor alone
    // when it is copied onto itself.
    if (slave <= 2) _ = posix.system.fcntl(slave, posix.F.SETFD, @as(usize, 0));
    for ([_]posix.fd_t{ 0, 1, 2 }) |fd| _ = posix.system.dup2(slave, fd);

    var seen_access_denied = false;
    var last: posix.E = .NOENT;
    for (candidates) |path| {
        last = posix.errno(posix.system.execve(path, argv, envp));
        switch (last) {
            .NOENT, .NOTDIR => {},
            .ACCES => seen_access_denied = true,
            else => break,
        }
    } else if (seen_access_denied) last = .ACCES;
    childFail(err_fd, .exec, last);
}

fn childFail(err_fd: posix.fd_t, stage: @FieldType(ChildFailure, "stage"), err: posix.E) noreturn {
    const failure: ChildFailure = .{ .stage = stage, .errno = @intFromEnum(err) };
    _ = posix.system.write(err_fd, std.mem.asBytes(&failure), @sizeOf(ChildFailure));
    if (builtin.link_libc) std.c._exit(127);
    std.os.linux.exit_group(127);
}

/// Reads until `buf` is full or end of file, returning the length read.
fn readFull(fd: posix.fd_t, buf: []u8) usize {
    var len: usize = 0;
    while (len < buf.len) {
        const rc = posix.system.read(fd, buf[len..].ptr, buf.len - len);
        switch (posix.errno(rc)) {
            .SUCCESS => if (rc == 0) break else {
                len += @intCast(rc);
            },
            .INTR => {},
            else => break,
        }
    }
    return len;
}

/// Reads what the child has written. `buf` must not be empty.
pub fn read(p: Pty, buf: []u8) ReadResult {
    std.debug.assert(buf.len > 0);
    if (p.master < 0) return .closed;
    const len = posix.read(p.master, buf) catch |err| return switch (err) {
        error.WouldBlock => .would_block,
        // Linux reports EIO once the last descriptor of the slave closes.
        else => .closed,
    };
    if (len == 0) return .closed;
    return .{ .data = len };
}

/// Writes as much of `bytes` as the pty takes without blocking, which may
/// be nothing.
pub fn write(p: Pty, bytes: []const u8) error{Closed}!usize {
    if (p.master < 0) return error.Closed;
    while (true) {
        const rc = posix.system.write(p.master, bytes.ptr, bytes.len);
        switch (posix.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => {},
            .AGAIN => return 0,
            else => return error.Closed,
        }
    }
}

/// Changes the pty's size; the kernel sends SIGWINCH to the foreground job.
pub fn resize(p: Pty, size: Size) void {
    if (p.master >= 0) setSize(p.master, size);
}

/// The child's status if it has exited, without blocking.
pub fn tryWait(p: *Pty) ?Status {
    return p.reap(true);
}

/// Waits for the child to exit.
pub fn wait(p: *Pty) Status {
    // Only fails when the child cannot be waited for at all, which does not
    // happen for a child of this process; report a failure regardless.
    return p.reap(false) orelse .{ .exited = 1 };
}

const WaitStatus = if (builtin.link_libc) c_int else u32;

fn reap(p: *Pty, comptime nohang: bool) ?Status {
    if (p.reaped) |status| return status;
    var raw: WaitStatus = 0;
    while (true) {
        const rc = posix.system.waitpid(p.pid, &raw, if (nohang) posix.W.NOHANG else 0);
        switch (posix.errno(rc)) {
            .SUCCESS => if (rc == 0) return null else break,
            .INTR => {},
            else => return null,
        }
    }
    const bits: u32 = @bitCast(raw);
    const status: Status = if (posix.W.IFEXITED(bits))
        .{ .exited = posix.W.EXITSTATUS(bits) }
    else if (posix.W.IFSIGNALED(bits))
        .{ .signaled = @intCast(@intFromEnum(posix.W.TERMSIG(bits))) }
    else
        return null;
    p.reaped = status;
    return status;
}

/// Hangs up: closes the master side, which makes the kernel send SIGHUP to
/// the session, and sends SIGHUP to the child as well in case it has left
/// the session.
pub fn hangUp(p: *Pty) void {
    p.close();
    if (p.reaped == null) _ = posix.system.kill(p.pid, .HUP);
}

/// Closes the master side. The child is not waited for.
pub fn close(p: *Pty) void {
    if (p.master < 0) return;
    closeFd(p.master);
    p.master = -1;
}

const testing = std.testing;

/// Spawns `argv` for a test, skipping it where there are no ptys or no
/// /bin/sh, as in the Nix build sandbox.
fn testSpawn(arena: Allocator, argv: []const []const u8, environ: *const std.process.Environ.Map) !Pty {
    return spawn(arena, testing.io, .{
        .argv = argv,
        .environ = environ,
        .size = .{ .cols = 80, .rows = 24 },
    }) catch |err| switch (err) {
        error.PtyUnavailable => error.SkipZigTest,
        error.FileNotFound => if (std.mem.eql(u8, argv[0], "/bin/sh") or std.mem.eql(u8, argv[0], "sh"))
            error.SkipZigTest
        else
            err,
        else => err,
    };
}

/// Collects the child's output until the pty closes, failing after about
/// five seconds.
fn readAll(p: *Pty, buf: []u8) ![]const u8 {
    var len: usize = 0;
    var waits: usize = 0;
    while (true) {
        switch (p.read(buf[len..])) {
            .data => |n| len += n,
            .closed => return buf[0..len],
            .would_block => {
                if (waits == 50) return error.Timeout;
                waits += 1;
                var ready: [1]poll.Ready = undefined;
                try poll.wait(&.{.{ .fd = p.master, .read = true }}, &ready, 100);
            },
        }
        if (len == buf.len) return error.NoSpaceLeft;
    }
}

test "runs a command and reports its exit status" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var environ: std.process.Environ.Map = .init(arena_state.allocator());
    var p = try testSpawn(arena_state.allocator(), &.{ "/bin/sh", "-c", "printf hello; exit 3" }, &environ);
    defer p.close();
    var buf: [4096]u8 = undefined;
    const output = try readAll(&p, &buf);
    try testing.expect(std.mem.indexOf(u8, output, "hello") != null);
    try testing.expectEqual(Status{ .exited = 3 }, p.wait());
    try testing.expectEqual(Status{ .exited = 3 }, p.tryWait().?);
}

test "looks programs up in PATH and passes the environment" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var environ: std.process.Environ.Map = .init(arena_state.allocator());
    try environ.put("PATH", "/usr/bin:/bin");
    try environ.put("RAMBIT_TEST", "ok");
    var p = try testSpawn(arena_state.allocator(), &.{ "sh", "-c", "printf %s \"$RAMBIT_TEST\"" }, &environ);
    defer p.close();
    var buf: [4096]u8 = undefined;
    try testing.expectEqualStrings("ok", try readAll(&p, &buf));
    try testing.expectEqual(Status{ .exited = 0 }, p.wait());
}

test resize {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var environ: std.process.Environ.Map = .init(arena_state.allocator());
    var p = try testSpawn(arena_state.allocator(), &.{ "/bin/sh", "-c", "read x" }, &environ);
    defer p.close();
    p.resize(.{ .cols = 100, .rows = 30 });
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    try testing.expectEqual(.SUCCESS, ioctl(p.master, posix.T.IOCGWINSZ, @intFromPtr(&ws)));
    try testing.expectEqual(100, ws.col);
    try testing.expectEqual(30, ws.row);
    try testing.expectEqual(1, try p.write("\n"));
    var buf: [4096]u8 = undefined;
    _ = try readAll(&p, &buf);
    try testing.expectEqual(Status{ .exited = 0 }, p.wait());
}

test "reports a missing program" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var environ: std.process.Environ.Map = .init(arena);
    try environ.put("PATH", "/bin");
    try expectSpawnError(error.FileNotFound, arena, &.{"/nonexistent/rambit-test"}, &environ);
    try expectSpawnError(error.FileNotFound, arena, &.{"rambit-no-such-command"}, &environ);
}

fn expectSpawnError(
    expected: SpawnError,
    arena: Allocator,
    argv: []const []const u8,
    environ: *const std.process.Environ.Map,
) !void {
    if (testSpawn(arena, argv, environ)) |spawned| {
        var p = spawned;
        p.hangUp();
        _ = p.wait();
        return error.TestUnexpectedResult;
    } else |err| {
        if (err == error.SkipZigTest) return err;
        try testing.expectEqual(expected, err);
    }
}

test "reports death by a signal" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var environ: std.process.Environ.Map = .init(arena_state.allocator());
    var p = try testSpawn(arena_state.allocator(), &.{ "/bin/sh", "-c", "kill -TERM $$" }, &environ);
    defer p.close();
    var buf: [4096]u8 = undefined;
    _ = try readAll(&p, &buf);
    const status = p.wait();
    try testing.expectEqual(Status{ .signaled = 15 }, status);
    try testing.expectEqual(143, status.exitCode());
}

test "hangs up" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    var environ: std.process.Environ.Map = .init(arena_state.allocator());
    var p = try testSpawn(arena_state.allocator(), &.{ "/bin/sh", "-c", "read x" }, &environ);
    p.hangUp();
    var buf: [16]u8 = undefined;
    try testing.expectEqual(ReadResult.closed, p.read(&buf));
    try testing.expectError(error.Closed, p.write("x"));
    // The shell dies of the hang-up or exits on end of input.
    const status = p.wait();
    try testing.expect(status == .signaled or status == .exited);
}
