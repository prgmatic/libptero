//! Process entry for `elf_pack`; `root.zig` holds its behavior.
const std = @import("std");
const elf_pack = @import("root.zig");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    elf_pack.run(init.gpa, init.io, args[1..]) catch |err| return fail(err);
    return 0;
}

/// Prints usage for bad arguments, otherwise the error's name.
fn fail(err: anyerror) u8 {
    if (err == error.InvalidArguments) std.debug.print("{s}", .{elf_pack.usage}) else std.debug.print("elf_pack: error: {s}\n", .{@errorName(err)});
    return 1;
}
