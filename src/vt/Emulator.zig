//! A terminal emulator in the manner of xterm, as the program in the
//! pseudo-terminal expects with TERM=xterm-256color: it feeds what the
//! program writes through a `Parser` and keeps the primary and alternate
//! screens as `Grid`s, with a cursor, a pen style, tab stops, character sets
//! and the replies owed to the program's queries.
//!
//! There is no scrollback: what scrolls off the top is lost. Combining marks
//! are dropped. Mouse reporting and OSC strings are not supported.

const Emulator = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Parser = @import("Parser.zig");
const Grid = @import("Grid.zig");
const codepointWidth = @import("width.zig").codepointWidth;

gpa: Allocator,
parser: Parser = .{},
primary: Grid,
alternate: Grid,
alt_active: bool = false,
cursor: Cursor = .{},
/// What DECSC saved, one for each screen.
saved: [2]Saved = .{ .{}, .{} },
modes: Modes = .{},
/// The scroll region, rows scroll_top to scroll_bottom inclusive.
scroll_top: u16 = 0,
scroll_bottom: u16,
/// Whether column x is a tab stop.
tabs: []bool,
charsets: Charsets = .{},
/// The last character printed, for REP.
last_printed: ?u21 = null,
/// Answers to the program's queries, waiting to be written back to it.
reply_buffer: [256]u8 = undefined,
reply_len: usize = 0,
/// Set by BEL; the owner clears it.
bell: bool = false,

pub const Cursor = struct {
    x: u16 = 0,
    y: u16 = 0,
    /// Set after printing in the last column with autowrap on: the next
    /// character goes to the start of the next line.
    pending_wrap: bool = false,
    /// The pen: the style of printed characters.
    style: Grid.Style = .{},
};

pub const Modes = struct {
    autowrap: bool = true,
    origin: bool = false,
    insert: bool = false,
    newline: bool = false,
    cursor_visible: bool = true,
    app_cursor: bool = false,
    app_keypad: bool = false,
    bracketed_paste: bool = false,
};

const Charsets = struct {
    /// G0 and G1.
    g: [2]Charset = .{ .ascii, .ascii },
    /// Which of them is invoked into GL, by SI and SO.
    shift: u1 = 0,
};

const Charset = enum { ascii, dec_graphics };

const Saved = struct {
    cursor: Cursor = .{},
    origin: bool = false,
    charsets: Charsets = .{},
};

/// The DEC special graphics set, for 0x5F to 0x7E: line drawing and a few
/// symbols.
const dec_graphics = [32]u21{
    ' ', 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0, // _ ` a-f
    0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C, // g-n
    0x23BA, 0x23BB, 0x2500, 0x23BC, 0x23BD, 0x251C, 0x2524, 0x2534, // o-v
    0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7, // w-~
};

pub fn init(gpa: Allocator, cols: u16, rows: u16) Allocator.Error!Emulator {
    var primary: Grid = try .init(gpa, cols, rows);
    errdefer primary.deinit(gpa);
    var alternate: Grid = try .init(gpa, cols, rows);
    errdefer alternate.deinit(gpa);
    const tabs = try gpa.alloc(bool, cols);
    defaultTabs(tabs);
    return .{
        .gpa = gpa,
        .primary = primary,
        .alternate = alternate,
        .scroll_bottom = rows - 1,
        .tabs = tabs,
    };
}

pub fn deinit(e: *Emulator) void {
    e.primary.deinit(e.gpa);
    e.alternate.deinit(e.gpa);
    e.gpa.free(e.tabs);
    e.* = undefined;
}

/// Takes what the program wrote. It never fails: what cannot be handled is
/// dropped.
pub fn feed(e: *Emulator, bytes: []const u8) void {
    e.parser.feed(bytes, e);
}

/// The screen being shown, primary or alternate.
pub fn screen(e: *const Emulator) *const Grid {
    return if (e.alt_active) &e.alternate else &e.primary;
}

/// The replies to write back to the program, such as cursor position reports.
pub fn replies(e: *const Emulator) []const u8 {
    return e.reply_buffer[0..e.reply_len];
}

pub fn clearReplies(e: *Emulator) void {
    e.reply_len = 0;
}

fn active(e: *Emulator) *Grid {
    return if (e.alt_active) &e.alternate else &e.primary;
}

/// What erasing and scrolling leave behind, in the pen's background.
fn blank(e: *const Emulator) Grid.Cell {
    return .blank(e.cursor.style);
}

/// Appends a reply, or drops it when the buffer is full.
fn reply(e: *Emulator, comptime fmt: []const u8, args: anytype) void {
    const out = std.fmt.bufPrint(e.reply_buffer[e.reply_len..], fmt, args) catch return;
    e.reply_len += out.len;
}

fn defaultTabs(tabs: []bool) void {
    for (tabs, 0..) |*tab, x| tab.* = x % 8 == 0 and x != 0;
}

// Parser handler.

