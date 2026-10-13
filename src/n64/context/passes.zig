//! Borrowed pass handles; beginning another pass invalidates all earlier copies.
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
        frame: Context.Frame,
        generation: u64,
        pipeline: options.GeometryPipeline,

        /// Borrow the fixed transform and asset payloads until completion.
        pub fn drawModel(self: @This(), asset: anytype, transform: *const math.FixedMat4) !void {
            try validate(self.frame, self.generation);
            self.pipeline.apply(&self.frame.context.geometry);
            self.frame.context.geometry.drawModelWithTransform(asset, transform);
        }

        /// Record immutable geometry/materials once in caller-owned persistent storage.
        /// Pipeline/material commands are captured. Camera, lighting and pose remain dynamic.
        pub fn recordModel(self: @This(), recorded: anytype, asset: anytype) !void {
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
        frame: Context.Frame,
        generation: u64,
        options: options.OverlayOptions,

        fn prepare(self: @This()) !void {
            try validate(self.frame, self.generation);
            const render = &self.frame.context.renderer.render;
            self.options.pipeline.apply(render);
        }

        pub fn drawSprite(self: @This(), image: anytype, opts: options.SpriteOptions) !void {
            try validate(self.frame, self.generation);
            try opts.validate(image.width, image.height);
            if (opts.scale[0] == 0 or opts.scale[1] == 0) return;
            try self.prepare();
            const render = &self.frame.context.renderer.render;
            render.setPrimColor(opts.tint);
            render.drawSprite(image, opts.position[0], opts.position[1], opts.drawOptions());
        }

        /// Text coordinates use the first baseline. Font-specific state is local to this draw.
        pub fn drawText(self: @This(), font: graphics.font.Font, x: f32, y: f32, text: []const u8, opts: graphics.font.TextOptions) !void {
            try self.prepare();
            _ = try font.draw(&self.frame.context.renderer.render, x, y, text, opts);
        }

        /// Scratch is consumed during recording and may be reused immediately.
        /// A formatting failure emits no commands.
        pub fn drawTextPrint(self: @This(), font: graphics.font.Font, x: f32, y: f32, scratch: []u8, opts: graphics.font.TextOptions, comptime fmt: []const u8, args: anytype) !void {
            try validate(self.frame, self.generation);
            const text = try std.fmt.bufPrint(scratch, fmt, args);
            try self.drawText(font, x, y, text, opts);
        }
    };
}
