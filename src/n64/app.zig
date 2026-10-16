//! Optional game loop support with borrowed render data and explicit submission.
const std = @import("std");
const rdp = @import("rdp.zig");
const graphics = @import("graphics.zig");
const display_api = @import("display/swapchain.zig");
const rsp = @import("rsp.zig");
const joypad = @import("input.zig");
const time = @import("time.zig");
const math = @import("math.zig");
const passes = @import("app/passes.zig");
const pass_options = @import("app/pass_options.zig");
const GeometryOptions = pass_options.GeometryOptions;
const GeometryPipeline = pass_options.GeometryPipeline;
const OverlayOptions = pass_options.OverlayOptions;
const OverlayPipeline = pass_options.OverlayPipeline;
const SpriteOptions = pass_options.SpriteOptions;
const Lighting = pass_options.Lighting;
const Light = pass_options.Light;
const Fog = pass_options.Fog;

pub const Config = struct {
    geometry: bool = false,
};
const InitOptions = struct {
    display: display_api.Swapchain(graphics.pixel.Rgba16).Options = .{ .framebuffer_access = .gpu_only },
    input: bool = true,
    max_delta: f32 = 0.25,
    /// Print RSP/RDP registers and queue state over the debug link when a
    /// frame times out, before the error is returned.
    report_timeouts: bool = true,
};
const BeginFrameOptions = struct {
    clear_color: ?graphics.pixel.Rgba16 = null,
    clear_depth: bool = true,
};

/// Initialize in persistent storage; this owner and its components must not move.
/// Allocates display/depth only at init. Frame operations never heap allocate.
/// Audio can borrow &context.runtime and must detach before context.deinit(allocator).
pub fn App(comptime config: Config) type {
    return AppImpl(config, Hardware);
}

