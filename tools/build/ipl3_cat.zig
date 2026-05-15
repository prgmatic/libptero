const std = @import("std");

// This program takes an ipl3 binary and an elf file
// and tapes then together. It will also do some Alignment
// That's it, simple program

// Alignment of payload after header
const payload_alignment = 256;
// Make final size of rom a multiple of 16kb
const rom_padding = 1024 * 16; 

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    const io = init.io;

    const ipl3_path   = args[1];
    const elf_path    = args[2];
    const result_path = args[3];

    var readBuffer: [std.heap.pageSize()]u8 = undefined;
    var writeBuffer: [std.heap.pageSize()]u8 = undefined;

    var result_file = try std.Io.Dir.cwd().createFile(io, result_path, .{});
    defer result_file.close(io);
    var writer = result_file.writer(io, &writeBuffer);
    var out = &writer.interface;

    // Write ipl3
    var ipl3_file = try std.Io.Dir.cwd().openFile(io, ipl3_path, .{});
    defer ipl3_file.close(io);
    var reader = ipl3_file.reader(io, &readBuffer);
    _ = try out.sendFileAll(&reader, .unlimited);
    try out.flush();

    // Paylaod Align
    try pad(&writer, payload_alignment);

    // Write Elf
    var elf_file = try std.Io.Dir.cwd().openFile(io, elf_path, .{});
    defer elf_file.close(io);
    reader = elf_file.reader(io, &readBuffer);
    _ = try out.sendFileAll(&reader, .unlimited);
    try out.flush();

    // Finall Pad
    try pad(&writer, rom_padding);
}


fn pad(w: *std.Io.File.Writer, alignment: usize) !void {
    const padding = alignment - @mod(w.pos, alignment);
    try w.interface.splatByteAll(0, padding);
}
