const rdp = @import("../rdp.zig");
const std = @import("std");
const context = @import("../app.zig");
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
    pub const Render = rdp.RenderEncoder(rdp.backend.Direct);
    pub const Geometry = struct {
        render: *Render,
        matrix: ?*const math.FixedMat4 = null,
        pose: []const math.FixedMat4 = &.{},
        vertices: []const graphics.VertexPair = &.{},
        camera: ?*const graphics.Viewport = null,
        fog_enabled: bool = false,
        ambient: graphics.pixel.Rgba32 = .black,
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
        pub fn attachViewport(self: *@This(), camera: *const graphics.Viewport) void {
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
        pub fn setAmbientLight(self: *@This(), color: graphics.pixel.Rgba32) void {
            self.ambient = color;
        }
        pub fn setDirectionalLightAt(self: *@This(), _: u8, _: graphics.pixel.Rgba32, _: math.Vec3) void {
            self.camera_before_lights = self.camera != null;
        }
        pub fn setPointLightAt(self: *@This(), _: u8, _: graphics.pixel.Rgba32, _: math.Vec3, _: f32, _: bool) void {
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
        pub fn init(_: std.mem.Allocator, _: @import("../display/swapchain.zig").Swapchain(@import("../graphics/pixel.zig").Rgba16).Options) !@This() {
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
        pub fn get(_: *@This(), _: @import("../input/Controllers.zig").Port) @import("../input/Controllers.zig").Snapshot {
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
        pub fn read(_: @This()) @import("../time.zig").Duration {
            return .{ .ticks = 0 };
        }
    };
    pub const Completion = struct {
        pub fn wait(_: @This(), _: anytype) !void {}
    };
    pub var timeout_reports: usize = 0;
    pub fn reportTimeout(comptime _: []const u8, _: *Renderer) void {
        timeout_reports += 1;
    }
};

test "frame tokens borrow caller buffers and reject duplicate acquire and stale copies" {
    var game: context.testing.create(.{ .geometry = true }, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    try std.testing.expectEqual(@as(f32, 0.25), frame.delta);
    try std.testing.expectError(error.FrameActive, game.beginFrame(.{}));
    try std.testing.expectError(error.FrameActive, game.deinit(std.testing.failing_allocator));
    var camera: graphics.Viewport = .init(320, 240);
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
    var camera: graphics.Viewport = .init(320, 240);
    var second_camera: graphics.Viewport = .init(640, 240);
    var transform = math.FixedMat4.identity;
    const lights = [_]graphics.Light{.{ .directional = .{ .direction = .init(1, -1, 1) } }};
    var pipeline: context.App(.{ .geometry = true }).GeometryPass.State = .{};
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
    const too_many = [_]graphics.Light{.{ .directional = .{ .direction = .init(0, 1, 0) } }} ** (graphics.max_lights + 1);
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

fn emptyFont() graphics.Font {
    return .{ .point_size = 8, .ascent = 8, .descent = 0, .line_height = 8, .ranges = &.{}, .glyphs = &.{} };
}

test "overlay isolates font state and multiplies sprite tint alpha without reloading textures" {
    var game: context.testing.create(.{}, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    const hud = try frame.beginOverlay(.{});
    const pixels: [4]graphics.pixel.Rgba16 align(8) = @splat(.white);
    const image: graphics.ConstImage(graphics.pixel.Rgba16) = .{ .texel_data = &pixels, .width = 2, .height = 2 };
    try hud.drawSprite(image, .{ .tint = .fromInt(0xff000080), .source = .{ .x = 1, .width = 1, .height = 2 }, .scale = .{ 2, 3 } });
    const tex_count = game.renderer.render.tex_cache_len;
    var font = emptyFont();
    const outlines = [_]graphics.PalettedImage(graphics.pixel.Ci4Pair){undefined};
    font.outline_atlases = &outlines; // Empty text changes pipeline, never reads this atlas.
    try hud.drawText(font, 0, 0, "", .{});
    // Outlined text restores the pass coverage modes it changes.
    try std.testing.expect(!game.renderer.render.getModes().antialias_en);
    try std.testing.expect(game.renderer.render.getModes().blender_alpha == .combiner);
    try hud.drawSprite(image, .{});
    try std.testing.expectEqualDeep((context.App(.{}).OverlayPass.State{}).state.combine, game.renderer.render.getState().combine);
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

test "custom overlay pipeline survives text and resets across passes" {
    const Game = context.testing.create(.{}, Backend);
    try std.testing.expect(!@hasDecl(Game.Frame, "drawSprite"));
    var game: Game = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    const pixels: [4]graphics.pixel.Rgba16 align(8) = @splat(.white);
    const image: graphics.ConstImage(graphics.pixel.Rgba16) = .{ .texel_data = &pixels, .width = 2, .height = 2 };
    var pipeline: context.App(.{}).OverlayPass.State = .{ .environment = .fromInt(0xffffff60) };
    pipeline.state.modes.texture_sample = .bilinear;
    pipeline.state.modes.cycle_type = .two_cycle;
    pipeline.state.combine = .{
        .cycle0 = .{ .rgb_a = .tex0, .rgb_c = .primitive, .alpha_a = .tex0, .alpha_c = .primitive },
        .cycle1 = .{ .rgb_a = .environment, .rgb_b = .combined, .rgb_c = .environment_alpha, .rgb_d = .combined, .alpha_d = .combined },
    };
    const sprites = try frame.beginOverlay(.{ .pipeline = pipeline });
    try std.testing.expectEqualDeep(pipeline.state, game.renderer.render.getState());
    try sprites.drawSprite(image, .{});
    const texture_count = game.renderer.render.tex_cache_len;
    try sprites.drawText(emptyFont(), 0, 0, "", .{ .color = .green });
    try std.testing.expect(!std.meta.eql(pipeline.state.combine, game.renderer.render.getState().combine));
    // Simulate environment color left by another draw as well as font state.
    game.renderer.render.setEnvironmentColor(.black);
    const start = game.renderer.render.cmd_queue.queue.index;
    const tint: graphics.pixel.Rgba32 = .fromInt(0xffc080c0);
    try sprites.drawSprite(image, .{ .tint = tint });
    try std.testing.expectEqualDeep(pipeline.state, game.renderer.render.getState());
    try std.testing.expectEqualDeep(pipeline.state.combine, game.renderer.render.emitted_combine.?);
    try std.testing.expectEqualDeep(pipeline.state.modes, game.renderer.render.emitted_mode.?);
    // Color register changes are synchronized before this sprite is emitted.
    const commands = game.renderer.commands[start..game.renderer.render.cmd_queue.queue.index];
    try std.testing.expectEqual(@as(u64, 0xE7) << 56, commands[0]);
    try std.testing.expectEqual((@as(u64, 0xFB) << 56) | @as(u32, @bitCast(pipeline.environment)), commands[1]);
    try std.testing.expectEqual((@as(u64, 0xFA) << 56) | @as(u32, @bitCast(tint)), commands[2]);
    const ordinary_start = game.renderer.render.cmd_queue.queue.index;
    const ordinary = try frame.beginOverlay(.{});
    try std.testing.expectError(error.InvalidPass, sprites.drawSprite(image, .{}));
    try ordinary.drawSprite(image, .{});
    // Later sprites in the pass with the same tint emit no state or color commands.
    const repeat_start = game.renderer.render.cmd_queue.queue.index;
    try ordinary.drawSprite(image, .{ .position = .{ 4, 4 } });
    for (game.renderer.commands[repeat_start..game.renderer.render.cmd_queue.queue.index]) |command| {
        try std.testing.expect(command >> 56 != 0xE7 and command >> 56 != 0xFA and command >> 56 != 0xFB);
    }
    try std.testing.expectEqualDeep((context.App(.{}).OverlayPass.State{}).state, game.renderer.render.getState());
    try std.testing.expectEqual((@as(u64, 0xFB) << 56) | @as(u32, @bitCast(graphics.pixel.Rgba32.white)), game.renderer.commands[ordinary_start + 1]);
    try std.testing.expectEqual(texture_count, game.renderer.render.tex_cache_len);
    _ = try frame.submit();
    try std.testing.expectError(error.FrameSubmitted, ordinary.drawSprite(image, .{}));
    try frame.present();
    try std.testing.expectError(error.InvalidFrame, ordinary.drawSprite(image, .{}));
    try game.deinit(std.testing.failing_allocator);
}

test "sprite batches emit one rectangle per draw and rebind after text" {
    const Game = context.testing.create(.{}, Backend);
    var game: Game = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    const pixels: [4]graphics.pixel.Rgba16 align(8) = @splat(.white);
    const image: graphics.ConstImage(graphics.pixel.Rgba16) = .{ .texel_data = &pixels, .width = 2, .height = 2 };
    const pass = try frame.beginOverlay(.{});
    var batch = try pass.sprites(image);
    try batch.draw(.{ .position = .{ 4, 4 } });
    const render = &game.renderer.render;
    var start = render.cmd_queue.queue.index;
    try batch.draw(.{ .position = .{ 8, 4 } });
    // Texture rectangles are two words; same tint and binding emit nothing else.
    try std.testing.expectEqual(@as(usize, 2), render.cmd_queue.queue.index - start);
    try std.testing.expectEqual(@as(u64, 0xE4), game.renderer.commands[start] >> 56);
    start = render.cmd_queue.queue.index;
    try batch.draw(.{ .position = .{ 12, 4 }, .tint = .red });
    try std.testing.expectEqual(@as(usize, 3), render.cmd_queue.queue.index - start);
    try std.testing.expectEqual(@as(u64, 0xFA), game.renderer.commands[start] >> 56);
    // Text replaces the pipeline; the next draw restores it before its rectangle.
    try pass.drawText(emptyFont(), 0, 0, "", .{});
    try batch.draw(.{ .position = .{ 16, 4 }, .tint = .red });
    try std.testing.expectEqualDeep((context.App(.{}).OverlayPass.State{}).state, render.getState());
    try std.testing.expectEqualDeep(render.mode, render.emitted_mode.?);
    _ = try frame.beginOverlay(.{});
    try std.testing.expectError(error.InvalidPass, batch.draw(.{}));
    _ = try frame.submit();
    try frame.present();
    try game.deinit(std.testing.failing_allocator);
}

test "recorded draws and poses borrow final buffers through timeout recovery" {
    var game: context.testing.create(.{ .geometry = true }, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    var camera: graphics.Viewport = .init(320, 240);
    var transform = math.FixedMat4.identity;
    var bones = [_]math.FixedMat4{.identity};
    var vertices = [_]graphics.VertexPair{std.mem.zeroes(graphics.VertexPair)};
    const world = try frame.beginGeometry(.{ .camera = &camera });
    var recorded: rdp.State = undefined;
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

test "timeouts are reported once each unless disabled" {
    var game: context.testing.create(.{}, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    game.display.timeout = true;
    const before = Backend.timeout_reports;
    try std.testing.expectError(error.VBlankTimeout, frame.present());
    try std.testing.expectEqual(before + 1, Backend.timeout_reports);
    game.options.report_timeouts = false;
    try std.testing.expectError(error.VBlankTimeout, frame.present());
    try std.testing.expectEqual(before + 1, Backend.timeout_reports);
    game.display.timeout = false;
    try frame.present();
    try game.deinit(std.testing.failing_allocator);
}

test "attached audio mixes after each submit and errors keep the frame submitted" {
    const Player = struct {
        updates: usize = 0,
        fail: bool = false,
        pub fn update(self: *@This(), _: struct {}) !u8 {
            if (self.fail) return error.AudioTimeout;
            self.updates += 1;
            return 1;
        }
    };
    var game: context.testing.create(.{}, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    var player: Player = .{};
    game.attachAudio(&player);
    var frame = try game.beginFrame(.{});
    try std.testing.expectEqual(@as(usize, 0), player.updates);
    _ = try frame.submit();
    try std.testing.expectEqual(@as(usize, 1), player.updates);
    try frame.present();
    player.fail = true;
    frame = try game.beginFrame(.{});
    try std.testing.expectError(error.AudioTimeout, frame.submit());
    try frame.present();
    game.detachAudio();
    player.fail = false;
    frame = try game.beginFrame(.{});
    try frame.present();
    try std.testing.expectEqual(@as(usize, 1), player.updates);
    try game.deinit(std.testing.failing_allocator);
}

test "overlay rectangles fill opaquely or blend with a flat combiner" {
    var game: context.testing.create(.{}, Backend) = undefined;
    try game.init(std.testing.failing_allocator, .{});
    const frame = try game.beginFrame(.{});
    const pass = try frame.beginOverlay(.{});
    const render = &game.renderer.render;
    var start = render.cmd_queue.queue.index;
    try pass.fillRect(0, 0, 320, 12, .fromBytes(255, 0, 0, 255));
    // Sync, fill mode, fill color, rectangle.
    try std.testing.expectEqual(@as(usize, 4), render.cmd_queue.queue.index - start);
    start = render.cmd_queue.queue.index;
    try pass.fillRect(0, 12, 320, 12, .fromBytes(255, 0, 0, 255));
    try std.testing.expectEqual(@as(usize, 1), render.cmd_queue.queue.index - start);
    try std.testing.expectEqual(@as(u64, 0xF6), game.renderer.commands[start] >> 56);
    start = render.cmd_queue.queue.index;
    try pass.fillRect(0, 24, 320, 12, .fromBytes(0, 255, 0, 255));
    try std.testing.expectEqual(@as(usize, 3), render.cmd_queue.queue.index - start);
    try pass.fillRect(0, 0, 0, 12, .white);
    try pass.drawRect(10, 10, 20.5, 8, .fromInt(0x00ff0080));
    try std.testing.expectEqualDeep(rdp.CombineMode.primitive, render.emitted_combine.?);
    try std.testing.expectEqualDeep((context.App(.{}).OverlayPass.State{}).state.modes, render.emitted_mode.?);
    const rect = game.renderer.commands[render.cmd_queue.queue.index - 1];
    try std.testing.expectEqual(@as(u64, 0xF6), rect >> 56);
    try std.testing.expectEqual(@as(u64, 122), (rect >> 44) & 0xfff);
    start = render.cmd_queue.queue.index;
    try pass.drawRect(10, 30, 20, 8, .fromInt(0x00ff0080));
    try std.testing.expectEqual(@as(usize, 1), render.cmd_queue.queue.index - start);
    try std.testing.expectError(error.InvalidRect, pass.drawRect(std.math.inf(f32), 0, 1, 1, .white));
    const pixels: [4]graphics.pixel.Rgba16 align(8) = @splat(.white);
    const image: graphics.ConstImage(graphics.pixel.Rgba16) = .{ .texel_data = &pixels, .width = 2, .height = 2 };
    try pass.drawSprite(image, .{});
    try std.testing.expectEqualDeep((context.App(.{}).OverlayPass.State{}).state, render.getState());
    try std.testing.expectEqualDeep(render.combine_mode, render.emitted_combine.?);
    try frame.discard();
    try game.deinit(std.testing.failing_allocator);
}