fn AppImpl(comptime config: Config, comptime Backend: type) type {
    return struct {
        const Self = @This();
        pub const Options = InitOptions;
        pub const FrameOptions = BeginFrameOptions;
        pub const Pixel = graphics.pixel.Rgba16;
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
        /// Whether the current overlay pass pipeline is still in effect
        /// (text replaces it), so consecutive sprites skip re-applying it.
        overlay: struct { applied: bool = false } = .{},
        acquired: Backend.Display.Frame = undefined,
        completion: Backend.Completion = undefined,
        discard_pending: bool = false,
        stats: FrameStats = .{},
        recording_stats: FrameStats = .{},
        audio: ?AudioHook = null,

        const AudioHook = struct {
            player: *anyopaque,
            update: *const fn (*anyopaque) anyerror!void,
        };

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
            self.acquired = self.display.acquire() catch |err| {
                self.reportTimeout("acquire", err);
                return err;
            };
            // The previous frame has completed, so the RDP is idle.
            if (@hasDecl(Backend, "GpuCounters")) Backend.GpuCounters.reset();
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
            const elapsed = self.timer.lap();
            self.recording_stats = .{ .frame_ms = elapsed.milliseconds() };
            return .{
                .context = self,
                .generation = self.generation,
                .input = self.controllers.get(.one),
                .delta = @min(elapsed.seconds(), self.options.max_delta),
            };
        }

        /// Mix audio in every submit, right after the GPU receives the frame,
        /// so mixing overlaps rendering. `player` is an audio.Player (or any
        /// type with `update(.{})`) that must stay at a stable address; detach
        /// before deinitializing it.
        pub fn attachAudio(self: *Self, player: anytype) void {
            const Player = @TypeOf(player.*);
            self.audio = .{ .player = player, .update = struct {
                fn update(opaque_player: *anyopaque) anyerror!void {
                    const typed: *Player = @ptrCast(@alignCast(opaque_player));
                    _ = try typed.update(.{});
                }
            }.update };
        }

        pub fn detachAudio(self: *Self) void {
            self.audio = null;
        }

        fn reportTimeout(self: *Self, comptime stage: []const u8, err: anyerror) void {
            if (comptime !@hasDecl(Backend, "reportTimeout")) return;
            if (!self.options.report_timeouts) return;
            switch (err) {
                error.RspTimeout, error.RdpFenceTimeout, error.VBlankTimeout => Backend.reportTimeout(stage, &self.renderer),
                else => {},
            }
        }

        /// Timing of the most recently completed frame, measured without
        /// debug output. Updated when that frame finishes (normally in the
        /// following beginFrame).
        pub fn lastFrameStats(self: *const Self) FrameStats {
            return self.stats;
        }

        /// Present submitted work. A timeout retains the frame, completion and
        /// uploads for retry; it never silently releases hardware-owned memory.
        pub fn finish(self: *Self) !void {
            if (self.state != .submitted) return;
            const wait_start = self.timer.read();
            self.presentSubmitted() catch |err| {
                self.reportTimeout("present", err);
                return err;
            };
            self.state = .idle;
            var stats = self.recording_stats;
            stats.present_wait_ms = self.timer.read().milliseconds() - wait_start.milliseconds();
            if (@hasDecl(Backend, "GpuCounters")) {
                const counters = Backend.GpuCounters.read();
                const ms_per_cycle = 1000.0 / Backend.GpuCounters.cycles_per_second;
                stats.rdp_busy_ms = @as(f32, @floatFromInt(counters.command_busy)) * ms_per_cycle;
                stats.rdp_pipe_ms = @as(f32, @floatFromInt(counters.pipe_busy)) * ms_per_cycle;
                stats.rdp_tmem_ms = @as(f32, @floatFromInt(counters.tmem_busy)) * ms_per_cycle;
            }
            if (@hasDecl(Backend, "RspCounters")) {
                const counters = Backend.RspCounters.take();
                stats.rsp_busy_ms = counters.busyMilliseconds();
                stats.rsp_queue_wait_ms = counters.queueWaitMilliseconds();
            }
            self.stats = stats;
        }

        fn presentSubmitted(self: *Self) !void {
            if (self.discard_pending) {
                try self.completion.wait(.{ .max_attempts = self.options.display.max_attempts });
                try self.display.release(self.acquired);
            } else try self.display.present(self.acquired, self.completion, .{ .max_attempts = self.options.display.max_attempts });
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
            pub fn setCamera(self: Frame, viewport: *const graphics.Viewport) !void {
                if (!config.geometry) @compileError("setCamera requires App(.{ .geometry = true })");
                try self.recording();
                self.context.pass_generation +%= 1;
                self.context.geometry.attachViewport(viewport);
            }

            pub fn drawModel(self: Frame, asset: anytype, transform: *const math.FixedMat4) !void {
                if (!config.geometry) @compileError("drawModel requires App(.{ .geometry = true })");
                try self.recording();
                self.context.pass_generation +%= 1;
                self.context.geometry.drawModelWithTransform(asset, transform);
            }

            /// Start a geometry pass. Camera matrices remain borrowed until completion.
            pub fn beginGeometry(self: Frame, options: GeometryOptions) !GeometryPass {
                if (!config.geometry) @compileError("beginGeometry requires App(.{ .geometry = true })");
                try self.recording();
                if (options.lighting.lights.len > graphics.max_lights) return error.TooManyLights;
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
                self.context.overlay = .{ .applied = true };
                return .{ .frame = self, .generation = self.context.pass_generation, .options = options };
            }

            pub fn drawText(self: Frame, font: graphics.Font, x: f32, y: f32, text: []const u8, options: graphics.Font.DrawOptions) !void {
                try self.recording();
                self.context.pass_generation +%= 1;
                _ = try font.draw(&self.context.renderer.render, x, y, text, options);
            }

            /// Submit once without waiting or changing VI, then mix attached
            /// audio. A copied Frame cannot draw afterward. An audio error is
            /// returned after the frame is submitted; present() still applies.
            /// Public renderer/context remain low-level escape hatches.
            pub fn submit(self: Frame) !Backend.Completion {
                try self.recording();
                const context = self.context;
                const submit_start = context.timer.read();
                context.recording_stats.record_ms = submit_start.milliseconds();
                context.completion = if (config.geometry) context.geometry.submit() else context.renderer.submit();
                context.discard_pending = false;
                context.state = .submitted;
                if (context.audio) |audio| {
                    const mix_start = context.timer.read();
                    try audio.update(audio.player);
                    context.recording_stats.audio_ms = context.timer.read().milliseconds() - mix_start.milliseconds();
                }
                return context.completion;
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

/// One frame's timing. CPU times come from the COP0 counter; RDP times
/// from the RDP's own busy counters, so they are unaffected by CPU stalls.
pub const FrameStats = struct {
    /// Previous frame start to this frame start.
    frame_ms: f32 = 0,
    /// beginFrame returning to submit: CPU update and command recording.
    record_ms: f32 = 0,
    /// Mixing attached audio in submit.
    audio_ms: f32 = 0,
    /// CPU time blocked finishing the frame (GPU completion and vsync).
    present_wait_ms: f32 = 0,
    /// RDP processing commands, including stalls waiting on RDRAM.
    rdp_busy_ms: f32 = 0,
    /// RDP pixel pipeline busy.
    rdp_pipe_ms: f32 = 0,
    /// RDP loading TMEM.
    rdp_tmem_ms: f32 = 0,
    /// RSP running since the previous frame finished: geometry, RDP command
    /// generation and audio, including its stalls on DMA and RDP buffer space.
    /// Measured from the dispatcher's idle timestamps on the DP clock.
    rsp_busy_ms: f32 = 0,
    /// Part of `record_ms` the CPU spent blocked because the RSP had not yet
    /// drained the previous command buffer (RSP-bound recording).
    rsp_queue_wait_ms: f32 = 0,
};

const Hardware = struct {
    const GpuCounters = @import("hw/dp.zig").Counters;
    const RspCounters = struct {
        fn take() rsp.Counters {
            return rsp.takeCounters();
        }
    };
    const Runtime = rsp.Runtime;
    const Renderer = rdp.Renderer;
    const Geometry = graphics.GeometryEncoder;
    const Display = display_api.Swapchain(graphics.pixel.Rgba16);
    const Depth = graphics.DepthBuffer;
    const Controllers = joypad.Controllers;
    const Timer = time.Timer;
    const Completion = rdp.Completion;

    pub fn reportTimeout(comptime stage: []const u8, renderer: *Renderer) void {
        @import("debug/diagnostics.zig").reportRenderTimeout("app " ++ stage, &renderer.queue);
    }
};

test {
    _ = @import("app/tests.zig");
}
pub const testing = if (@import("builtin").is_test) struct {
    pub const create = AppImpl;
} else struct {};
