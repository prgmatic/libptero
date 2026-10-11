//! Programmatic deploy SDK: protocol clients accept an injectable byte stream.
pub const options = @import("options.zig");
pub const rom = @import("rom.zig");
pub const cic = @import("cic.zig");
pub const stream = @import("stream.zig");
pub const sc64 = @import("sc64.zig");
pub const everdrive = @import("everdrive.zig");
pub const packet = @import("packet.zig");
pub const monitor = @import("monitor.zig");
pub const protocol = @import("run_protocol");
pub const cli = @import("cli.zig");
test {
    @import("std").testing.refAllDecls(@This());
    _ = @import("ftdi.zig");
    _ = @import("interrupt.zig");
    _ = @import("power.zig");
    _ = @import("files.zig");
    _ = @import("hardware.zig");
    _ = @import("ares.zig");
    _ = @import("relay.zig");
}
