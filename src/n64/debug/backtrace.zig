const debug = @import("../debug.zig");
const srcmap = @import("srcmap.zig");

const max_depth = 20;

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
    var sp: u32 = undefined;
    var ra: u32 = undefined;
    asm volatile (
        \\move %[sp], $sp
        \\move %[ra], $ra
        : [sp] "=r" (sp),
          [ra] "=r" (ra),
    );

    const self_pc: u32 = @truncate(@intFromPtr(&printBacktrace) + 24);
    const my_frame = findFrame(self_pc) orelse {
        debug.writeStr("  <backtrace unavailable>\n");
        return;
    };
    sp +%= my_frame.stack_size;

    var to_skip: u32 = skip;
    while (to_skip > 0) : (to_skip -= 1) {
        const frame = findFrame(ra) orelse {
            debug.print("  <backtrace stopped at 0x{x:0>8}>\n", .{ra});
            return;
        };
        const saved_ra = readSavedRa(sp, frame.ra_offset) orelse {
            debug.print("  <invalid stack while skipping frames>\n", .{});
            return;
        };
        ra = saved_ra -% 4;
        sp +%= frame.stack_size;
    }

    var depth: u32 = 0;
    while (depth < max_depth) : (depth += 1) {
        if (!isValidCodeAddr(ra)) break;

        if (!srcmap.printLineInfo(depth, ra)) {
            debug.print("  #{d}: 0x{x:0>8}\n", .{ depth, ra });
        }

        const frame = findFrame(ra) orelse {
            break;
        };
        const saved_ra = readSavedRa(sp, frame.ra_offset) orelse break;
        ra = saved_ra -% 4;
        sp +%= frame.stack_size;
    }
}

pub fn printBacktraceFrom(pc: u32, frame_sp: u32, frame_ra: u32) void {
    var sp = frame_sp;
    var ra = pc;

    var depth: u32 = 0;
    while (depth < max_depth) : (depth += 1) {
        if (!isValidCodeAddr(ra)) break;

        if (!srcmap.printLineInfo(depth, ra)) {
            debug.print("  #{d}: 0x{x:0>8}\n", .{ depth, ra });
        }

        const frame = findFrame(ra) orelse break;
        const saved_ra = if (depth == 0)
            frame_ra
        else
            readSavedRa(sp, frame.ra_offset) orelse break;
        sp +%= frame.stack_size;
        ra = saved_ra -% 4;
    }
}
