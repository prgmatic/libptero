const n64 = @import("n64");
const pi = n64.interfaces.parallel;

pub fn init() void {
    n64.debug.init();
}


// For printing from ipl3 when in DMEM. DMEM can only do 32 bit writes.
pub fn dmemPrint(fmt: []const u8, args: []const u32) void {
    switch (n64.debug.current_backend) {
        .IsViewer => {
            const s = dmemFormat(n64.debug.is_viewer.buffer, fmt, args);
            n64.debug.is_viewer.flushBuffer(s.len * 4);
        },
        .Sc64 => {
            @memset(n64.debug.sc64.data_buffer, 0);
            const s = dmemFormat(n64.debug.sc64.data_buffer, fmt, args);
            n64.debug.sc64.flushBuffer(s.len * 4);
        },
        
        else => {},
    }
}

fn dmemFormat(buffer: []u32, fmt: []const u8, args: []const u32) []u32 {
    var buf_index: usize = 0;

    // Write string in 4-byte aligned chunks, pad with spaces if needed
    for (0..fmt.len) |i| {
        if (i % 4 == 0) {
            var chunk: u32 = 0;
            for (0..4) |j| {
                const idx = i + j;
                const c: u32 = if (idx < fmt.len) @intCast(fmt[idx]) else 0x20; // pad with space
                chunk |= c << @intCast((3 - j) * 8);
            }
            
            pi.waitIo();
            buffer[buf_index] = chunk;
            buf_index += 1;
        }
    }

    // Iterate over args tuple
    for (args, 0..args.len) |x, arg_idx| {
        const val: u32 = x;
        var hex_high: u32 = 0;
        var hex_low: u32 = 0;

        for (0..4) |i| {
            const shift = 28 - i * 4;
            const nibble = (val >> @intCast(shift)) & 0xF;
            const c = if (nibble < 10) '0' + nibble else 'A' + (nibble - 10);
            hex_high |= c << @intCast((3 - i) * 8); // pack into 4 bytes
        }

        for (0..4) |i| {
            const shift = 12 - i * 4;
            const nibble = (val >> @intCast(shift)) & 0xF;
            const c = if (nibble < 10) '0' + nibble else 'A' + (nibble - 10);
            hex_low |= c << @intCast((3 - i) * 8); // pack into 4 bytes
        }

        pi.waitIo();
        buffer[buf_index] = hex_high;
        buf_index += 1;
        pi.waitIo();
        buffer[buf_index] = hex_low;
        buf_index += 1;

        if (arg_idx < args.len - 1) {
            pi.waitIo();
            buffer[buf_index] = 0x20202020; // space separator
            buf_index += 1;
        }
    }

    // Append newline at the end
    pi.waitIo();
    buffer[buf_index] = 0x2020200A;
    buf_index += 1;
    return buffer[0..buf_index];
}
