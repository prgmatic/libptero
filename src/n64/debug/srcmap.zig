const std = @import("std");
const debug = @import("../debug.zig");
const pi = @import("../interfaces/parallel.zig");

const magic = "NSRC";
const magic_word: u32 = 0x4e535243;
const elf_magic_word: u32 = 0x7f454c46;
const rom_kseg1_base: u32 = 0xb0000000;
const elf_search_start: u32 = 0x1000;
const elf_search_step: u32 = 0x100;
const elf_search_limit: u32 = 1024 * 1024;

export var __srcmap_rom_offset: u32 = 0xffffffff;
export var __srcmap_rom_size: u32 = 0xffffffff;

var elf_rom_offset: u32 = 0xffffffff;

var func_name_buf: [128]u8 align(8) = undefined;
var file_name_buf: [192]u8 align(8) = undefined;
var line_text_buf: [256]u8 align(8) = undefined;

pub const LineInfoBuffers = struct {
    func_name: []u8,
    file_name: []u8,
    line_text: []u8,
};

pub const LineInfo = struct {
    function_name: ?[]const u8,
    file_name: ?[]const u8,
    line_text: ?[]const u8,
    line: u16,
    column: u16,
};

pub fn getLineInfo(addr: u32, buffers: LineInfoBuffers) ?LineInfo {
    const header = readHeader() orelse return null;
    if (header.entry_count == 0) return null;
    if (!header.isValid()) return null;

    const target: u24 = @truncate(addr);

    var lo: u32 = 0;
    var hi: u32 = header.entry_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_entry = readAddrInfo(mid) orelse return null;
        if (mid_entry.start_addr < target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    const idx: u32 = if (lo < header.entry_count) blk: {
        const entry = readAddrInfo(lo) orelse return null;
        if (entry.start_addr == target) break :blk lo;
        if (lo > 0) break :blk lo - 1;
        return null;
    } else if (lo > 0) lo - 1 else return null;

    const entry = readAddrInfo(idx) orelse return null;
    const sli_offset = header.line_blob_offset + entry.source_line_offset;
    const sli = readSourceLineInfo(sli_offset) orelse return null;

    const line_text = readRomString(sli_offset + @sizeOf(SourceLineInfo), buffers.line_text);
    return .{
        .function_name = readRomString(header.func_blob_offset + sli.func_name_offset, buffers.func_name),
        .file_name = readRomString(header.file_blob_offset + sli.file_name_offset, buffers.file_name),
        .line_text = if (line_text != null and line_text.?.len > 0) line_text else null,
        .line = sli.line,
        .column = entry.column,
    };
}

pub fn printLineInfo(depth: u32, addr: u32) bool {
    const info = getLineInfo(addr, .{
        .func_name = &func_name_buf,
        .file_name = &file_name_buf,
        .line_text = &line_text_buf,
    }) orelse return false;

    debug.print(" #{d}: 0x{x:0>8} ", .{ depth, addr });
    if (info.function_name) |func_name| {
        debug.writeStr(func_name);
        debug.writeStr(" ");
    }
    if (info.file_name) |file_name| {
        debug.writeStr(file_name);
    }
    debug.print(":{d}:{d}\n", .{ info.line, info.column });
    if (info.line_text) |line_text| {
        debug.writeStr("  ");
        debug.writeStr(line_text);
        debug.writeStr("\n");
        for (0..info.column + 1) |_| {
            debug.writeStr(" ");
        }
        debug.writeStr("^\n");
    }
    return true;
}

pub fn getUnwindInfo(addr: u32) ?UnwindInfo {
    const header = readHeader() orelse return null;
    if (header.unwind_count == 0) return null;
    if (!header.isValid()) return null;

    var lo: u32 = 0;
    var hi: u32 = header.unwind_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const mid_entry = readUnwindInfo(header, mid) orelse return null;
        if (mid_entry.start_addr <= addr) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }

    if (lo == 0) return null;
    const entry = readUnwindInfo(header, lo - 1) orelse return null;
    if (addr >= entry.start_addr and addr < entry.end_addr) return entry;
    return null;
}

pub const Header = extern struct {
    magic: [4]u8,
    entry_count: u32,
    unwind_count: u32,
    unwind_offset: u32,
    func_blob_offset: u32,
    func_blob_size: u32,
    file_blob_offset: u32,
    file_blob_size: u32,
    line_blob_offset: u32,
    line_blob_size: u32,

    fn isValid(header: Header) bool {
        const entry_bytes = @as(usize, header.entry_count) * @sizeOf(AddrInfo);
        const unwind_bytes = @as(usize, header.unwind_count) * @sizeOf(UnwindInfo);
        if (header.unwind_offset != @sizeOf(Header) + entry_bytes) return false;
        if (header.func_blob_offset != header.unwind_offset + unwind_bytes) return false;
        if (header.func_blob_size == 0 or header.file_blob_size == 0 or header.line_blob_size == 0) return false;
        const func_end = header.func_blob_offset +% header.func_blob_size;
        const file_end = header.file_blob_offset +% header.file_blob_size;
        if (func_end < header.func_blob_offset or file_end < header.file_blob_offset) return false;
        if (header.file_blob_offset < func_end) return false;
        if (header.line_blob_offset < file_end) return false;
        return rangeInSrcmap(header.line_blob_offset, header.line_blob_size);
    }
};

