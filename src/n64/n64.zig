//! Nintendo 64 runtime. Namespaces group domains; types own their configuration.
pub const App = @import("app.zig").App;
pub const AppConfig = @import("app.zig").Config;
pub const audio = @import("audio.zig");
pub const cpu = @import("cpu.zig");
pub const debug = @import("debug.zig");
pub const display = @import("display.zig");
pub const graphics = @import("graphics.zig");
pub const hw = @import("hw.zig");
pub const input = @import("input.zig");
pub const interrupt = @import("interrupt.zig");
pub const math = @import("math.zig");
pub const pi = @import("pi.zig");
pub const rdp = @import("rdp.zig");
pub const rom = @import("rom.zig");
pub const rsp = @import("rsp.zig");
pub const time = @import("time.zig");

test {
    _ = @import("rsp/command_buffer_tests.zig");
    _ = @import("rsp/program_tests.zig");
    _ = @import("math_tests.zig");
    _ = @import("app.zig");
    _ = debug.profiler;
    _ = debug.backends.everdrive;
    _ = debug.backends.is_viewer;
    _ = debug.diagnostics;
    _ = debug.crash_screen.model;
    _ = debug.crash_screen.model.memory;
    _ = debug.crash_screen.font;
    _ = debug.crash_screen.ui;
    _ = @import("debug/crash_screen/input.zig");
    _ = @import("cpu/exception_codes.zig");
    _ = graphics;
    _ = input.Controllers;
    _ = time;
    _ = audio;
    _ = rom;
    _ = pi.Transfer;
    _ = rdp;
    _ = display;
}
