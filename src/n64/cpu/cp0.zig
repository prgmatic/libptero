const std = @import("std");

fn comptimePrint(comptime x: u8) []const u8 {
    return std.fmt.comptimePrint("{}", .{x});
}

pub const Cp0Reg = enum(u8) {
    /// Index into the TLB array (entry index register)
    Index = 0,

    /// Randomly generated index into the TLB array (randomized access register)
    Random = 1,

    /// Low-order portion of the current TLB entry for even-number virtual pages
    EntryLo0 = 2,

    /// Low-order portion of the current TLB entry for odd-number virtual pages
    EntryLo1 = 3,

    /// Pointer to page-table entry in memory / lookup address
    Context = 4,

    /// Control for variable page size in TLB entries
    PageMask = 5,

    /// Controls the number of fixed TLB entries
    Wired = 6,

    /// Stores virtual address for the most recent address-related exception
    BadVAddr = 8,

    /// Increments every time an opcode is processed (processor cycle count)
    Count = 9,

    /// High-order portion of the current TLB entry
    EntryHi = 10,

    /// Timer interrupt control (interrupt when Count == Compare)
    Compare = 11,

    /// Process status register / used for exception handling
    Status = 12,

    /// Exception cause register (type of last exception)
    Cause = 13,

    /// Exception Program Counter:
    /// address of instruction that caused the exception,
    /// and where execution resumes afterward
    EPC = 14,

    /// Processor identification and revision
    PRId = 15,

    /// Configuration register
    Config = 16,

    /// Load-linked address (used by atomic LL/SC)
    LLAddr = 17,

    /// Watchpoint address
    WatchLo = 18,

    /// Watchpoint control
    WatchHi = 19,

    /// Context register for R4300i addressing / PTE array related
    XContext = 20,

    /// Cache parity error control and status
    CacheErr = 27,

    /// Low-order portion of cache tag interface
    TagLo = 28,

    /// High-order portion of cache tag interface (reserved on R4300i)
    TagHi = 29,

    /// Error Exception Program Counter
    ErrorEPC = 30,
};

pub fn init() void {
    regWrite(.Cause, 0);
    regWrite(.Count, 0);
    regWrite(.Compare, 0);
    regWrite(.WatchLo, 0);
}

pub inline fn regWrite(comptime reg: Cp0Reg, value: u32) void {
    asm volatile (
        "mtc0 %[val], $" ++ comptimePrint(@intFromEnum(reg))
        :
        : [val] "r"(value)
    );
}

pub inline fn regRead(comptime reg: Cp0Reg) u32 {
    var out: u32 = undefined;
    asm volatile (
        "mfc0 %[out], $" ++ comptimePrint(@intFromEnum(reg))
        : [out] "=r"(out)
        :
    );
    return out;
}
