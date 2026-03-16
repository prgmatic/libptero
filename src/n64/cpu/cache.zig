const io = @import("../io.zig");
// Cache ops described in VR4300 manual on page 404.
const CacheOp = enum(u8) {
    IndexInvalidate,
    IndexLoadTag,
    IndexStoreTag,
    IndecCreateDirty,
    HitInvalidate,
    HitWritebackInvalidate,
    HitWriteback
};

const CacheType = enum(u8) {
    Instruction,
    Data
};

const instruction_cache_size = 16 * 1024;
const instruction_cache_linesize = 32;
const data_cache_size = 8 * 1024;
const data_cache_linesize = 16;

inline fn cacheOp(op: CacheOp, cache_type: CacheType, addr: u32, length: usize) void {
    const line_size: u32 = if(cache_type == .Instruction) instruction_cache_linesize else data_cache_linesize;
    const op_code = (@intFromEnum(op) << 2) | @intFromEnum(cache_type);
    
    var currentAddr = addr;
    const targetAddr = addr + length;
    while (currentAddr <= targetAddr) : (currentAddr += line_size) {
        asm volatile (
            \\ cache %[op], 0(%[addr])
            :
            : [op] "i" (op_code),
              [addr] "r" (currentAddr),
            : .{ .memory = true }
        );
    }
}

pub fn clear() void {
    invadidateDataAll();
    invadidateInstAll();
}

pub fn invalidateData(data: anytype) void {
    const len = @sizeOf(@TypeOf(data.*));
    cacheOp(.HitInvalidate, .Data, @intFromPtr(data), len);
}

pub fn invalidateDataRange(addr: u32, len: u32) void {
    cacheOp(.HitInvalidate, .Data, addr, len);
}
pub fn invadidateDataAll() void {
    cacheOp(.IndexInvalidate, .Data, io.kseg0_addr, 0x2000);
}
pub fn writebackData(data: anytype) void {
    const len = @sizeOf(@TypeOf(data.*));
    cacheOp(.HitWriteback, .Data, @intFromPtr(data), len);
}
pub fn writebackDataRange(addr: u32, len: u32) void {
    cacheOp(.HitWriteback, .Data, addr, len);
}
pub fn writebackDataAll() void {
    cacheOp(.HitWriteback, .Data, io.kseg0_addr, 0x2000);
}


pub fn invalidateInstRange(addr: u32, len: u32) void {
    cacheOp(.HitWriteback, .Instruction, addr, len);
}
pub fn invadidateInstAll() void {
    cacheOp(.IndexInvalidate, .Instruction, io.kseg0_addr, 0x4000);
}
pub fn writebackInstRange(addr: u32, len: u32) void {
    cacheOp(.HitWriteback, .Instruction, addr, len);
}
pub fn writebackInstAll() void {
    cacheOp(.HitWriteback, .Data, io.kseg0_addr, 0x4000);
}
