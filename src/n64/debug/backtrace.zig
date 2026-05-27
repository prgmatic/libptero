const debug = @import("../debug.zig");
const srcmap = @import("srcmap.zig");

pub const max_depth = 20;

extern const __text_start: u8;
extern const __text_end: u8;

fn isAlignedWord(addr: u32) bool {
    return addr & 3 == 0;
}

fn isValidCodeAddr(addr: u32) bool {
    const start: u32 = @truncate(@intFromPtr(&__text_start));
    const end: u32 = @truncate(@intFromPtr(&__text_end));
    return addr >= start and addr < end and isAlignedWord(addr);
}

fn isValidStackSlot(addr: u32) bool {
    return addr >= 0x80000000 and addr <= 0x807ffffc and isAlignedWord(addr);
}

fn readSavedRa(sp: u32, offset: u32) ?u32 {
    const addr = sp +% offset;
    if (!isValidStackSlot(addr)) return null;
    return @as(*const u32, @ptrFromInt(addr)).*;
}

const Frame = struct {
    stack_size: u32,
    ra_offset: u32, // byte offset from sp to saved 32-bit return address
};

fn findFrame(addr: u32) ?Frame {
    const info = srcmap.getUnwindInfo(addr) orelse return null;
    return .{
        .stack_size = info.stack_size,
        .ra_offset = info.ra_offset,
    };
}

/// Walk the call stack and print resolved source locations to the debug console.
///
/// `skip` is the number of caller frames to omit, in addition to this function's
/// own frame. Pass 1 from a panic handler so frame #0 is the panic call site.
///
/// This uses the compact unwind table generated from the debug ELF.
pub noinline fn printBacktrace(skip: u32) void {
    const trace = capture(skip + 1) orelse {
        debug.writeStr("  <backtrace unavailable>\n");
        return;
    };
    printTrace(trace);
}

pub const Entry = struct {
    depth: u32,
    addr: u32,
};

pub const Trace = struct {
    sp: u32,
    ra: u32,
    fallback_ra: ?u32 = null,
    depth: u32 = 0,

    pub fn next(trace: *Trace) ?Entry {
        if (trace.depth >= max_depth) return null;
        if (!isValidCodeAddr(trace.ra)) return null;

        const entry: Entry = .{
            .depth = trace.depth,
            .addr = trace.ra,
        };
        trace.depth += 1;
        _ = trace.advance();
        return entry;
    }

    pub fn skip(trace: *Trace, count: u32) bool {
        var remaining = count;
        while (remaining > 0) : (remaining -= 1) {
            if (!isValidCodeAddr(trace.ra)) return false;
            if (!trace.advance()) return false;
        }
        return true;
    }

    fn advance(trace: *Trace) bool {
        const frame = findFrame(trace.ra) orelse {
            trace.ra = 0;
            return false;
        };
        const saved_ra = readSavedRa(trace.sp, frame.ra_offset) orelse blk: {
            const fallback = trace.fallback_ra orelse {
                trace.ra = 0;
                return false;
            };
            break :blk fallback;
        };
        trace.fallback_ra = null;
        trace.sp +%= frame.stack_size;
        trace.ra = saved_ra -% 4;
        return true;
    }
};

/// Capture the current call stack as an address iterator.
///
/// `skip` is the number of caller frames to omit, in addition to this function's
/// own frame. The returned `Trace` is consumed by calls to `next`.
pub noinline fn capture(skip: u32) ?Trace {
    var sp: u32 = undefined;
    var ra: u32 = undefined;
    asm volatile (
        \\move %[sp], $sp
        \\move %[ra], $ra
        : [sp] "=r" (sp),
          [ra] "=r" (ra),
    );

    const self_pc: u32 = @truncate(@intFromPtr(&capture) + 24);
    const my_frame = findFrame(self_pc) orelse return null;
    sp +%= my_frame.stack_size;

    var trace: Trace = .{
        .sp = sp,
        .ra = ra,
    };
    if (!trace.skip(skip)) return null;
    return trace;
}

pub fn captureFrom(pc: u32, frame_sp: u32, frame_ra: u32) Trace {
    return .{
        .sp = frame_sp,
        .ra = pc,
        .fallback_ra = frame_ra,
    };
}

/// Print a captured trace.
pub fn printTrace(trace: Trace) void {
    var iter = trace;
    while (iter.next()) |entry| {
        if (!srcmap.printLineInfo(entry.depth, entry.addr)) {
            debug.print("  #{d}: 0x{x:0>8}\n", .{ entry.depth, entry.addr });
        }
    }
}

pub fn printBacktraceFrom(pc: u32, frame_sp: u32, frame_ra: u32) void {
    const trace = captureFrom(pc, frame_sp, frame_ra);
    printTrace(trace);
}