pub fn print(e: *Emulator, cp: u21) void {
    const c = e.mapCharset(cp);
    const n = codepointWidth(c);
    if (n == 0) return; // combining marks are dropped
    const g = e.active();
    if (n == 2 and g.cols < 2) return;

    if (e.cursor.pending_wrap and e.modes.autowrap) {
        e.cursor.x = 0;
        e.index();
    }
    if (n == 2 and e.cursor.x + 1 >= g.cols) {
        // A wide character does not fit before the right edge.
        if (e.modes.autowrap) {
            e.cursor.x = 0;
            e.index();
        } else {
            e.cursor.x = g.cols - 2;
        }
    }
    const x = e.cursor.x;
    if (e.modes.insert) g.insertBlanks(e.cursor.y, x, n, e.blank());

    const cells = g.row(e.cursor.y);
    // Overwriting half of a wide character blanks its other half.
    if (cells[x].wide == .spacer and x > 0) cells[x - 1] = e.blank();
    if (cells[x + n - 1].wide == .head and x + n < g.cols) cells[x + n] = e.blank();
    const style = e.cursor.style;
    if (n == 2) {
        cells[x] = .{ .cp = c, .wide = .head, .style = style };
        cells[x + 1] = .{ .wide = .spacer, .style = style };
    } else {
        cells[x] = .{ .cp = c, .style = style };
    }

    if (x + n >= g.cols) {
        e.cursor.x = g.cols - 1;
        e.cursor.pending_wrap = e.modes.autowrap;
    } else {
        e.cursor.x = x + n;
        e.cursor.pending_wrap = false;
    }
    e.last_printed = c;
}

pub fn execute(e: *Emulator, c: u8) void {
    switch (c) {
        0x07 => e.bell = true,
        0x08 => {
            e.cursor.x -|= 1;
            e.cursor.pending_wrap = false;
        },
        '\t' => e.tabForward(1),
        '\n', 0x0B, 0x0C => {
            e.index();
            if (e.modes.newline) e.cursor.x = 0;
        },
        '\r' => {
            e.cursor.x = 0;
            e.cursor.pending_wrap = false;
        },
        0x0E => e.charsets.shift = 1,
        0x0F => e.charsets.shift = 0,
        else => {},
    }
}

pub fn escDispatch(e: *Emulator, esc: Parser.Esc) void {
    if (esc.intermediates.len == 0) {
        switch (esc.final) {
            '7' => e.saveCursor(),
            '8' => e.restoreCursor(),
            'D' => e.index(),
            'E' => {
                e.cursor.x = 0;
                e.index();
            },
            'M' => e.reverseIndex(),
            'H' => e.tabs[e.cursor.x] = true,
            'c' => e.fullReset(),
            '=' => e.modes.app_keypad = true,
            '>' => e.modes.app_keypad = false,
            else => {},
        }
        return;
    }
    if (esc.intermediates.len != 1) return;
    switch (esc.intermediates[0]) {
        '(', ')' => {
            const set: Charset = if (esc.final == '0') .dec_graphics else .ascii;
            e.charsets.g[@intFromBool(esc.intermediates[0] == ')')] = set;
        },
        '#' => if (esc.final == '8') e.screenAlignment(),
        else => {},
    }
}

pub fn csiDispatch(e: *Emulator, csi: Parser.Csi) void {
    if (csi.intermediates.len != 0) return;
    switch (csi.marker) {
        0 => {},
        '>' => if (csi.final == 'c' and csi.param(0, 0) == 0) e.reply("\x1b[>1;10;0c", .{}),
        '?' => if (csi.final == 'n' and csi.param(0, 0) == 6) e.reportPosition("?"),
        else => {},
    }
    if (csi.marker != 0) return;

    const n = csi.param(0, 1);
    const g = e.active();
    const y = e.cursor.y;
    switch (csi.final) {
        '@' => {
            g.insertBlanks(y, e.cursor.x, n, e.blank());
            e.cursor.pending_wrap = false;
        },
        'A' => e.cursorUp(n),
        'B', 'e' => e.cursorDown(n),
        'C', 'a' => e.cursorForward(n),
        'D' => e.cursorBack(n),
        'E' => {
            e.cursorDown(n);
            e.cursor.x = 0;
        },
        'F' => {
            e.cursorUp(n);
            e.cursor.x = 0;
        },
        'G', '`' => e.setX(n - 1),
        'H', 'f' => e.moveTo(@as(i32, csi.param(1, 1)) - 1, @as(i32, n) - 1),
        'd' => e.moveTo(e.cursor.x, @as(i32, n) - 1),
        'I' => e.tabForward(n),
        'Z' => e.tabBack(n),
        'J' => e.eraseDisplay(csi.param(0, 0)),
        'K' => e.eraseLine(csi.param(0, 0)),
        'P' => {
            g.deleteCells(y, e.cursor.x, n, e.blank());
            e.cursor.pending_wrap = false;
        },
        'X' => {
            g.erase(y, e.cursor.x, @intCast(@min(@as(u32, e.cursor.x) + n, g.cols)), e.blank());
            e.cursor.pending_wrap = false;
        },
        'g' => switch (csi.param(0, 0)) {
            0 => e.tabs[e.cursor.x] = false,
            3 => @memset(e.tabs, false),
            else => {},
        },
        'm' => e.selectGraphicRendition(csi),
        'n' => switch (csi.param(0, 0)) {
            5 => e.reply("\x1b[0n", .{}),
            6 => e.reportPosition(""),
            else => {},
        },
        'c' => if (csi.param(0, 0) == 0) e.reply("\x1b[?1;2c", .{}),
        's' => e.saveCursor(),
        'u' => e.restoreCursor(),
        else => {},
    }
}

