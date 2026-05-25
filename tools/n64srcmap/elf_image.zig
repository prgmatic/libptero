const std = @import("std");

pub const FuncRange = struct {
    start: u32,
    end: u32,

    pub fn fromDwarf(range: anytype) ?FuncRange {
        if (range.start < 0x80000000) return null;
        if (range.end <= range.start) return null;
        return .{
            .start = @truncate(range.start),
            .end = @truncate(range.end),
        };
    }

    pub fn lessThan(_: void, lhs: FuncRange, rhs: FuncRange) bool {
        return lhs.start < rhs.start;
    }
};

pub const FrameInfo = struct {
    stack_size: u16,
    ra_offset: u16,
};

pub fn analyzeFrame(elf: []const u8, range: FuncRange) ?FrameInfo {
    var stack_size: ?u16 = null;
    var ra_offset: ?u16 = null;

    var addr = range.start;
    while (addr < range.end and addr - range.start < 256) : (addr += 4) {
        const op = readWordAtVaddr(elf, addr) catch return null;
        if (isStackPointerAdjust(op)) {
            const imm: i16 = @bitCast(@as(u16, @truncate(op)));
            if (imm < 0) {
                const size: u32 = @intCast(-@as(i32, imm));
                if (size > std.math.maxInt(u16)) return null;
                stack_size = @intCast(size);
            }
        } else if (isSaveRa32(op)) {
            const imm: i16 = @bitCast(@as(u16, @truncate(op)));
            if (imm < 0) return null;
            ra_offset = @intCast(@as(u32, @intCast(imm)));
        } else if (isSaveRa64(op)) {
            const imm: i16 = @bitCast(@as(u16, @truncate(op)));
            const adjusted: i32 = @as(i32, imm) + 4;
            if (adjusted < 0 or adjusted > std.math.maxInt(u16)) return null;
            ra_offset = @intCast(adjusted);
        }

        if (stack_size != null and ra_offset != null) {
            return .{
                .stack_size = stack_size.?,
                .ra_offset = ra_offset.?,
            };
        }
    }

    return null;
}

pub fn readAll(io: std.Io, alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    var buf: [4096]u8 = undefined;
    var r = f.reader(io, &buf);
    return r.interface.allocRemaining(alloc, .unlimited);
}

fn isStackPointerAdjust(op: u32) bool {
    return (op & 0xFFFF_0000) == 0x27BD_0000 or
        (op & 0xFFFF_0000) == 0x67BD_0000;
}

fn isSaveRa32(op: u32) bool {
    return (op & 0xFFFF_0000) == 0xAFBF_0000;
}

fn isSaveRa64(op: u32) bool {
    return (op & 0xFFFF_0000) == 0xFFBF_0000;
}

fn readWordAtVaddr(elf: []const u8, vaddr: u32) !u32 {
    const off = try vaddrToOffset(elf, vaddr);
    if (off + 4 > elf.len) return error.BadElf;
    return std.mem.readInt(u32, elf[off..][0..4], .big);
}

fn vaddrToOffset(elf: []const u8, vaddr: u32) !usize {
    if (elf.len < 52) return error.BadElf;
    const phoff = readInt(u32, elf, 28);
    const phent = readInt(u16, elf, 42);
    const phnum = readInt(u16, elf, 44);
    if (phent < 32) return error.BadElf;

    for (0..phnum) |i| {
        const ph = @as(usize, phoff) + i * phent;
        if (ph + 32 > elf.len) return error.BadElf;
        if (readInt(u32, elf, ph + 0) != 1) continue;
        const seg_off = readInt(u32, elf, ph + 4);
        const seg_vaddr = readInt(u32, elf, ph + 8);
        const seg_filesz = readInt(u32, elf, ph + 16);
        if (vaddr >= seg_vaddr and vaddr < seg_vaddr + seg_filesz) {
            return @as(usize, seg_off) + (vaddr - seg_vaddr);
        }
    }

    return error.NotMapped;
}

fn readInt(comptime T: type, bytes: []const u8, offset: usize) T {
    return std.mem.readInt(T, bytes[offset..][0..@sizeOf(T)], .big);
}
