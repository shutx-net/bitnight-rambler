//! The terminal emulator behind `rambit shell`: it parses what the program in
//! the pseudo-terminal writes and keeps a screen of cells, so that ramblers can
//! be drawn over it.

pub const width = @import("width.zig");

test {
    _ = width;
}
