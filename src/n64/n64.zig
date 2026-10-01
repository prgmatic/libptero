pub const debug = @import("debug.zig");
pub const io = @import("io.zig");
pub const interfaces = @import("interfaces.zig");
pub const cpu = @import("cpu.zig");
pub const cache = @import("cpu/cache.zig");
pub const graphics = @import("graphics.zig");

test {
    _ = graphics.model;
    _ = graphics.geometry;
    _ = @import("graphics/material.zig");
    _ = io.joypad;
    _ = graphics.rdp.RenderQueue;
}
pub const rsp = @import("rsp/rsp.zig");
pub const interrupt = @import("interrupt.zig");
pub const math = @import("math.zig");
