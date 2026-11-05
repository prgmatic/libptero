//! Host-compilable view of the RSP program and queue ABI. Host tools such as
//! the RSP interpreter import this instead of copying runtime definitions.
pub const Program = @import("Program.zig");
pub const overlay_layout = @import("overlay_layout.zig");
pub const InternalCommand = @import("internal_commands.zig").InternalCommand;
/// Bytes the resident dispatcher fetches per command window.
pub const fetch_window_byte_len = 0x100;

test {
    _ = overlay_layout;
}
