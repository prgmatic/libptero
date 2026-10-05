const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

pub const tests = [_]runner.Test{
    .{ .name = "FPU: boot flushes underflowing products to signed zero", .run = underflow },
    .{ .name = "FPU: decaying animation blend reaches idle without trapping", .run = animationDecay },
};

// Volatile reads keep the products on the console's FPU, not the compiler's.
var single_inputs = [_]f32{ 1e-30, 1e-10 };
var double_inputs = [_]f64{ 1e-200, 1e-200 };
var initial_speed: f32 = 0.4;

fn underflow() !void {
    const control = asm volatile ("cfc1 %[control], $31"
        : [control] "=r" (-> u32),
    );
    try testing.expectEqual(@as(u32, 1 << 24), control & ((1 << 24) | 3 | (0x1f << 7)));
    const single: *volatile [2]f32 = &single_inputs;
    const double: *volatile [2]f64 = &double_inputs;
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(single[0] * single[1])));
    try testing.expectEqual(@as(u32, 0x80000000), @as(u32, @bitCast(-single[0] * single[1])));
    try testing.expectEqual(@as(u64, 0), @as(u64, @bitCast(double[0] * double[1])));
    try testing.expectEqual(@as(u64, 0x8000000000000000), @as(u64, @bitCast(-double[0] * double[1])));
}

fn animationDecay() !void {
    const Transform = n64.graphics.animation.Transform;
    const idle: Transform = .{};
    const walk: Transform = .{
        .translation = .init(1e-6, -1e-6, 1),
        .rotation = .{ .x = 1e-6, .y = -1e-6, .z = 0, .w = 1 },
    };
    var speed = @as(*volatile f32, &initial_speed).*;
    var pose = idle;
    for (0..512) |_| {
        speed *= 0.8;
        pose = idle.blend(walk, @min(speed / 0.51, 1));
        try testing.expect(@abs(pose.rotation.dot(pose.rotation) - 1) < 0.000001);
    }
    try testing.expectEqual(@as(f32, 0), speed);
    try testing.expectEqual(@as(f32, 0), pose.translation.x);
    try testing.expectEqual(@as(f32, 0), pose.translation.y);
    try testing.expectEqual(@as(f32, 0), pose.translation.z);
    try testing.expectEqual(@as(f32, 0), pose.rotation.x);
    try testing.expectEqual(@as(f32, 0), pose.rotation.y);
    try testing.expectEqual(@as(f32, 1), pose.rotation.w);
}
