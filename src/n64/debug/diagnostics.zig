//! Opt-in, allocation-free rendering diagnostics. No calls are made automatically.
const std = @import("std");
const debug = @import("../debug.zig");
const rsp = @import("../rsp/rsp.zig");
const rdp = @import("../graphics/rdp.zig");
const rdp_io = @import("../graphics/rdp/io.zig");
const VertexPair = @import("../graphics/geometry.zig").VertexPair;

fn print(comptime format: []const u8, args: anytype) void {
    var buffer: [256]u8 = undefined;
    debug.writeStr(std.fmt.bufPrint(&buffer, format, args) catch return);
}

/// Capture a tightly packed RGBA16/32 image after its already-submitted full-sync
/// fence. The caller must stop writes/reuse of the image until this returns.
/// Read through KSEG1: do not discard or write back CPU cache lines here.
/// IDs identify transfers in logs and must not be reused within one capture log.
pub fn captureFramebuffer(frame: anytype, fence: rdp.Fence, id: u32, max_attempts: u32) !void {
    if (debug.current_backend == .None) return error.NoDebugBackend;
    const Frame = @TypeOf(frame);
    if (Frame.format != .rgba or (Frame.bit_depth != .@"16" and Frame.bit_depth != .@"32"))
        @compileError("framebuffer capture supports RGBA16 and RGBA32 only");
    if (!fence.waitTimeout(max_attempts)) return error.RdpFenceTimeout;
    const size = @sizeOf(Frame.Pixel);
    const len = @as(usize, frame.width) * frame.height * size;
    if (frame.width == 0 or frame.height == 0 or len != frame.texel_data.len * size)
        return error.InvalidFramebuffer;
    const bytes: [*]const volatile u8 = @ptrFromInt(uncachedAddress(@intFromPtr(frame.texel_data.ptr)));
    print("@@PTERO_FB_BEGIN@@ {d} {d} {d} {d}\n", .{ id, frame.width, frame.height, size * 8 });
    var offset: usize = 0;
    while (offset < len) {
        var buffer: [128]u8 = undefined;
        const encoded = @import("framebuffer_hex.zig").encode(bytes + offset, len - offset, &buffer);
        print("@@PTERO_FB_DATA@@ {d} {d} {s}\n", .{ id, offset, encoded });
        offset += encoded.len / 2;
    }
    print("@@PTERO_FB_END@@ {d}\n", .{id});
}

pub const ProbeResult = struct { compared_bytes: usize, mismatched_bytes: usize };

/// Compare current CPU-visible packed vertices with actual RDRAM. Does not flush
/// or invalidate: detecting a missing writeback is the purpose of this probe.
/// Stop both CPU and RSP writes first. Limit logging to max_details differing bytes.
pub fn probeVertices(vertices: []const VertexPair, max_details: usize) ProbeResult {
    const cpu = std.mem.sliceAsBytes(vertices);
    const ram: [*]const volatile u8 = @ptrFromInt(uncachedAddress(@intFromPtr(cpu.ptr)));
    var result: ProbeResult = .{ .compared_bytes = cpu.len, .mismatched_bytes = 0 };
    for (cpu, 0..) |expected, offset| {
        const actual = ram[offset];
        if (expected == actual) continue;
        if (result.mismatched_bytes < max_details)
            print("vertex probe pair={d} byte={d} cpu={x:0>2} rdram={x:0>2}\n", .{ offset / @sizeOf(VertexPair), offset % @sizeOf(VertexPair), expected, actual });
        result.mismatched_bytes += 1;
    }
    print("vertex probe compared={d} mismatched={d}\n", .{ result.compared_bytes, result.mismatched_bytes });
    return result;
}

fn uncachedAddress(address: usize) usize {
    // API inputs must reside in RDRAM's KSEG0/KSEG1 mappings, not MMIO/DMEM.
    return (address & 0x1fffffff) | 0xa0000000;
}

pub const RenderSnapshot = struct {
    rsp_status: u32,
    rsp_pc: u32,
    dma_busy: u32,
    dma_full: u32,
    rdp_status: u32,
    rdp_start: u32,
    rdp_end: u32,
    rdp_current: u32,

    /// Non-blocking, read-only MMIO reads; hardware may advance between fields.
    pub fn read() RenderSnapshot {
        return .{
            .rsp_status = @bitCast(rsp.io.status_register_read.*),
            .rsp_pc = rsp.io.program_counter.*,
            .dma_busy = rsp.io.dma_busy.*,
            .dma_full = rsp.io.dma_full.*,
            .rdp_status = @bitCast(rdp_io.status.*),
            .rdp_start = rdp_io.dma_start_addr.*,
            .rdp_end = rdp_io.dma_end_addr.*,
            .rdp_current = rdp_io.dma_current_addr.*,
        };
    }
};

/// Report a timeout without waiting for hardware, halting the RSP, touching the
/// semaphore, allocating, or relying on debug.initFmtBuffer. Label <= 80 bytes.
/// Backend transmission itself can block; this is not a transport watchdog.
pub fn reportRenderTimeout(label: []const u8, queue: ?*const rsp.Queue) void {
    const state = RenderSnapshot.read();
    print("render timeout: {s}\n", .{label[0..@min(80, label.len)]});
    print("RSP status={x:0>8} pc={x:0>8} dma_busy={d} dma_full={d}\n", .{ state.rsp_status, state.rsp_pc, state.dma_busy, state.dma_full });
    print("RDP status={x:0>8} start={x:0>8} end={x:0>8} current={x:0>8}\n", .{ state.rdp_status, state.rdp_start, state.rdp_end, state.rdp_current });
    if (queue) |q| {
        print("queue priority={s} write_index={d} submitted={} syncpoint_pending={} recording={}\n", .{ @tagName(q.priority), q.storage.write_index, q.storage.submitted, q.storage.syncpoint_pending, q.recording != null });
        for (&q.storage.queues, 0..) |*commands, index| {
            print("queue[{d}] addr={x:0>8} words={d}/{d} sealed={} next={} call={} swap={}\n", .{ index, @intFromPtr(commands.buffer.ptr), commands.index, commands.buffer.len, commands.sealed, commands.next != null, commands.call_target != null, commands.swap_target != null });
        }
    }
}