// Characters.

fn mapCharset(e: *const Emulator, cp: u21) u21 {
    if (e.charsets.g[e.charsets.shift] == .dec_graphics and cp >= 0x5F and cp <= 0x7E) {
        return dec_graphics[cp - 0x5F];
    }
    return cp;
}

// Cursor movement. Every move clears the pending wrap.

/// Moves down a line, scrolling the region up at its bottom margin.
fn index(e: *Emulator) void {
    e.cursor.pending_wrap = false;
    if (e.cursor.y == e.scroll_bottom) {
        e.active().scrollUp(e.scroll_top, e.scroll_bottom, 1, e.blank());
    } else if (e.cursor.y + 1 < e.primary.rows) {
        e.cursor.y += 1;
    }
}

/// Moves up a line, scrolling the region down at its top margin.
fn reverseIndex(e: *Emulator) void {
    e.cursor.pending_wrap = false;
    if (e.cursor.y == e.scroll_top) {
        e.active().scrollDown(e.scroll_top, e.scroll_bottom, 1, e.blank());
    } else if (e.cursor.y > 0) {
        e.cursor.y -= 1;
    }
}

/// Moves to column x and row y, both 0-based and clamped to the screen. In
/// origin mode y is relative to the scroll region and confined to it.
fn moveTo(e: *Emulator, x: i32, y: i32) void {
    const top: i32 = if (e.modes.origin) e.scroll_top else 0;
    const bottom: i32 = if (e.modes.origin) e.scroll_bottom else e.primary.rows - 1;
    e.cursor.x = @intCast(std.math.clamp(x, 0, @as(i32, e.primary.cols) - 1));
    e.cursor.y = @intCast(std.math.clamp(y + top, top, bottom));
    e.cursor.pending_wrap = false;
}

fn setX(e: *Emulator, x: u16) void {
    e.cursor.x = @min(x, e.primary.cols - 1);
    e.cursor.pending_wrap = false;
}

/// CUU: up n rows, stopping at the top margin when starting below it.
fn cursorUp(e: *Emulator, n: u16) void {
    const limit = if (e.cursor.y >= e.scroll_top) e.scroll_top else 0;
    e.cursor.y = @max(e.cursor.y -| n, limit);
    e.cursor.pending_wrap = false;
}

/// CUD: down n rows, stopping at the bottom margin when starting above it.
fn cursorDown(e: *Emulator, n: u16) void {
    const limit = if (e.cursor.y <= e.scroll_bottom) e.scroll_bottom else e.primary.rows - 1;
    e.cursor.y = @min(e.cursor.y +| n, limit);
    e.cursor.pending_wrap = false;
}

fn cursorForward(e: *Emulator, n: u16) void {
    e.setX(e.cursor.x +| n);
}

fn cursorBack(e: *Emulator, n: u16) void {
    e.setX(e.cursor.x -| n);
}

/// Moves to the n-th next tab stop, or the last column.
fn tabForward(e: *Emulator, n: u16) void {
    const last = e.primary.cols - 1;
    var x = e.cursor.x;
    var left = n;
    while (left > 0 and x < last) : (left -= 1) {
        x += 1;
        while (x < last and !e.tabs[x]) x += 1;
    }
    e.setX(x);
}

/// Moves to the n-th previous tab stop, or the first column.
fn tabBack(e: *Emulator, n: u16) void {
    var x = e.cursor.x;
    var left = n;
    while (left > 0 and x > 0) : (left -= 1) {
        x -= 1;
        while (x > 0 and !e.tabs[x]) x -= 1;
    }
    e.setX(x);
}

fn saveCursor(e: *Emulator) void {
    e.saved[@intFromBool(e.alt_active)] = .{
        .cursor = e.cursor,
        .origin = e.modes.origin,
        .charsets = e.charsets,
    };
}

fn restoreCursor(e: *Emulator) void {
    const s = e.saved[@intFromBool(e.alt_active)];
    e.cursor = s.cursor;
    e.modes.origin = s.origin;
    e.charsets = s.charsets;
    if (e.cursor.x >= e.primary.cols or e.cursor.y >= e.primary.rows) {
        e.cursor.x = @min(e.cursor.x, e.primary.cols - 1);
        e.cursor.y = @min(e.cursor.y, e.primary.rows - 1);
        e.cursor.pending_wrap = false;
    }
}

