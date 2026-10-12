const std = @import("std");
const context = @import("../context.zig");
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
        commands: [1024]u64 = undefined,
        render: Render = undefined,
        pub fn init(self: *@This(), _: *Runtime) void {
            self.render = .init(.{ .buffer = &self.commands });
        }
        pub fn deinit(_: *@This()) void {}
        pub fn beginFrame(self: *@This(), _: Image, _: anytype) void {
            self.render.clear();
        }
        pub fn submit(_: *@This()) Completion {
            return .{};
        }
    };
    pub const Render = graphics.rdp.FixedRenderQueue;
    pub const Geometry = struct {
        render: *Render,
        matrix: ?*const math.FixedMat4 = null,
        pose: []const math.FixedMat4 = &.{},
        vertices: []const graphics.geometry.VertexPair = &.{},
        camera: ?*const graphics.geometry.Viewport = null,
        fog_enabled: bool = false,
        ambient: graphics.color.Rgba32 = .black,
        light_count: u8 = 0,
        camera_before_lights: bool = false,
        draws: usize = 0,
        syncs: usize = 0,
        pub fn init(self: *@This(), renderer: *Renderer) void {
            self.* = .{ .render = &renderer.render };
        }
        pub fn deinit(_: *@This()) void {}
        pub fn beginFrame(self: *@This(), _: Image, _: anytype) void {
            self.render.clear();
        }
        pub fn attachViewport(self: *@This(), camera: *const graphics.geometry.Viewport) void {
            self.camera = camera;
        }
        pub fn drawModelWithTransform(self: *@This(), asset: anytype, matrix: *const math.FixedMat4) void {
            self.matrix = matrix;
            if (@TypeOf(asset) != void) self.vertices = asset.vertices;
            self.draws += 1;
        }
        pub fn recordModel(self: *@This(), recorded: anytype, _: anytype) void {
            recorded.* = self.render.getState();
        }
        pub fn drawRecordedWithTransform(self: *@This(), recorded: anytype, matrix: *const math.FixedMat4) void {
            self.render.setState(recorded.*);
            self.matrix = matrix;
            self.draws += 1;
        }
        pub fn setPose(self: *@This(), matrices: []const math.FixedMat4) void {
            self.pose = matrices;
        }
        pub fn setAmbientLight(self: *@This(), color: graphics.color.Rgba32) void {
            self.ambient = color;
        }
        pub fn setDirectionalLightAt(self: *@This(), _: u8, _: graphics.color.Rgba32, _: math.Vec3) void {
            self.camera_before_lights = self.camera != null;
        }
        pub fn setPointLightAt(self: *@This(), _: u8, _: graphics.color.Rgba32, _: math.Vec3, _: f32, _: bool) void {
            self.camera_before_lights = self.camera != null;
        }
        pub fn setLightCount(self: *@This(), count: u8) void {
            self.light_count = count;
        }
        pub fn setFogEnabled(self: *@This(), enabled: bool) void {
            self.fog_enabled = enabled;
        }
        pub fn setFogRange(_: *@This(), _: f32, _: f32) void {}
        pub fn submit(_: *@This()) Completion {
            return .{};
        }
        pub fn syncTriangles(self: *@This()) void {
            self.syncs += 1;
        }
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

test "frame tokens borrow caller buffers and reject duplicate acquire and stale copies" {
    var game: context.testing.create(.{ .geometry = true }, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    try std.testing.expectEqual(@as(f32, 0.25), frame.delta);
    try std.testing.expectError(error.FrameActive, game.beginFrame(.{}));
    try std.testing.expectError(error.FrameActive, game.deinit(std.testing.failing_allocator));
    var camera: graphics.geometry.Viewport = .init(320, 240);
    var transform = math.FixedMat4.identity;
    try frame.setCamera(&camera);
    try std.testing.expectEqual(&camera, game.geometry.camera.?);
    try frame.drawModel({}, &transform);
    try std.testing.expectEqual(&transform, game.geometry.matrix.?);
    _ = try frame.submit();
    try std.testing.expectError(error.FrameSubmitted, frame.drawModel({}, &transform));
    const next = try game.beginFrame(.{});
    try std.testing.expectEqual(@as(usize, 1), game.display.presents);
    try std.testing.expectError(error.InvalidFrame, frame.present());
    // The prior submission is complete; the caller can now update its buffer.
    transform.set(3, 0, 17);
    try next.drawModel({}, &transform);
    try std.testing.expectEqual(@as(f32, 17), game.geometry.matrix.?.get(3, 0));
    try next.discard();
    try std.testing.expectEqual(@as(usize, 1), game.display.releases);
    try game.deinit(std.testing.failing_allocator);
}

test "presentation timeouts preserve the submission and caller-buffer lifetime" {
    var game: context.testing.create(.{ .geometry = true }, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    var transform = math.FixedMat4.identity;
    try frame.drawModel({}, &transform);
    game.display.timeout = true;
    try std.testing.expectError(error.VBlankTimeout, frame.present());
    try std.testing.expectError(error.VBlankTimeout, game.beginFrame(.{}));
    try std.testing.expectEqual(&transform, game.geometry.matrix.?);
    try std.testing.expectEqual(@as(usize, 1), game.geometry.draws);
    game.display.timeout = false;
    try frame.present();
    try std.testing.expectEqual(@as(usize, 1), game.display.presents);
    try std.testing.expectError(error.InvalidFrame, frame.submit());
    game.runtime.mixer_attached = true;
    try std.testing.expectError(error.AudioAttached, game.deinit(std.testing.failing_allocator));
    game.runtime.mixer_attached = false;
    try game.deinit(std.testing.failing_allocator);
}

test "2D context can drain an abandoned frame" {
    var game: context.testing.create(.{}, Backend) = undefined;
    try std.testing.expectError(error.InvalidDelta, game.init(std.testing.failing_allocator, .{ .max_delta = 0 }));
    try game.init(std.testing.failing_allocator, .{ .input = false });
    const frame = try game.beginFrame(.{});
    _ = try frame.beginOverlay(.{});
    try frame.discard();
    try std.testing.expectEqual(@as(usize, 0), game.display.presents);
    try std.testing.expectEqual(@as(usize, 1), game.display.releases);
    try game.deinit(std.testing.failing_allocator);
}

test "passes borrow cameras, reset material state and reject earlier handles" {
    var game: context.testing.create(.{ .geometry = true }, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    var camera: graphics.geometry.Viewport = .init(320, 240);
    var second_camera: graphics.geometry.Viewport = .init(640, 240);
    var transform = math.FixedMat4.identity;
    const lights = [_]context.Light{.{ .directional = .{ .direction = .init(1, -1, 1) } }};
    var pipeline: context.GeometryPipeline = .{};
    pipeline.state.modes.antialias_en = false;
    const world = try frame.beginGeometry(.{ .camera = &camera, .lighting = .{ .lights = &lights }, .pipeline = pipeline });
    try std.testing.expectEqual(&camera, game.geometry.camera.?);
    try std.testing.expect(game.geometry.camera_before_lights);
    try std.testing.expectEqual(@as(u8, 1), game.geometry.light_count);
    // Simulate state left by an imported translucent/fogged material.
    game.renderer.render.setState(.translucent_geometry);
    game.geometry.fog_enabled = true;
    try world.drawModel({}, &transform);
    try std.testing.expectEqualDeep(pipeline.state, game.renderer.render.getState());
    try std.testing.expect(!game.geometry.fog_enabled);
    const too_many = [_]context.Light{.{ .directional = .{ .direction = .init(0, 1, 0) } }} ** (graphics.geometry.max_lights + 1);
    const before_failure = game.renderer.render.cmd_queue.queue.index;
    try std.testing.expectError(error.TooManyLights, frame.beginGeometry(.{ .camera = &camera, .lighting = .{ .lights = &too_many } }));
    try std.testing.expectEqual(before_failure, game.renderer.render.cmd_queue.queue.index);
    try world.drawModel({}, &transform); // Failed begin preserves the current pass.
    const overlay = try frame.beginOverlay(.{});
    try std.testing.expectError(error.InvalidPass, world.drawModel({}, &transform));
    const next = try frame.beginGeometry(.{ .camera = &second_camera });
    try std.testing.expectEqual(&second_camera, game.geometry.camera.?);
    try std.testing.expectEqual(@as(u16, 320), camera.width);
    try std.testing.expectEqual(@as(u8, 0), game.geometry.light_count);
    try std.testing.expectError(error.InvalidPass, overlay.drawText(emptyFont(), 0, 0, "", .{}));
    // Draws borrow caller storage; there is no implicit transform-slot limit.
    for (0..140) |_| try next.drawModel({}, &transform);
    _ = try frame.submit();
    try std.testing.expectError(error.FrameSubmitted, next.drawModel({}, &transform));
    try frame.present();
    try std.testing.expectError(error.InvalidFrame, next.drawModel({}, &transform));
    try game.deinit(std.testing.failing_allocator);
}

fn emptyFont() graphics.font.Font {
    return .{ .point_size = 8, .ascent = 8, .descent = 0, .line_height = 8, .ranges = &.{}, .glyphs = &.{} };
}

test "overlay isolates font state and multiplies sprite tint alpha without reloading textures" {
    var game: context.testing.create(.{}, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    const hud = try frame.beginOverlay(.{});
    const pixels: [4]graphics.color.Rgba16 align(8) = @splat(.white);
    const image: graphics.image.ConstImage(graphics.color.Rgba16) = .{ .texel_data = &pixels, .width = 2, .height = 2 };
    try hud.drawSprite(image, .{ .tint = .fromInt(0xff000080), .source = .{ .x = 1, .width = 1, .height = 2 }, .scale = .{ 2, 3 } });
    const tex_count = game.renderer.render.tex_cache_len;
    var font = emptyFont();
    const outlines = [_]graphics.image.PalettedImage(graphics.color.Ci4Pair){undefined};
    font.outline_atlases = &outlines; // Empty text changes pipeline, never reads this atlas.
    try hud.drawText(font, 0, 0, "", .{});
    try std.testing.expect(game.renderer.render.getModes().antialias_en);
    try hud.drawSprite(image, .{});
    try std.testing.expectEqualDeep((context.OverlayOptions{}).state().combine, game.renderer.render.getState().combine);
    try std.testing.expect(!game.renderer.render.getModes().antialias_en);
    try std.testing.expect(!game.renderer.render.getModes().z_compare_en);
    try std.testing.expectEqual(tex_count, game.renderer.render.tex_cache_len);
    const commands = game.renderer.render.cmd_queue.queue.index;
    try hud.drawSprite(image, .{ .scale = .{ 0, 1 } });
    try std.testing.expectError(error.InvalidSpriteScale, hud.drawSprite(image, .{ .scale = .{ 0.001, 1 } }));
    try std.testing.expectError(error.InvalidSpritePosition, hud.drawSprite(image, .{ .position = .{ std.math.nan(f32), 0 } }));
    try std.testing.expectError(error.InvalidSpriteRegion, hud.drawSprite(image, .{ .source = .{ .x = 1, .width = 2, .height = 2 } }));
    try std.testing.expectEqual(commands, game.renderer.render.cmd_queue.queue.index);
    var scratch: [1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, hud.drawTextPrint(emptyFont(), 0, 0, &scratch, .{}, "{s}", .{"too long"}));
    try std.testing.expectEqual(commands, game.renderer.render.cmd_queue.queue.index);
    try hud.drawTextPrint(emptyFont(), 0, 0, &scratch, .{}, "{d}", .{7});
    try frame.discard();
    try game.deinit(std.testing.failing_allocator);
}

test "recorded draws and poses borrow final buffers through timeout recovery" {
    var game: context.testing.create(.{ .geometry = true }, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    var camera: graphics.geometry.Viewport = .init(320, 240);
    var transform = math.FixedMat4.identity;
    var bones = [_]math.FixedMat4{.identity};
    var vertices = [_]graphics.geometry.VertexPair{std.mem.zeroes(graphics.geometry.VertexPair)};
    const world = try frame.beginGeometry(.{ .camera = &camera });
    var recorded: graphics.rdp.State = undefined;
    try world.recordModel(&recorded, {});
    try world.drawRecorded(&recorded, &transform);
    try std.testing.expectEqual(&transform, game.geometry.matrix.?);
    try world.setPose(&bones);
    try std.testing.expectEqual(bones[0..].ptr, game.geometry.pose.ptr);
    try std.testing.expectError(error.EmptyPose, world.setPose(&.{}));
    try world.drawModel(.{ .vertices = vertices[0..] }, &transform);
    try std.testing.expectEqual(vertices[0..].ptr, game.geometry.vertices.ptr);
    game.display.timeout = true;
    try std.testing.expectError(error.VBlankTimeout, frame.present());
    try std.testing.expectError(error.FrameSubmitted, world.setPose(&bones));
    try std.testing.expectError(error.FrameSubmitted, world.drawRecorded(&recorded, &transform));
    try std.testing.expectEqual(bones[0..].ptr, game.geometry.pose.ptr);
    try std.testing.expectEqual(vertices[0..].ptr, game.geometry.vertices.ptr);
    game.display.timeout = false;
    try frame.present();
    // Sources can be regenerated in place once every reader has completed.
    transform.set(3, 0, 9);
    bones[0].set(3, 0, 10);
    vertices[0].pos_a[0] = 20;
    const next = try game.beginFrame(.{});
    const next_world = try next.beginGeometry(.{ .camera = &camera });
    try next_world.setPose(&bones);
    try next_world.drawModel(.{ .vertices = vertices[0..] }, &transform);
    try std.testing.expectEqual(@as(f32, 9), game.geometry.matrix.?.get(3, 0));
    try std.testing.expectEqual(@as(f32, 10), game.geometry.pose[0].get(3, 0));
    try std.testing.expectEqual(@as(i16, 20), game.geometry.vertices[0].pos_a[0]);
    try next.discard();
    try game.deinit(std.testing.failing_allocator);
}