pub const UnwindInfo = extern struct {
    start_addr: u32,
    end_addr: u32,
    stack_size: u16,
    ra_offset: u16,

    pub fn compare(_: void, lhs: UnwindInfo, rhs: UnwindInfo) bool {
        return lhs.start_addr < rhs.start_addr;
    }
};

pub const SourceLineInfo = packed struct(u64) {
    line: u16,
    func_name_offset: u20,
    file_name_offset: u28,
};

pub const AddrInfo = packed struct(u64) {
    start_addr: u24,
    column: u16,
    source_line_offset: u24,

    pub fn compare(_: void, lhs: AddrInfo, rhs: AddrInfo) bool {
        return lhs.start_addr < rhs.start_addr;
    }
};

fn readHeader() ?Header {
    if (__srcmap_rom_offset == 0xffffffff or __srcmap_rom_size < @sizeOf(Header)) return null;
    _ = findElfRomOffset() orelse return null;
    if (readRomU32(0) != magic_word) return null;
    return .{
        .magic = magic.*,
        .entry_count = readRomU32(4),
        .unwind_count = readRomU32(8),
        .unwind_offset = readRomU32(12),
        .func_blob_offset = readRomU32(16),
        .func_blob_size = readRomU32(20),
        .file_blob_offset = readRomU32(24),
        .file_blob_size = readRomU32(28),
        .line_blob_offset = readRomU32(32),
        .line_blob_size = readRomU32(36),
    };
}

fn readAddrInfo(index: u32) ?AddrInfo {
    const offset = @sizeOf(Header) + index * @sizeOf(AddrInfo);
    if (!rangeInSrcmap(offset, @sizeOf(AddrInfo))) return null;
    const word = readRomU64(offset);
    return .{
        .start_addr = @truncate(word >> 40),
        .column = @truncate(word >> 24),
        .source_line_offset = @truncate(word),
    };
}

fn readSourceLineInfo(offset: u32) ?SourceLineInfo {
    if (!rangeInSrcmap(offset, @sizeOf(SourceLineInfo))) return null;
    const word = readRomU64(offset);
    return .{
        .line = @truncate(word >> 48),
        .func_name_offset = @truncate(word >> 28),
        .file_name_offset = @truncate(word),
    };
}

fn readUnwindInfo(header: Header, index: u32) ?UnwindInfo {
    const offset = header.unwind_offset + index * @sizeOf(UnwindInfo);
    if (!rangeInSrcmap(offset, @sizeOf(UnwindInfo))) return null;
    const stack_ra = readRomU32(offset + 8);
    return .{
        .start_addr = readRomU32(offset),
        .end_addr = readRomU32(offset + 4),
        .stack_size = @truncate(stack_ra >> 16),
        .ra_offset = @truncate(stack_ra),
    };
}

fn readRomString(offset: u32, buf: []u8) ?[]const u8 {
    if (buf.len == 0 or offset >= __srcmap_rom_size) return null;
    const max_len: u32 = @intCast(buf.len - 1);
    const len = findRomStringLen(offset, max_len) orelse return null;
    copyRomBytes(offset, buf[0 .. len + 1]);
    buf[len] = 0;
    return buf[0..len];
}

fn findRomStringLen(offset: u32, max_len: u32) ?usize {
    var pos: u32 = 0;
    while (pos <= max_len and offset + pos < __srcmap_rom_size) {
        const word_offset = offset + pos;
        const word = readRomU32(word_offset & ~@as(u32, 3));
        const start_byte = word_offset & 3;
        var i: u32 = start_byte;
        while (i < 4 and pos + (i - start_byte) <= max_len) : (i += 1) {
            const shift: u5 = @intCast((3 - i) * 8);
            if (((word >> shift) & 0xff) == 0)
                return pos + (i - start_byte);
        }
        pos += 4 - start_byte;
    }
    return max_len;
}

fn readRomU64(offset: u32) u64 {
    return (@as(u64, readRomU32(offset)) << 32) | readRomU32(offset + 4);
}

fn readRomU32(offset: u32) u32 {
    const addr = romKseg1Addr(offset & ~@as(u32, 3));
    return readKseg1U32(addr);
}

fn copyRomBytes(offset: u32, dst: []u8) void {
    var copied: usize = 0;
    while (copied < dst.len) {
        const current_offset: u32 = offset + @as(u32, @intCast(copied));
        const word = readRomU32(current_offset & ~@as(u32, 3));
        var byte_index = current_offset & 3;
        while (byte_index < 4 and copied < dst.len) : (byte_index += 1) {
            const shift: u5 = @intCast((3 - byte_index) * 8);
            dst[copied] = @truncate(word >> shift);
            copied += 1;
        }
    }
}

fn romKseg1Addr(offset: u32) u32 {
    return rom_kseg1_base + (findElfRomOffset() orelse 0) + __srcmap_rom_offset + offset;
}

fn rangeInSrcmap(offset: u32, len: u32) bool {
    return offset <= __srcmap_rom_size and len <= __srcmap_rom_size - offset;
}

fn findElfRomOffset() ?u32 {
    if (elf_rom_offset != 0xffffffff) return elf_rom_offset;

    var offset: u32 = elf_search_start;
    while (offset < elf_search_limit) : (offset += elf_search_step) {
        if (readKseg1U32(rom_kseg1_base + offset) == elf_magic_word) {
            elf_rom_offset = offset;
            return offset;
        }
    }

    return null;
}

fn readKseg1U32(addr: u32) u32 {
    const value = @as(*const volatile u32, @ptrFromInt(addr)).*;
    pi.waitIo();
    return value;
}