/// CPR: the cursor position, 1-based, its row relative to the scroll region
/// in origin mode.
fn reportPosition(e: *Emulator, comptime marker: []const u8) void {
    const top = if (e.modes.origin) e.scroll_top else 0;
    e.reply("\x1b[" ++ marker ++ "{d};{d}R", .{ (e.cursor.y -| top) + 1, e.cursor.x + 1 });
}

// Erasing.

fn eraseDisplay(e: *Emulator, mode: u16) void {
    const g = e.active();
    const y = e.cursor.y;
    switch (mode) {
        0 => {
            g.erase(y, e.cursor.x, g.cols, e.blank());
            for (y + 1..g.rows) |below| g.erase(@intCast(below), 0, g.cols, e.blank());
        },
        1 => {
            for (0..y) |above| g.erase(@intCast(above), 0, g.cols, e.blank());
            g.erase(y, 0, e.cursor.x + 1, e.blank());
        },
        2 => g.eraseAll(e.blank()),
        else => return, // 3 erases the scrollback, which there is none of
    }
    e.cursor.pending_wrap = false;
}

fn eraseLine(e: *Emulator, mode: u16) void {
    const g = e.active();
    const y = e.cursor.y;
    switch (mode) {
        0 => g.erase(y, e.cursor.x, g.cols, e.blank()),
        1 => g.erase(y, 0, e.cursor.x + 1, e.blank()),
        2 => g.erase(y, 0, g.cols, e.blank()),
        else => return,
    }
    e.cursor.pending_wrap = false;
}

/// DECALN: fills the screen with 'E', resets the scroll region and moves
/// home, as xterm does.
fn screenAlignment(e: *Emulator) void {
    e.active().eraseAll(.{ .cp = 'E' });
    e.scroll_top = 0;
    e.scroll_bottom = e.primary.rows - 1;
    e.moveTo(0, 0);
}

/// RIS: everything back to how it started, both screens erased. Pending
/// replies are kept.
fn fullReset(e: *Emulator) void {
    e.primary.eraseAll(.{});
    e.alternate.eraseAll(.{});
    e.alt_active = false;
    e.cursor = .{};
    e.saved = .{ .{}, .{} };
    e.modes = .{};
    e.scroll_top = 0;
    e.scroll_bottom = e.primary.rows - 1;
    defaultTabs(e.tabs);
    e.charsets = .{};
    e.last_printed = null;
    e.bell = false;
}

// SGR.

fn selectGraphicRendition(e: *Emulator, csi: Parser.Csi) void {
    const style = &e.cursor.style;
    if (csi.params.len == 0) {
        style.* = .{};
        return;
    }
    const params = csi.params;
    var i: usize = 0;
    while (i < params.len) {
        // A parameter and its ':' sub-parameters.
        var end = i + 1;
        while (end < params.len and csi.isSub(end)) end += 1;
        const subs = params[i + 1 .. end];
        switch (params[i]) {
            0 => style.* = .{},
            1 => style.attrs.bold = true,
            2 => style.attrs.dim = true,
            3 => style.attrs.italic = true,
            4 => style.attrs.underline = subs.len == 0 or subs[0] != 0,
            5, 6 => style.attrs.blink = true,
            7 => style.attrs.inverse = true,
            8 => style.attrs.invisible = true,
            9 => style.attrs.strikethrough = true,
            21 => style.attrs.underline = true,
            22 => {
                style.attrs.bold = false;
                style.attrs.dim = false;
            },
            23 => style.attrs.italic = false,
            24 => style.attrs.underline = false,
            25 => style.attrs.blink = false,
            27 => style.attrs.inverse = false,
            28 => style.attrs.invisible = false,
            29 => style.attrs.strikethrough = false,
            30...37 => |p| style.fg = .{ .palette = @intCast(p - 30) },
            39 => style.fg = .default,
            40...47 => |p| style.bg = .{ .palette = @intCast(p - 40) },
            49 => style.bg = .default,
            90...97 => |p| style.fg = .{ .palette = @intCast(p - 90 + 8) },
            100...107 => |p| style.bg = .{ .palette = @intCast(p - 100 + 8) },
            38, 48, 58 => |p| {
                const ext = if (subs.len > 0) extendedColor(subs, true) else extendedColor(params[end..], false);
                // The semicolon form takes up the parameters after it.
                if (subs.len == 0) end += ext.used;
                if (ext.color) |c| switch (p) {
                    38 => style.fg = c,
                    48 => style.bg = c,
                    else => {}, // the underline color is not supported
                };
            },
            else => {},
        }
        i = end;
    }
}

const ExtendedColor = struct {
    color: ?Grid.Color,
    /// How many of the arguments it took up.
    used: usize,
};

