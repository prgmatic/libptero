//! Optional game loop support with borrowed render data and explicit submission.
const std = @import("std");
const graphics = @import("graphics.zig");
const display_api = @import("display.zig");
const rsp = @import("rsp/rsp.zig");
const joypad = @import("io/joypad.zig");
const time = @import("time.zig");
const math = @import("math.zig");
const passes = @import("context/passes.zig");
const pass_options = @import("context/pass_options.zig");
pub const GeometryOptions = pass_options.GeometryOptions;
pub const GeometryPipeline = pass_options.GeometryPipeline;
pub const OverlayOptions = pass_options.OverlayOptions;
pub const OverlayPipeline = pass_options.OverlayPipeline;
pub const SpriteOptions = pass_options.SpriteOptions;
pub const Lighting = pass_options.Lighting;
pub const Light = pass_options.Light;
pub const Fog = pass_options.Fog;

pub const Config = struct {
    geometry: bool = false,
};
pub const Options = struct {
    display: display_api.Options = .{ .framebuffer_access = .gpu_only },
    input: bool = true,
    max_delta: f32 = 0.25,
};
pub const FrameOptions = struct {
    clear_color: ?graphics.color.Rgba16 = null,
    clear_depth: bool = true,
};

/// Initialize in persistent storage; this owner and its components must not move.
/// Allocates display/depth only at init. Frame operations never heap allocate.
/// Audio can borrow &context.runtime and must detach before context.deinit(allocator).
pub fn Context(comptime config: Config) type {
    return ContextImpl(config, Hardware);
}

