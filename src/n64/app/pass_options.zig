//! Values describing pass defaults. Material fields override geometry defaults;
//! each draw starts from these values, never from the previous draw's material.
const rdp = @import("../rdp.zig");
const graphics = @import("../graphics.zig");
const math = @import("../math.zig");
const Color = graphics.pixel.Rgba32;

pub const Light = graphics.Light;
pub const Lighting = graphics.Lighting;
pub const Fog = graphics.Fog;
pub const GeometryPipeline = struct {
    state: rdp.State = .opaque_geometry,
    primitive: Color = .white,
    environment: Color = .white,
    fog: ?Fog = null,

    pub fn apply(self: GeometryPipeline, context: anytype) void {
        const render = context.render;
        render.setState(self.state);
        render.cmd_queue.pipeSync();
        render.setPrimColor(self.primitive);
        render.setEnvironmentColor(self.environment);
        context.setFogEnabled(self.fog != null);
        if (self.fog) |fog| {
            render.setFogColor(fog.color);
            context.setFogRange(fog.near, fog.far);
        } else context.setFogRange(0, 0);
    }
};
pub const GeometryOptions = struct {
    /// Stable caller-owned viewport; its fixed matrices remain borrowed until completion.
    camera: *const graphics.Viewport,
    lighting: Lighting = .{},
    pipeline: GeometryPipeline = .{},
};
/// Baseline restored before every overlay draw. Sprite tint supplies primitive
/// color; custom combiners decide how tint and environment color are used.
pub const OverlayPipeline = struct {
    state: rdp.State = defaultState(),
    environment: Color = .white,

    /// Modes and combiner flush lazily before the next draw; the environment
    /// color syncs the pipe itself only when it changes.
    pub fn apply(self: OverlayPipeline, render: anytype) void {
        render.setState(self.state);
        render.setEnvironmentColor(self.environment);
    }

    fn defaultState() rdp.State {
        var result = rdp.State.textured_sprite;
        // Both RGB and alpha are multiplied by the draw's tint.
        result.combine = .single(.{ .rgb_a = .tex0, .rgb_c = .primitive, .alpha_a = .tex0, .alpha_c = .primitive });
        return result;
    }
};
pub const OverlayOptions = struct {
    pipeline: OverlayPipeline = .{},
};
pub const SpriteOptions = struct {
    position: [2]f32 = .{ 0, 0 },
    tint: Color = .white,
    source: ?struct { x: u8 = 0, y: u8 = 0, width: u8, height: u8 } = null,
    pivot: rdp.Pivot = .top_left,
    scale: [2]f32 = .{ 1, 1 },
    flip_x: bool = false,
    flip_y: bool = false,
    /// Radians around the pivot. Non-zero draws two textured triangles.
    rotation: f32 = 0,

    /// Zero scale is a no-op. Other scales must fit the RDP's signed 5.10 step.
    pub fn validate(self: SpriteOptions, width: u32, height: u32) !void {
        for (self.position) |value| if (!@import("std").math.isFinite(value)) return error.InvalidSpritePosition;
        for (self.scale) |value| try validateScale(value);
        if (!@import("std").math.isFinite(self.rotation)) return error.InvalidSpriteRotation;
        if (self.source) |source| try validateRegion(source, width, height);
    }

    fn validateScale(value: f32) !void {
        if (!@import("std").math.isFinite(value)) return error.InvalidSpriteScale;
        if (value != 0 and @abs(value) < 1024.0 / 32767.0) return error.InvalidSpriteScale;
    }

    fn validateRegion(source: anytype, width: u32, height: u32) !void {
        if (source.width == 0 or source.height == 0 or
            @as(u32, source.x) + source.width > width or
            @as(u32, source.y) + source.height > height) return error.InvalidSpriteRegion;
    }

    pub fn drawOptions(self: SpriteOptions) rdp.SpriteDrawOptions {
        return .{
            .s0 = if (self.source) |source| source.x else 0,
            .t0 = if (self.source) |source| source.y else 0,
            .width = if (self.source) |source| source.width else 0,
            .height = if (self.source) |source| source.height else 0,
            .pivot = self.pivot,
            .scale_x = self.scale[0],
            .scale_y = self.scale[1],
            .flip_x = self.flip_x,
            .flip_y = self.flip_y,
            .rotation = self.rotation,
        };
    }
};