/// Parses the arguments of SGR 38, 48 or 58: `5;n` for a palette entry or
/// `2;r;g;b` for a direct color. The colon form may also hold a color space
/// id before r, as in `38:2:cs:r:g:b`.
fn extendedColor(args: []const u16, colon: bool) ExtendedColor {
    if (args.len == 0) return .{ .color = null, .used = 0 };
    switch (args[0]) {
        5 => {
            if (args.len < 2) return .{ .color = null, .used = args.len };
            return .{ .color = .{ .palette = channel(args[1]) }, .used = 2 };
        },
        2 => {
            if (args.len < 4) return .{ .color = null, .used = args.len };
            const rgb = if (colon and args.len >= 5) args[2..5] else args[1..4];
            return .{
                .color = .{ .rgb = .{ .r = channel(rgb[0]), .g = channel(rgb[1]), .b = channel(rgb[2]) } },
                .used = 4,
            };
        },
        else => return .{ .color = null, .used = 1 },
    }
}

fn channel(value: u16) u8 {
    return @intCast(@min(value, 255));
}

const testing = std.testing;

fn expectRows(e: *const Emulator, expected: []const []const u8) !void {
    const g = e.screen();
    try testing.expectEqual(expected.len, g.rows);
    for (expected, 0..) |text, y| {
        var buf: [256]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        try g.writeRow(@intCast(y), &w);
        try testing.expectEqualStrings(text, w.buffered());
    }
}

fn expectCursor(e: *const Emulator, x: u16, y: u16) !void {
    try testing.expectEqual(x, e.cursor.x);
    try testing.expectEqual(y, e.cursor.y);
}

fn cellAt(e: *const Emulator, x: u16, y: u16) Grid.Cell {
    return e.screen().row(y)[x];
}

test "text and CR LF" {
    var e: Emulator = try .init(testing.allocator, 10, 3);
    defer e.deinit();
    e.feed("hello\r\nworld");
    try expectRows(&e, &.{ "hello", "world", "" });
    try expectCursor(&e, 5, 1);
    // LF alone keeps the column.
    e.feed("\nx");
    try expectRows(&e, &.{ "hello", "world", "     x" });
}

test "autowrap and the pending wrap" {
    var e: Emulator = try .init(testing.allocator, 5, 3);
    defer e.deinit();
    e.feed("abcde");
    try expectCursor(&e, 4, 0);
    try testing.expect(e.cursor.pending_wrap);
    e.feed("\rX");
    try expectRows(&e, &.{ "Xbcde", "", "" });

    e.feed("\x1b[2J\x1b[Habcdefg");
    try expectRows(&e, &.{ "abcde", "fg", "" });
    try expectCursor(&e, 2, 1);

    // A cursor move cancels the pending wrap.
    e.feed("\x1b[2J\x1b[Habcde\x1b[1;5HZ");
    try expectRows(&e, &.{ "abcdZ", "", "" });
}

test "LF at the bottom scrolls" {
    var e: Emulator = try .init(testing.allocator, 4, 3);
    defer e.deinit();
    e.feed("1\r\n2\r\n3\r\n4");
    try expectRows(&e, &.{ "2", "3", "4" });
    try expectCursor(&e, 1, 2);
    // So does wrapping on the last row.
    e.feed("abcd");
    try expectRows(&e, &.{ "3", "4abc", "d" });
    // The new line takes the pen's background.
    e.feed("\x1b[41m\n");
    try testing.expect(cellAt(&e, 3, 2).eql(.{ .style = .{ .bg = .{ .palette = 1 } } }));
    // VT and FF act as LF.
    e.feed("\x1b[H\x0bv\x0cf");
    try expectRows(&e, &.{ "4abc", "v", " f" });
}

test "BS stops at column 0" {
    var e: Emulator = try .init(testing.allocator, 5, 2);
    defer e.deinit();
    e.feed("ab\x08\x08\x08c");
    try expectRows(&e, &.{ "cb", "" });
    // BS from the pending wrap.
    e.feed("\rvwxyz\x08Q");
    try expectRows(&e, &.{ "vwxQz", "" });
}

test "tabs, HTS and TBC" {
    var e: Emulator = try .init(testing.allocator, 20, 2);
    defer e.deinit();
    e.feed("a\tb\tc\td");
    try expectRows(&e, &.{ "a       b       c  d", "" });
    try expectCursor(&e, 19, 0);

    // Set a stop at column 3, clear the one at 8.
    e.feed("\r\n\x1b[3G\x1bH\x1b[9G\x1b[g\r\tx\ty");
    try expectRows(&e, &.{ "a       b       c  d", "  x             y" });

    // CHT and CBT.
    e.feed("\r\x1b[2IA\x1b[2ZB\x1b[2ZC");
    try testing.expectEqual(@as(u16, 1), e.cursor.x);
    try expectRows(&e, &.{ "a       b       c  d", "C B             A" });

    // TBC 3 clears every stop.
    e.feed("\x1b[3g\r\tE");
    try expectRows(&e, &.{ "a       b       c  d", "C B             A  E" });
}

