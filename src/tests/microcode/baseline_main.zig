//! `zig build rsp-baseline [-- --update]`: reports RSP workloads against the
//! recorded baseline (exit status 1 on regression) or rewrites it.
const std = @import("std");
const baseline = @import("baseline.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.gpa);
    defer init.gpa.free(args);
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const failed = try baseline.runCommand(init.io, init.gpa, std.Io.Dir.cwd(), args, &stdout.interface);
    try stdout.interface.flush();
    std.process.exit(@intFromBool(failed));
}
