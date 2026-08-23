pub const magic = "NSRC";

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

    pub fn encode(self: SourceLineInfo) u64 {
        return (@as(u64, self.line) << 48) |
            (@as(u64, self.func_name_offset) << 28) |
            @as(u64, self.file_name_offset);
    }

    pub fn decode(word: u64) SourceLineInfo {
        return .{
            .line = @truncate(word >> 48),
            .func_name_offset = @truncate(word >> 28),
            .file_name_offset = @truncate(word),
        };
    }
};

pub const AddrInfo = packed struct(u64) {
    start_addr: u24,
    column: u16,
    source_line_offset: u24,

    pub fn compare(_: void, lhs: AddrInfo, rhs: AddrInfo) bool {
        return lhs.start_addr < rhs.start_addr;
    }

    pub fn encode(self: AddrInfo) u64 {
        return (@as(u64, self.start_addr) << 40) |
            (@as(u64, self.column) << 24) |
            @as(u64, self.source_line_offset);
    }

    pub fn decode(word: u64) AddrInfo {
        return .{
            .start_addr = @truncate(word >> 40),
            .column = @truncate(word >> 24),
            .source_line_offset = @truncate(word),
        };
    }
};