test "cursor movement is clamped" {
    var e: Emulator = try .init(testing.allocator, 10, 5);
    defer e.deinit();
    e.feed("\x1b[3;4H");
    try expectCursor(&e, 3, 2);
    e.feed("\x1b[A");
    try expectCursor(&e, 3, 1);
    e.feed("\x1b[9A");
    try expectCursor(&e, 3, 0);
    e.feed("\x1b[2B");
    try expectCursor(&e, 3, 2);
    e.feed("\x1b[99B");
    try expectCursor(&e, 3, 4);
    e.feed("\x1b[4C");
    try expectCursor(&e, 7, 4);
    e.feed("\x1b[99C");
    try expectCursor(&e, 9, 4);
    e.feed("\x1b[3D");
    try expectCursor(&e, 6, 4);
    e.feed("\x1b[99D");
    try expectCursor(&e, 0, 4);
    e.feed("\x1b[5G");
    try expectCursor(&e, 4, 4);
    e.feed("\x1b[99`");
    try expectCursor(&e, 9, 4);
    e.feed("\x1b[2d");
    try expectCursor(&e, 9, 1);
    e.feed("\x1b[0d");
    try expectCursor(&e, 9, 0);
    e.feed("\x1b[99;99f");
    try expectCursor(&e, 9, 4);
    e.feed("\x1b[H");
    try expectCursor(&e, 0, 0);
    e.feed("\x1b[;3H");
    try expectCursor(&e, 2, 0);
    e.feed("\x1b[2a\x1b[3e");
    try expectCursor(&e, 4, 3);
    e.feed("\x1b[2;5H\x1b[2E");
    try expectCursor(&e, 0, 3);
    e.feed("\x1b[1;5H\x1b[F");
    try expectCursor(&e, 0, 0);
    e.feed("\x1b[3;5H\x1b[2F");
    try expectCursor(&e, 0, 0);
}

test "ED and EL erase with the background color" {
    var e: Emulator = try .init(testing.allocator, 4, 3);
    defer e.deinit();
    const red: Grid.Cell = .{ .style = .{ .bg = .{ .palette = 1 } } };
    const fill = "abcd\r\nefgh\r\nijkl";

    e.feed(fill ++ "\x1b[2;3H\x1b[41m\x1b[J");
    try expectRows(&e, &.{ "abcd", "ef", "" });
    try testing.expect(cellAt(&e, 2, 1).eql(red));
    try testing.expect(cellAt(&e, 0, 2).eql(red));
    try testing.expect(cellAt(&e, 1, 1).eql(.{ .cp = 'f' }));

    e.feed("\x1b[m\x1b[H" ++ fill ++ "\x1b[2;3H\x1b[1J");
    try expectRows(&e, &.{ "", "   h", "ijkl" });

    e.feed("\x1b[H" ++ fill ++ "\x1b[2;3H\x1b[2J");
    try expectRows(&e, &.{ "", "", "" });
    try expectCursor(&e, 2, 1);

    // ED 3 is a no-op: there is no scrollback.
    e.feed("\x1b[H" ++ fill ++ "\x1b[3J");
    try expectRows(&e, &.{ "abcd", "efgh", "ijkl" });

    e.feed("\x1b[2;2H\x1b[K");
    try expectRows(&e, &.{ "abcd", "e", "ijkl" });
    e.feed("\x1b[3;2H\x1b[1K");
    try expectRows(&e, &.{ "abcd", "e", "  kl" });
    e.feed("\x1b[1;3H\x1b[44m\x1b[2K");
    try expectRows(&e, &.{ "", "e", "  kl" });
    try testing.expect(cellAt(&e, 3, 0).eql(.{ .style = .{ .bg = .{ .palette = 4 } } }));
}

test "ICH, DCH and ECH" {
    var e: Emulator = try .init(testing.allocator, 6, 1);
    defer e.deinit();
    e.feed("abcdef\x1b[3G\x1b[2@");
    try expectRows(&e, &.{"ab  cd"});
    e.feed("\x1b[3P");
    try expectRows(&e, &.{"abd"});
    e.feed("\x1b[1G\x1b[2X");
    try expectRows(&e, &.{"  d"});
    e.feed("\x1b[1G\x1b[99X");
    try expectRows(&e, &.{""});
    try expectCursor(&e, 0, 0);
}

