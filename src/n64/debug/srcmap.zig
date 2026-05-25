const std = @import("std");
extern const __srcmap_start: u8;
const magic = "NSRC";

pub fn getLineInfo(addr: u32) ?LineInfoAtAddr {
    const base = @intFromPtr(&__srcmap_start);
    const header: *const Header = @ptrFromInt(base);
    if (!std.mem.eql(u8, &header.magic, magic)) return null;
    if (header.entry_count == 0) return null;
    if (!header.isValid()) return null;

    const entries: [*]const AddrInfo = @ptrFromInt(base + @sizeOf(Header));
    const target: u24 = @truncate(addr);

    // Binary search for the last entry with start_addr <= target.
    var lo: u32 = 0;
    var hi: u32 = header.entry_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (entries[mid].start_addr < target) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    // lo is the first index where start_addr >= target.
    const idx: u32 = if (lo < header.entry_count and entries[lo].start_addr == target)
        lo
    else if (lo > 0)
        lo - 1
    else
        return null;

    const entry = entries[idx];
    const sli: *const SourceLineInfo = @ptrFromInt(base + header.line_blob_offset + entry.source_line_offset);
    const str_ptr: [*]const u8 = @ptrFromInt(base + header.line_blob_offset + entry.source_line_offset + @sizeOf(SourceLineInfo));
    const func_ptr: [*]const u8 = @ptrFromInt(base + header.func_blob_offset + sli.func_name_offset);
    const file_ptr: [*]const u8 = @ptrFromInt(base + header.file_blob_offset + sli.file_name_offset);

    return .{
        .line = sli.line,
        .column = entry.column,
        .func_name = std.mem.sliceTo(func_ptr, 0),
        .file_name = std.mem.sliceTo(file_ptr, 0),
        .line_text = std.mem.sliceTo(str_ptr, 0),
    };
}

pub const LineInfoAtAddr = struct {
    line: u16,
    column: u16,
    func_name: []const u8,
    file_name: []const u8,
    line_text: []const u8,
};

pub const Header = extern struct {
    magic: [4]u8,
    entry_count: u32,
    func_blob_offset: u32,
    func_blob_size: u32,
    file_blob_offset: u32,
    file_blob_size: u32,
    line_blob_offset: u32,
    line_blob_size: u32,

    fn isValid(header: Header) bool {
        const entry_bytes = @as(usize, header.entry_count) * @sizeOf(AddrInfo);
        if (header.func_blob_offset != @sizeOf(Header) + entry_bytes) return false;
        if (header.func_blob_size == 0 or header.file_blob_size == 0 or header.line_blob_size == 0) return false;
        const func_end = header.func_blob_offset +% header.func_blob_size;
        const file_end = header.file_blob_offset +% header.file_blob_size;
        if (func_end < header.func_blob_offset or file_end < header.file_blob_offset) return false;
        if (header.file_blob_offset < func_end) return false;
        if (header.line_blob_offset < file_end) return false;
        return true;
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
