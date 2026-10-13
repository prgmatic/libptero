const n64 = @import("n64");
const runner = @import("runner.zig");
const testing = @import("assert.zig");

pub const tests = [_]runner.Test{
    .{ .name = "FPU: boot flushes underflowing products to signed zero", .run = underflow },
    .{ .name = "FPU: decaying animation blend reaches idle without trapping", .run = animationDecay },
    .{ .name = "FPU: native math floors, wraps and rotates", .run = nativeMath },
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

var math_inputs = [_]f32{ -1.25, 1.75, -0.25, 1.57079637, 2147483520.0, -2147483648.0 };

fn nativeMath() !void {
    const inputs: *volatile [6]f32 = &math_inputs;
    try testing.expectEqual(@as(f32, -2), n64.math.fast.floor(inputs[0]));
    try testing.expectEqual(@as(f32, 1), n64.math.fast.floor(inputs[1]));
    try testing.expectEqual(@as(f32, 0.75), n64.math.fast.mod(inputs[2], 1));
    try testing.expectEqual(inputs[4], n64.math.fast.floor(inputs[4]));
    try testing.expectEqual(inputs[5], n64.math.fast.floor(inputs[5]));
    try testing.expect(@abs(n64.math.fast.sin(inputs[3]) - 1) < 0.000002);
    try testing.expect(@abs(n64.math.fast.cos(inputs[3])) < 0.000002);
    const rotation = n64.math.Quat.fromAxisAngle(.init(0, 1, 0), inputs[3]);
    const matrix = n64.math.Mat4.fromSrt(.one, rotation, .zero);
    const point = matrix.transformPoint(.init(1, 0, 0));
    try testing.expect(@abs(point.x) < 0.00001);
    try testing.expect(@abs(point.z + 1) < 0.00001);
}
