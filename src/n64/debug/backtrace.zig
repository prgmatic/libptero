const debug = @import("../debug.zig");
const srcmap = @import("srcmap.zig");

const max_depth = 20;
const max_scan = 4096;

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

/// Scan backward from `addr` to find the enclosing function's prologue.
/// Returns the frame size and where RA was saved.
fn analyzeFrame(addr: u32) ?Frame {
    var a = addr;
    var stack_size: u32 = 0;
    var ra_offset: u32 = 0;
    var found_ra = false;

    var i: u32 = 0;
    while (i < max_scan) : (i += 1) {
        if (!isValidCodeAddr(a)) return null;
        const op: u32 = @as(*const u32, @ptrFromInt(a)).*;

        if ((op & 0xFFFF_0000) == 0x27BD_0000 or // addiu sp, sp, imm
            (op & 0xFFFF_0000) == 0x67BD_0000) // daddiu sp, sp, imm
        {
            const imm: i16 = @bitCast(@as(u16, @truncate(op)));
            if (imm < 0) {
                stack_size = @intCast(-@as(i32, imm));
                if (found_ra) break;
            }
        } else if ((op & 0xFFFF_0000) == 0xAFBF_0000) {
            // sw ra, imm(sp) - 32-bit save (O32 ABI)
            const imm: i16 = @bitCast(@as(u16, @truncate(op)));
            if (imm < 0) return null; // unexpected negative offset
            ra_offset = @intCast(@as(i32, imm));
            found_ra = true;
            stack_size = 0; // discard any addiu sp seen before sw ra (epilogue / alloca)
        } else if ((op & 0xFFFF_0000) == 0xFFBF_0000) {
            // sd ra, imm(sp) - low 32 bits at imm+4 on big-endian MIPS.
            const imm: i16 = @bitCast(@as(u16, @truncate(op)));
            const adjusted: i32 = @as(i32, imm) + 4;
            if (adjusted < 0) return null;
            ra_offset = @intCast(adjusted);
            found_ra = true;
            stack_size = 0;
        } else if ((op & 0xFFFF_0000) == 0x3C1C_0000) {
            // lui gp, imm - marks entry of _start; stop scanning.
            return null;
        }

        if (a < 4) return null;
        a -= 4;
    }

    if (!found_ra or stack_size == 0) return null;
    return .{ .stack_size = stack_size, .ra_offset = ra_offset };
}

/// Walk the call stack and print resolved source locations to the debug console.
///
/// `skip` is the number of caller frames to omit, in addition to this function's
/// own frame. Pass 1 from a panic handler so frame #0 is the panic call site.
///
/// This uses a prologue-scanning stack walk because FullPanic's return address
/// argument is unreliable on this target.
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
    const my_frame = analyzeFrame(self_pc) orelse {
        debug.print("  <backtrace unavailable>\n", .{});
        return;
    };
    sp +%= my_frame.stack_size;

    var to_skip: u32 = skip;
    while (to_skip > 0) : (to_skip -= 1) {
        const frame = analyzeFrame(ra) orelse {
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

        if (srcmap.getLineInfo(ra)) |info| {
            debug.print("  #{d}: 0x{x:0>8} {s} ({s}:{d}:{d})\n", .{
                depth, ra, info.func_name, info.file_name, info.line, info.column,
            });
            if (info.line_text.len > 0)
                debug.print("        {s}\n", .{info.line_text});
        } else {
            debug.print("  #{d}: 0x{x:0>8}\n", .{ depth, ra });
        }

        const frame = analyzeFrame(ra) orelse {
            break;
        };
        const saved_ra = readSavedRa(sp, frame.ra_offset) orelse break;
        ra = saved_ra -% 4;
        sp +%= frame.stack_size;
    }
}
