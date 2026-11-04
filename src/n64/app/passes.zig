//! Borrowed pass handles; beginning another pass invalidates all earlier copies.
//! Overlay passes emit their pipeline once; code that drives the renderer
//! directly in the middle of a pass must restore that state itself.
const std = @import("std");
const graphics = @import("../graphics.zig");
const math = @import("../math.zig");
const options = @import("pass_options.zig");

fn validate(frame: anytype, generation: u64) !void {
    if (frame.generation != frame.context.generation or frame.context.state == .idle) return error.InvalidFrame;
    if (frame.context.state != .recording) return error.FrameSubmitted;
    if (generation != frame.context.pass_generation) return error.InvalidPass;
}

pub fn GeometryPass(comptime Context: type) type {
    return struct {
        pub const Options = options.GeometryOptions;
        pub const State = options.GeometryPipeline;
        frame: Context.Frame,
        generation: u64,
        pipeline: options.GeometryPipeline,

        /// Borrow the fixed transform and asset payloads until completion.
        pub fn drawModel(self: @This(), asset: graphics.ModelAsset, transform: *const math.FixedMat4) !void {
            try validate(self.frame, self.generation);
            self.pipeline.apply(&self.frame.context.geometry);
            self.frame.context.geometry.drawModelWithTransform(asset, transform);
        }

        /// Record immutable geometry/materials once in caller-owned persistent storage.
        /// Pipeline/material commands are captured. Camera, lighting and pose remain dynamic.
        pub fn recordModel(self: @This(), recorded: anytype, asset: graphics.ModelAsset) !void {
            try validate(self.frame, self.generation);
            self.pipeline.apply(&self.frame.context.geometry);
            self.frame.context.geometry.recordModel(recorded, asset);
        }

        /// Borrow the recorded commands and fixed transform until completion.
        pub fn drawRecorded(self: @This(), recorded: anytype, transform: *const math.FixedMat4) !void {
            try validate(self.frame, self.generation);
            self.pipeline.apply(&self.frame.context.geometry);
            self.frame.context.geometry.drawRecordedWithTransform(recorded, transform);
        }

        /// Bind fixed global bone matrices without copying. Keep them unchanged until completion.
        pub fn setPose(self: @This(), matrices: []const math.FixedMat4) !void {
            try validate(self.frame, self.generation);
            if (matrices.len == 0) return error.EmptyPose;
            self.frame.context.geometry.setPose(matrices);
        }
    };
}

pub fn OverlayPass(comptime Context: type) type {
    return struct {
        const Pass = @This();
        pub const Options = options.OverlayOptions;
        pub const State = options.OverlayPipeline;
        pub const SpriteOptions = options.SpriteOptions;
        frame: Context.Frame,
        generation: u64,
        options: options.OverlayOptions,

        /// Re-applies the pass pipeline only after text changed it.
        fn prepare(self: @This()) void {
            const overlay = &self.frame.context.overlay;
            if (overlay.applied) return;
            self.options.pipeline.apply(&self.frame.context.renderer.render);
            overlay.applied = true;
        }

        pub fn drawSprite(self: @This(), image: anytype, opts: options.SpriteOptions) !void {
            try validate(self.frame, self.generation);
            try opts.validate(image.width, image.height);
            if (opts.scale[0] == 0 or opts.scale[1] == 0) return;
            self.prepare();
            const render = &self.frame.context.renderer.render;
            // The encoder skips a repeated tint; primitive color needs no sync.
            render.setPrimColor(opts.tint);
            render.drawSprite(image, opts.position[0], opts.position[1], opts.drawOptions());
        }

        /// Text coordinates use the first baseline. Font-specific state is local to this draw.
        /// The font sets every state it relies on from the pass baseline, and
        /// reapplying it is idempotent, so consecutive text needs no reset.
        pub fn drawText(self: @This(), font: graphics.Font, x: f32, y: f32, text: []const u8, opts: graphics.Font.DrawOptions) !void {
            try validate(self.frame, self.generation);
            self.frame.context.overlay.applied = false;
            _ = try font.draw(&self.frame.context.renderer.render, x, y, text, opts);
        }

        /// Draw many sprites from one image: the texture is bound once and each
        /// draw emits only a changed tint and its rectangle. The batch is a
        /// borrowed handle like the pass, and rebinds by itself after text or
        /// texture eviction in between.
        pub fn sprites(self: @This(), image: anytype) !SpriteBatch(@TypeOf(image)) {
            try validate(self.frame, self.generation);
            return .{ .pass = self, .image = image };
        }

        pub fn SpriteBatch(comptime Image: type) type {
            return struct {
                pass: Pass,
                image: Image,
                tile: u3 = 0,
                epoch: ?u32 = null,

                pub fn draw(batch: *@This(), opts: options.SpriteOptions) !void {
                    try validate(batch.pass.frame, batch.pass.generation);
                    try opts.validate(batch.image.width, batch.image.height);
                    if (opts.scale[0] == 0 or opts.scale[1] == 0) return;
                    const context = batch.pass.frame.context;
                    const render = &context.renderer.render;
                    if (!context.overlay.applied or batch.epoch != render.texture_epoch) {
                        batch.pass.prepare();
                        batch.tile = render.bindSprite(batch.image, 0);
                        batch.epoch = render.texture_epoch;
                    }
                    render.setPrimColor(opts.tint);
                    render.drawSpriteOnTile(batch.tile, batch.image.width, batch.image.height, opts.position[0], opts.position[1], opts.drawOptions());
                }
            };
        }

        /// Opaque rectangle in whole pixels, drawn in fill mode: the fastest way
        /// to cover large areas, but it ignores the pass blend and combiner.
        pub fn fillRect(self: @This(), x: u16, y: u16, w: u16, h: u16, color: graphics.pixel.Rgba32) !void {
            try validate(self.frame, self.generation);
            const pixel = Context.Pixel.fromBytes(color.r, color.g, color.b, color.a);
            self.frame.context.renderer.render.fillRectangle(x, y, w, h, pixel);
        }

        /// Flat-colored rectangle blended with the pass's blend mode; the color's
        /// alpha is its coverage. Swaps the pass combiner for a flat one, so group
        /// rectangles together rather than alternating them with sprites.
        pub fn drawRect(self: @This(), x: f32, y: f32, w: f32, h: f32, color: graphics.pixel.Rgba32) !void {
            try validate(self.frame, self.generation);
            for ([_]f32{ x, y, w, h }) |value| if (!std.math.isFinite(value)) return error.InvalidRect;
            const context = self.frame.context;
            const render = &context.renderer.render;
            self.prepare();
            render.setCombineMode(.primitive);
            context.overlay.applied = false;
            render.setPrimColor(color);
            render.shadeRectangle(x, y, w, h);
        }

        /// Scratch is consumed during recording and may be reused immediately.
        /// A formatting failure emits no commands.
        pub fn drawTextPrint(self: @This(), font: graphics.Font, x: f32, y: f32, scratch: []u8, opts: graphics.Font.DrawOptions, comptime fmt: []const u8, args: anytype) !void {
            try validate(self.frame, self.generation);
            const text = try std.fmt.bufPrint(scratch, fmt, args);
            try self.drawText(font, x, y, text, opts);
        }
    };
}