fn ContextImpl(comptime config: Config, comptime Backend: type) type {
    return struct {
        const Self = @This();
        pub const Pixel = graphics.color.Rgba16;
        runtime: Backend.Runtime = undefined,
        renderer: Backend.Renderer = undefined,
        geometry: if (config.geometry) Backend.Geometry else void = undefined,
        display: Backend.Display = undefined,
        depth: if (config.geometry) Backend.Depth else void = undefined,
        controllers: Backend.Controllers = undefined,
        options: Options = .{},
        timer: Backend.Timer = undefined,
        state: enum { idle, recording, submitted } = .idle,
        generation: u64 = 0,
        pass_generation: u64 = 0,
        acquired: Backend.Display.Frame = undefined,
        completion: Backend.Completion = undefined,
        discard_pending: bool = false,

        pub fn init(self: *Self, allocator: std.mem.Allocator, options: Options) !void {
            if (!std.math.isFinite(options.max_delta) or options.max_delta <= 0) return error.InvalidDelta;
            self.* = .{ .options = options };
            // Allocate depth first, before display takes ownership of VI.
            if (config.geometry) {
                const size = options.display.resolution.dimensions();
                self.depth = try Backend.Depth.init(allocator, size.width, size.height);
            }
            errdefer if (config.geometry) self.depth.deinit(allocator);
            self.display = try Backend.Display.init(allocator, options.display);
            self.runtime.init();
            self.renderer.init(&self.runtime);
            if (config.geometry) self.geometry.init(&self.renderer);
            self.controllers = if (options.input) Backend.Controllers.init() else .{};
            self.timer = Backend.Timer.start();
        }

        /// Finish the previously submitted frame before acquiring the next target.
        /// Call submit() early to overlap independent CPU work with GPU execution.
        pub fn beginFrame(self: *Self, options: FrameOptions) !Frame {
            if (self.state == .recording) return error.FrameActive;
            try self.finish();
            self.acquired = try self.display.acquire();
            self.generation +%= 1;
            self.state = .recording;
            if (config.geometry) {
                self.geometry.beginFrame(self.acquired.image, .{
                    .clear_color = options.clear_color,
                    .depth = self.depth.view(),
                    .clear_depth = options.clear_depth,
                });
            } else self.renderer.beginFrame(self.acquired.image, .{ .clear_color = options.clear_color });
            self.renderer.render.setState(if (config.geometry) .opaque_geometry else .textured_sprite);
            if (self.options.input) self.controllers.poll();
            return .{
                .context = self,
                .generation = self.generation,
                .input = self.controllers.get(.one),
                .delta = @min(self.timer.lap().seconds(), self.options.max_delta),
            };
        }

        /// Present submitted work. A timeout retains the frame, completion and
        /// uploads for retry; it never silently releases hardware-owned memory.
        pub fn finish(self: *Self) !void {
            if (self.state != .submitted) return;
            if (self.discard_pending) {
                try self.completion.wait(.{ .max_attempts = self.options.display.max_attempts });
                try self.display.release(self.acquired);
            } else try self.display.present(self.acquired, self.completion, .{ .max_attempts = self.options.display.max_attempts });
            self.state = .idle;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) !void {
            if (self.state == .recording) return error.FrameActive;
            if (self.runtime.mixer_attached) return error.AudioAttached;
            try self.finish();
            // Retain every other resource if scanout teardown times out.
            try self.display.deinit(allocator);
            if (config.geometry) {
                self.geometry.deinit();
                self.depth.deinit(allocator);
            }
            self.renderer.deinit();
            self.runtime.deinit();
            self.* = undefined;
        }

        pub const GeometryPass = passes.GeometryPass(Self);
        pub const OverlayPass = passes.OverlayPass(Self);

        pub const Frame = struct {
            context: *Self,
            generation: u64,
            input: joypad.Snapshot,
            delta: f32,

            fn validate(self: Frame) !void {
                if (self.generation != self.context.generation or self.context.state == .idle) return error.InvalidFrame;
            }
            fn recording(self: Frame) !void {
                try self.validate();
                if (self.context.state != .recording) return error.FrameSubmitted;
            }

            /// Direct drawing compatibility API. Prefer beginGeometry for explicit state.
            /// Invalidates pass handles; borrows the camera until completion.
            pub fn setCamera(self: Frame, viewport: *const graphics.geometry.Viewport) !void {
                if (!config.geometry) @compileError("setCamera requires Context(.{ .geometry = true })");
                try self.recording();
                self.context.pass_generation +%= 1;
                self.context.geometry.attachViewport(viewport);
            }

            pub fn drawModel(self: Frame, asset: anytype, transform: *const math.FixedMat4) !void {
                if (!config.geometry) @compileError("drawModel requires Context(.{ .geometry = true })");
                try self.recording();
                self.context.pass_generation +%= 1;
                self.context.geometry.drawModelWithTransform(asset, transform);
            }

            /// Start a geometry pass. Camera matrices remain borrowed until completion.
            pub fn beginGeometry(self: Frame, options: GeometryOptions) !GeometryPass {
                if (!config.geometry) @compileError("beginGeometry requires Context(.{ .geometry = true })");
                try self.recording();
                if (options.lighting.lights.len > graphics.geometry.max_lights) return error.TooManyLights;
                self.context.geometry.syncTriangles();
                self.context.pass_generation +%= 1;
                self.context.geometry.attachViewport(options.camera);
                options.lighting.apply(&self.context.geometry);
                options.pipeline.apply(&self.context.geometry);
                return .{ .frame = self, .generation = self.context.pass_generation, .pipeline = options.pipeline };
            }

            /// Start a 2D pass, draining pending triangles before changing pipeline state.
            pub fn beginOverlay(self: Frame, options: OverlayOptions) !OverlayPass {
                try self.recording();
                if (config.geometry) self.context.geometry.syncTriangles();
                self.context.pass_generation +%= 1;
                options.pipeline.apply(&self.context.renderer.render);
                return .{ .frame = self, .generation = self.context.pass_generation, .options = options };
            }

            pub fn drawText(self: Frame, font: graphics.font.Font, x: f32, y: f32, text: []const u8, options: graphics.font.TextOptions) !void {
                try self.recording();
                self.context.pass_generation +%= 1;
                _ = try font.draw(&self.context.renderer.render, x, y, text, options);
            }

            /// Submit once without waiting or changing VI. A copied Frame cannot
            /// draw afterward. Public renderer/context remain low-level escape hatches.
            pub fn submit(self: Frame) !Backend.Completion {
                try self.recording();
                self.context.completion = if (config.geometry) self.context.geometry.submit() else self.context.renderer.submit();
                self.context.discard_pending = false;
                self.context.state = .submitted;
                return self.context.completion;
            }

            pub fn present(self: Frame) !void {
                try self.validate();
                if (self.context.state == .recording) _ = try self.submit();
                try self.context.finish();
            }

            /// Commands can execute while being recorded. Drain them before
            /// releasing an abandoned frame; retry this call after a timeout.
            pub fn discard(self: Frame) !void {
                try self.validate();
                if (self.context.state == .recording) _ = try self.submit();
                self.context.discard_pending = true;
                try self.context.finish();
            }
        };
    };
}

const Hardware = struct {
    const Runtime = rsp.Runtime;
    const Renderer = graphics.Renderer;
    const Geometry = graphics.geometry.Context;
    const Display = display_api.Swapchain(graphics.color.Rgba16);
    const Depth = graphics.DepthBuffer;
    const Controllers = joypad.System;
    const Timer = time.Timer;
    const Completion = graphics.rdp.Completion;
};

test {
    _ = @import("context/tests.zig");
}
pub const testing = if (@import("builtin").is_test) struct {
    pub const create = ContextImpl;
} else struct {};
