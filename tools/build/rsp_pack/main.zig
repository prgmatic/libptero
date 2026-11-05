//! Process entry for `rsp_pack`; `root.zig` holds its behavior.
const std = @import("std");
const rsp_pack = @import("root.zig");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    rsp_pack.run(init.gpa, init.io, args[1..]) catch |err| return fail(err);
    return 0;
}

/// Prints usage for bad arguments, otherwise the error's name.
fn fail(err: anyerror) u8 {
    if (err == error.InvalidArguments) std.debug.print("{s}", .{rsp_pack.usage}) else std.debug.print("rsp_pack: error: {s}\n", .{@errorName(err)});
    return 1;
}
