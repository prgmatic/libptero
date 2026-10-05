const std = @import("std");
const math = @import("../math.zig");
const geometry = @import("../graphics/geometry.zig");

/// Bounded upload storage. Reset only after every GPU reader has completed.
pub fn Storage(comptime capacity: usize, comptime cameras: usize) type {
    return struct {
        matrices: [capacity]math.FixedMat4 align(16) = undefined,
        viewports: [cameras]geometry.Viewport = undefined,
        matrix_count: usize = 0,
        viewport_count: usize = 0,
        matrix_high_water: usize = 0,

        pub fn reset(self: *@This()) void {
            self.matrix_count = 0;
            self.viewport_count = 0;
        }
        pub fn matrix(self: *@This(), value: math.Mat4) !*const math.FixedMat4 {
            if (self.matrix_count == capacity) return error.FrameStorageFull;
            const destination = &self.matrices[self.matrix_count];
            value.writeFixed(destination);
            self.matrix_count += 1;
            self.matrix_high_water = @max(self.matrix_high_water, self.matrix_count);
            return destination;
        }
        pub fn camera(self: *@This(), value: geometry.Viewport) !*geometry.Viewport {
            if (self.viewport_count == cameras) return error.FrameStorageFull;
            const destination = &self.viewports[self.viewport_count];
            destination.* = value;
            self.viewport_count += 1;
            return destination;
        }
    };
}

test "frame transforms retain independent values and enforce a fixed budget" {
    var storage: Storage(2, 2) = .{};
    var transform = math.Mat4.identity;
    const first = try storage.matrix(transform);
    transform.m[3][0] = 42;
    const second = try storage.matrix(transform);
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(f32, 0), first.get(3, 0));
    try std.testing.expectEqual(@as(f32, 42), second.get(3, 0));
    try std.testing.expectError(error.FrameStorageFull, storage.matrix(transform));
    _ = try storage.camera(.init(320, 240));
    _ = try storage.camera(.init(640, 240));
    try std.testing.expectError(error.FrameStorageFull, storage.camera(.init(320, 240)));
    storage.reset();
    try std.testing.expectEqual(@as(usize, 2), storage.matrix_high_water);
    try std.testing.expectEqual(first, try storage.matrix(.identity));
}
