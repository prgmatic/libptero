//! Process entry for the `zsp` command; `cli.zig` holds its behavior.
const std = @import("std");
const cli = @import("cli.zig");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [1024]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const context: cli.Context = .{ .allocator = init.gpa, .io = init.io, .stdout = &stdout.interface, .stderr = &stderr.interface };
    const code = cli.main(context, args[1..]);
    try stdout.interface.flush();
    try stderr.interface.flush();
    return code;
}