test "SGR" {
    var e: Emulator = try .init(testing.allocator, 4, 1);
    defer e.deinit();
    const style = &e.cursor.style;

    e.feed("\x1b[1;2;3;4;5;7;8;9m");
    try testing.expectEqual(Grid.Attrs{
        .bold = true,
        .dim = true,
        .italic = true,
        .underline = true,
        .blink = true,
        .inverse = true,
        .invisible = true,
        .strikethrough = true,
    }, style.attrs);
    e.feed("\x1b[22;23;24;25;27;28;29m");
    try testing.expectEqual(Grid.Attrs{}, style.attrs);
    e.feed("\x1b[4:3m");
    try testing.expect(style.attrs.underline);
    e.feed("\x1b[4:0m");
    try testing.expect(!style.attrs.underline);
    e.feed("\x1b[21;6m");
    try testing.expect(style.attrs.underline and style.attrs.blink);

    e.feed("\x1b[31;42m");
    try testing.expect(style.fg.eql(.{ .palette = 1 }) and style.bg.eql(.{ .palette = 2 }));
    e.feed("\x1b[97;100m");
    try testing.expect(style.fg.eql(.{ .palette = 15 }) and style.bg.eql(.{ .palette = 8 }));
    e.feed("\x1b[38;5;200;48;5;999m");
    try testing.expect(style.fg.eql(.{ .palette = 200 }) and style.bg.eql(.{ .palette = 255 }));
    e.feed("\x1b[38;2;1;2;3;1m");
    try testing.expect(style.fg.eql(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }));
    try testing.expect(style.attrs.bold);
    e.feed("\x1b[38:2::4:5:6m");
    try testing.expect(style.fg.eql(.{ .rgb = .{ .r = 4, .g = 5, .b = 6 } }));
    e.feed("\x1b[38:2:7:8:9m");
    try testing.expect(style.fg.eql(.{ .rgb = .{ .r = 7, .g = 8, .b = 9 } }));
    e.feed("\x1b[48:5:33;3m");
    try testing.expect(style.bg.eql(.{ .palette = 33 }) and style.attrs.italic);
    e.feed("\x1b[48;2;10;20;300m");
    try testing.expect(style.bg.eql(.{ .rgb = .{ .r = 10, .g = 20, .b = 255 } }));
    // The underline color is consumed and ignored, and so are its arguments.
    e.feed("\x1b[58;5;3;39m");
    try testing.expect(style.fg.eql(.default) and style.bg.eql(.{ .rgb = .{ .r = 10, .g = 20, .b = 255 } }));
    e.feed("\x1b[58:2::1:2:3;49m");
    try testing.expect(style.bg.eql(.default));

    // Characters take the pen's style.
    e.feed("\x1b[32mx");
    try testing.expect(cellAt(&e, 0, 0).style.fg.eql(.{ .palette = 2 }));

    // vim's modifyOtherKeys request is not SGR.
    const before = style.*;
    e.feed("\x1b[>4;2m");
    try testing.expect(style.eql(before));

    e.feed("\x1b[0m");
    try testing.expect(style.eql(.{}));
    e.feed("\x1b[1;31m\x1b[m");
    try testing.expect(style.eql(.{}));
    e.feed("\x1b[1;31m\x1b[;m");
    try testing.expect(style.eql(.{}));
}

test "wide characters" {
    var e: Emulator = try .init(testing.allocator, 5, 3);
    defer e.deinit();
    e.feed("あい");
    try expectRows(&e, &.{ "あい", "", "" });
    try expectCursor(&e, 4, 0);
    try testing.expect(!e.cursor.pending_wrap);
    // The third does not fit in the last column and wraps.
    e.feed("う");
    try expectRows(&e, &.{ "あい", "う", "" });
    try expectCursor(&e, 2, 1);

    // Overwriting the right half of a wide character blanks its left half,
    // and the left half blanks its right half.
    e.feed("\x1b[1;2Hx\x1b[1;3Hy");
    try expectRows(&e, &.{ " xy", "う", "" });
    try testing.expectEqual(Grid.Cell.Wide.narrow, cellAt(&e, 3, 0).wide);

    // A wide character over a narrow one followed by a wide one.
    e.feed("\x1b[3;1Habc\x1b[3;2Hいう");
    try expectRows(&e, &.{ " xy", "う", "aいう" });

    // Without autowrap, a wide character in the last column goes one back.
    e.feed("\x1b[2J\x1b[H");
    e.modes.autowrap = false;
    e.feed("abcdえ");
    try expectRows(&e, &.{ "abcえ", "", "" });
    try expectCursor(&e, 4, 0);
}

test "wide characters on a one-column screen are dropped" {
    var e: Emulator = try .init(testing.allocator, 1, 2);
    defer e.deinit();
    e.feed("あa");
    try expectRows(&e, &.{ "a", "" });
}

test "combining marks are dropped and invalid UTF-8 is replaced" {
    var e: Emulator = try .init(testing.allocator, 5, 1);
    defer e.deinit();
    e.feed("e\u{301}x\xFFy");
    try expectRows(&e, &.{"ex\u{FFFD}y"});
}

test "DEC special graphics" {
    var e: Emulator = try .init(testing.allocator, 8, 2);
    defer e.deinit();
    e.feed("\x1b(0lqk_x\x1b(Bq");
    try expectRows(&e, &.{ "┌─┐ │q", "" });
    // G1 invoked by SO, back to G0 by SI.
    e.feed("\r\n\x1b)0q\x0eq~\x0fq");
    try expectRows(&e, &.{ "┌─┐ │q", "q─·q" });
    try testing.expectEqual(@as(?u21, 'q'), e.last_printed);
}

