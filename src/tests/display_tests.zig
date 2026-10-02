const std = @import("std");
const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

var pixels: [2 * 320 * 240]n64.graphics.color.Rgba32 align(64) = undefined;
var commands: [32]u64 align(8) = undefined;

pub const tests = [_]runner.Test{
    .{ .name = "Display: CPU and RDP presentation without VI interrupts", .run = presentation },
};

fn presentation() !void {
    @setEvalBranchQuota(10_000);
    const status = n64.cpu.cp0.regRead(.Status);
    n64.cpu.cp0.regWrite(.Status, status & ~@as(u32, 1));
    defer n64.cpu.cp0.regWrite(.Status, status);
    var chain = try n64.display.Swapchain(n64.graphics.color.Rgba32).initBuffer(&pixels, .{});
    var unused_allocator = std.heap.FixedBufferAllocator.init(&.{});
    errdefer chain.deinit(unused_allocator.allocator()) catch {};
    const origin: *volatile u32 = @ptrFromInt(0xa4400004);
    const first_origin = origin.*;
    const cpu_frame = try chain.acquire();
    const cpu_image = cpu_frame.image;
    cpu_image.fill(.blue);
    try chain.presentCpu(cpu_frame, .{});
    try testing.expectEqual(@as(u32, @intFromPtr(cpu_image.texel_data.ptr)) & 0x1fff_ffff, origin.*);
    try testing.expect(origin.* != first_origin);

    const gpu_frame = try chain.acquire();
    try testing.expectEqual(@as(u32, @intFromPtr(gpu_frame.image.texel_data.ptr)) & 0x1fff_ffff, first_origin);
    n64.rsp.halt();
    n64.rsp.waitHalted();
    n64.rsp.releaseRdpToDirect();
    var render = n64.graphics.rdp.DirectRenderQueue.init(.{ .buffer = &commands });
    render.setFrameBuffer(gpu_frame.image);
    render.clearScreen(n64.graphics.color.Rgba32.green);
    const completion = render.submit();
    try chain.present(gpu_frame, completion, .{});
    try testing.expect(completion.isComplete());
    try completion.wait(.{ .max_attempts = 0 });
    try testing.expectEqual(first_origin, origin.*);
    n64.cache.invalidateData(gpu_frame.image.texel_data);
    for (gpu_frame.image.texel_data) |pixel| try testing.expectEqual(n64.graphics.color.Rgba32.green, pixel);

    // Retire an immediate-mode front buffer before returning it to the CPU.
    chain.options.present_mode = .immediate;
    const immediate = try chain.acquire();
    try chain.presentCpu(immediate, .{});
    const retired = try chain.acquire();
    try testing.expectEqual(gpu_frame.index, retired.index);
    try chain.release(retired);
    try testing.expectEqual(@as(u32, 0), n64.cpu.cp0.regRead(.Status) & 1);
    try chain.deinit(unused_allocator.allocator());
}
