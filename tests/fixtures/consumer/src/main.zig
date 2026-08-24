const n64 = @import("n64");
const assets = @import("assets");

comptime {
    if (assets.raw_data.len != 10) @compileError("raw asset was not embedded");
    if (assets.generated_data.len != 15) @compileError("generated asset was not embedded");
    if (assets.custom_rsp.len == 0) @compileError("ZSP asset was not embedded");
}

pub fn main() !void {}

pub fn alternateMain() !void {}

pub fn panicHandler(_: []const u8, _: ?usize) noreturn {
    while (true) {}
}

pub fn exceptionHandler(_: *n64.debug.TrapFrame) noreturn {
    while (true) {}
}

pub fn interruptHandler() void {}
