//! The terminal emulator behind `rambit shell`: it parses what the program in
//! the pseudo-terminal writes and keeps a screen of cells, so that ramblers can
//! be drawn over it.

pub const width = @import("width.zig");
pub const Parser = @import("Parser.zig");
pub const Grid = @import("Grid.zig");
pub const Emulator = @import("Emulator.zig");

test {
    _ = width;
    _ = Parser;
    _ = Grid;
    _ = Emulator;
}
