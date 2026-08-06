const std = @import("std");

const rsp_header_len = 24;
const imem_base = 0x1000;
const imem_end = 0x2000;
const overlay_dmem_start = 0x0a00;

pub fn main(init: std.process.Init) !void {
    const alloc = std.heap.smp_allocator;
    const io = init.io;
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 3) return error.InvalidArguments;

    const resident = try readAll(io, alloc, args[1]);
    defer alloc.free(resident);
    const text_start = try overlayTextStart(resident);

    const output = try std.Io.Dir.cwd().createFile(io, args[2], .{});
    defer output.close(io);
    var buffer: [4096]u8 = undefined;
    var file_writer = output.writer(io, &buffer);
    try writeLinkerScript(&file_writer.interface, text_start);
    try file_writer.interface.flush();
}

fn readAll(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(io, &buffer);
    return reader.interface.allocRemaining(alloc, .unlimited);
}

fn overlayTextStart(resident: []const u8) !u16 {
    if (resident.len < rsp_header_len) return error.InvalidRsp;
    const text_len = std.mem.readInt(u16, resident[0..2], .big);
    if (text_len == 0) return error.InvalidRsp;
    const start = std.mem.alignForward(u32, imem_base + text_len, 16);
    if (start >= imem_end) return error.ResidentTextTooLarge;
    return @intCast(start);
}

fn writeLinkerScript(writer: *std.Io.Writer, text_start: u16) !void {
    try writer.print(
        \\OUTPUT_ARCH(mips)
        \\ENTRY(_start)
        \\
        \\MEMORY {{
        \\    DMEM : ORIGIN = 0x{x:0>4}, LENGTH = 0x{x:0>4}
        \\    IMEM : ORIGIN = 0x{x:0>4}, LENGTH = 0x{x:0>4}
        \\}}
        \\
        \\SECTIONS {{
        \\    .data 0x{x:0>4} : {{
        \\        KEEP(*(.data*))
        \\        KEEP(*(.rodata*))
        \\    }} > DMEM
        \\
        \\    .bss (NOLOAD) : SUBALIGN(1) {{
        \\        *(.bss*)
        \\    }} > DMEM
        \\
        \\    .state (NOLOAD) : SUBALIGN(1) {{
        \\        KEEP(*(.state*))
        \\    }} > DMEM
        \\
        \\    .text 0x{x:0>4} : {{
        \\        *(.text*)
        \\    }} > IMEM
        \\
        \\    .zsp_commands 0 : {{
        \\        KEEP(*(.zsp_commands))
        \\    }}
        \\
        \\    /DISCARD/ : {{
        \\        *(.MIPS.abiflags)
        \\        *(.got*)
        \\    }}
        \\}}
        \\
    , .{
        overlay_dmem_start,
        0x1000 - overlay_dmem_start,
        text_start,
        imem_end - text_start,
        overlay_dmem_start,
        text_start,
    });
}

test "overlay text follows aligned resident text" {
    var rsp = [_]u8{0} ** rsp_header_len;
    std.mem.writeInt(u16, rsp[0..2], 0x01a8, .big);
    try std.testing.expectEqual(@as(u16, 0x11b0), try overlayTextStart(&rsp));
}
