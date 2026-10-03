pub const debug = @import("debug.zig");
pub const io = @import("io.zig");
pub const interfaces = @import("interfaces.zig");
pub const cpu = @import("cpu.zig");
pub const cache = @import("cpu/cache.zig");
pub const graphics = @import("graphics.zig");
pub const display = @import("display.zig");
pub const time = @import("time.zig");
pub const audio = @import("audio.zig");
pub const rom = @import("rom.zig");

test {
    _ = debug.crash_screen.model;
    _ = debug.crash_screen.model.memory;
    _ = debug.crash_screen.font;
    _ = debug.crash_screen.ui;
    _ = @import("debug/crash_screen/input.zig");
    _ = @import("debug/exception_codes.zig");
    _ = graphics.image;
    _ = graphics.depth;
    _ = graphics.model;
    _ = graphics.animation;
    _ = @import("graphics/skinned_model.zig");
    _ = @import("graphics/mutable_model.zig");
    _ = graphics.geometry;
    _ = @import("graphics/material.zig");
    _ = io.joypad;
    _ = time;
    _ = audio;
    _ = rom;
    _ = io.pi;
    _ = graphics.rdp.RenderQueue;
    _ = graphics.rdp.Completion;
    _ = display;
}
pub const rsp = @import("rsp/rsp.zig");
pub const interrupt = @import("interrupt.zig");
pub const math = @import("math.zig");