test "DSR and DA replies" {
    var e: Emulator = try .init(testing.allocator, 10, 5);
    defer e.deinit();
    try testing.expectEqualStrings("", e.replies());
    e.feed("\x1b[5n\x1b[3;7H\x1b[6n");
    try testing.expectEqualStrings("\x1b[0n\x1b[3;7R", e.replies());
    e.clearReplies();
    e.feed("\x1b[c\x1b[0c\x1b[>c\x1b[?6n\x1b[1c\x1b[>1c");
    try testing.expectEqualStrings("\x1b[?1;2c\x1b[?1;2c\x1b[>1;10;0c\x1b[?3;7R", e.replies());
    e.clearReplies();
    try testing.expectEqualStrings("", e.replies());

    // In origin mode the row counts from the top margin.
    e.scroll_top = 1;
    e.scroll_bottom = 3;
    e.modes.origin = true;
    e.feed("\x1b[H\x1b[6n");
    try expectCursor(&e, 0, 1);
    try testing.expectEqualStrings("\x1b[1;1R", e.replies());
    e.clearReplies();

    // Replies past the buffer are dropped.
    for (0..100) |_| e.feed("\x1b[5n");
    try testing.expect(e.replies().len <= e.reply_buffer.len);
    try testing.expectEqual(@as(usize, 0), e.replies().len % 4);
}

test "DECSC and DECRC" {
    var e: Emulator = try .init(testing.allocator, 10, 5);
    defer e.deinit();
    e.feed("\x1b[3;4H\x1b[1;31m\x1b(0\x1b7");
    e.feed("\x1b[H\x1b[m\x1b(B");
    try testing.expect(e.cursor.style.eql(.{}));
    e.feed("\x1b8q");
    try expectRows(&e, &.{ "", "", "   ─", "", "" });
    try testing.expect(cellAt(&e, 3, 2).style.eql(.{ .fg = .{ .palette = 1 }, .attrs = .{ .bold = true } }));
    try expectCursor(&e, 4, 2);

    // CSI s and CSI u do the same.
    e.feed("\x1b[m\x1b(B\x1b[5;6H\x1b[s\x1b[Hx\x1b[uy");
    try expectRows(&e, &.{ "x", "", "   ─", "", "     y" });
}

test "keypad modes and the bell" {
    var e: Emulator = try .init(testing.allocator, 4, 2);
    defer e.deinit();
    e.feed("\x1b=");
    try testing.expect(e.modes.app_keypad);
    e.feed("\x1b>");
    try testing.expect(!e.modes.app_keypad);
    try testing.expect(!e.bell);
    e.feed("a\x07b");
    try testing.expect(e.bell);
    try expectRows(&e, &.{ "ab", "" });
}

test "index and reverse index" {
    var e: Emulator = try .init(testing.allocator, 3, 3);
    defer e.deinit();
    e.feed("a\r\nb\r\nc\x1bDd");
    try expectRows(&e, &.{ "b", "c", " d" });
    e.feed("\x1bEe");
    try expectRows(&e, &.{ "c", " d", "e" });
    e.feed("\x1b[H\x1bMf");
    try expectRows(&e, &.{ "f", "c", " d" });
    e.feed("\x1b[3;1H\x1bMg");
    try expectRows(&e, &.{ "f", "g", " d" });
}

test "DECALN and RIS" {
    var e: Emulator = try .init(testing.allocator, 3, 2);
    defer e.deinit();
    e.feed("\x1b[2;2H\x1b#8");
    try expectRows(&e, &.{ "EEE", "EEE" });
    try expectCursor(&e, 0, 0);

    e.feed("\x1b[31m\x1b(0\x1b=\x07\x1b[3g\x1b[5n\x1bc");
    try expectRows(&e, &.{ "", "" });
    try testing.expect(e.cursor.style.eql(.{}));
    try testing.expect(!e.modes.app_keypad and !e.bell);
    try testing.expectEqual(Charset.ascii, e.charsets.g[0]);
    try testing.expectEqualStrings("\x1b[0n", e.replies());
    try testing.expectEqual(@as(?u21, null), e.last_printed);
}

test "unsupported sequences are ignored" {
    var e: Emulator = try .init(testing.allocator, 6, 1);
    defer e.deinit();
    e.feed("a\x1b[?u\x1b[2 q\x1b[t\x1b[>4;2m\x1b[?1;2c\x1b]0;title\x07\x1bP+q\x1b\\\x1b%Gb");
    try expectRows(&e, &.{"ab"});
    try testing.expectEqualStrings("", e.replies());
    try testing.expect(e.cursor.style.eql(.{}));
}

test "init fails cleanly" {
    for (0..5) |fail_index| {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = fail_index });
        try testing.expectError(error.OutOfMemory, Emulator.init(failing.allocator(), 4, 4));
    }
}
