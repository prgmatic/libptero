const std = @import("std");
const app = @import("../app.zig");
const graphics = @import("../graphics.zig");
const math = @import("../math.zig");

const Backend = struct {
    pub const Runtime = struct {
        mixer_attached: bool = false,
        pub fn init(self: *@This()) void {
            self.* = .{};
        }
        pub fn deinit(_: *@This()) void {}
    };
    pub const Renderer = struct {
        render: Render = .{},
        pub fn init(self: *@This(), _: *Runtime) void {
            self.* = .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn beginFrame(_: *@This(), _: Image, _: anytype) void {}
        pub fn submit(_: *@This()) Completion {
            return .{};
        }
    };
    pub const Render = struct {
        pub fn setState(_: *@This(), _: graphics.rdp.State) void {}
    };
    pub const Geometry = struct {
        matrix: ?*const math.FixedMat4 = null,
        pub fn init(self: *@This(), _: *Renderer) void {
            self.* = .{};
        }
        pub fn deinit(_: *@This()) void {}
        pub fn beginFrame(_: *@This(), _: Image, _: anytype) void {}
        pub fn attachViewport(_: *@This(), _: *graphics.geometry.Viewport) void {}
        pub fn drawModelWithTransform(self: *@This(), _: anytype, matrix: *const math.FixedMat4) void {
            self.matrix = matrix;
        }
        pub fn submit(_: *@This()) Completion {
            return .{};
        }
        pub fn syncTriangles(_: *@This()) void {}
    };
    const Image = struct {};
    pub const Display = struct {
        pub const Frame = struct { image: Image = .{} };
        timeout: bool = false,
        presents: usize = 0,
        releases: usize = 0,
        pub fn init(_: std.mem.Allocator, _: @import("../display.zig").Options) !@This() {
            return .{};
        }
        pub fn deinit(self: *@This(), _: std.mem.Allocator) !void {
            if (self.timeout) return error.VBlankTimeout;
        }
        pub fn acquire(_: *@This()) !Frame {
            return .{};
        }
        pub fn present(self: *@This(), _: Frame, _: Completion, _: anytype) !void {
            if (self.timeout) return error.VBlankTimeout;
            self.presents += 1;
        }
        pub fn release(self: *@This(), _: Frame) !void {
            self.releases += 1;
        }
    };
    pub const Depth = struct {
        pub fn init(_: std.mem.Allocator, _: u16, _: u16) !@This() {
            return .{};
        }
        pub fn deinit(_: *@This(), _: std.mem.Allocator) void {}
        pub fn view(_: @This()) void {}
    };
    pub const Controllers = struct {
        pub fn init() @This() {
            return .{};
        }
        pub fn poll(_: *@This()) void {}
        pub fn get(_: *@This(), _: @import("../io/joypad.zig").Port) @import("../io/joypad.zig").Snapshot {
            return .{};
        }
    };
    pub const Timer = struct {
        pub fn start() @This() {
            return .{};
        }
        pub fn lap(_: *@This()) @import("../time.zig").Duration {
            return .{ .ticks = @import("../time.zig").ticks_per_second };
        }
    };
    pub const Completion = struct {
        pub fn wait(_: @This(), _: anytype) !void {}
    };
};

test "frame tokens reject duplicate acquire, post-submit draws and stale copies" {
    var game: app.testing.create(.{ .geometry = true, .transforms = 2 }, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    try std.testing.expectEqual(@as(f32, 0.25), frame.delta);
    try std.testing.expectError(error.FrameActive, game.beginFrame(.{}));
    try std.testing.expectError(error.FrameActive, game.deinit(std.testing.failing_allocator));
    try frame.setCamera(.init(320, 240));
    try frame.drawModel({}, .identity);
    const first = game.geometry.matrix.?;
    var transform = math.Mat4.identity;
    transform.m[3][0] = 17;
    try frame.drawModel({}, transform);
    try std.testing.expectEqual(@as(f32, 0), first.get(3, 0));
    try std.testing.expectEqual(@as(f32, 17), game.geometry.matrix.?.get(3, 0));
    try std.testing.expectError(error.FrameStorageFull, frame.drawModel({}, transform));
    _ = try frame.submit();
    try std.testing.expectError(error.FrameSubmitted, frame.drawModel({}, transform));
    const next = try game.beginFrame(.{});
    try std.testing.expectEqual(@as(usize, 1), game.display.presents);
    try std.testing.expectEqual(@as(usize, 0), game.uploads.matrix_count);
    try std.testing.expectError(error.InvalidFrame, frame.present());
    try next.discard();
    try std.testing.expectEqual(@as(usize, 1), game.display.releases);
    try game.deinit(std.testing.failing_allocator);
}

test "presentation timeouts retain upload storage and are retried without resubmission" {
    var game: app.testing.create(.{ .geometry = true }, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    try frame.drawModel({}, .identity);
    game.display.timeout = true;
    try std.testing.expectError(error.VBlankTimeout, frame.present());
    try std.testing.expectError(error.VBlankTimeout, game.beginFrame(.{}));
    try std.testing.expectEqual(@as(usize, 1), game.uploads.matrix_count);
    game.display.timeout = false;
    try frame.present();
    try std.testing.expectEqual(@as(usize, 1), game.display.presents);
    try std.testing.expectError(error.InvalidFrame, frame.submit());
    game.runtime.mixer_attached = true;
    try std.testing.expectError(error.AudioAttached, game.deinit(std.testing.failing_allocator));
    game.runtime.mixer_attached = false;
    try game.deinit(std.testing.failing_allocator);
}

test "2D app reserves no transform storage and can drain an abandoned frame" {
    var game: app.testing.create(.{}, Backend) = undefined;
    try std.testing.expectError(error.InvalidDelta, game.init(std.testing.failing_allocator, .{ .max_delta = 0 }));
    try game.init(std.testing.failing_allocator, .{ .input = false });
    try std.testing.expectEqual(@as(usize, 0), game.uploads.matrices.len);
    const frame = try game.beginFrame(.{});
    try frame.beginOverlay();
    try frame.discard();
    try std.testing.expectEqual(@as(usize, 0), game.display.presents);
    try std.testing.expectEqual(@as(usize, 1), game.display.releases);
    try game.deinit(std.testing.failing_allocator);
}
