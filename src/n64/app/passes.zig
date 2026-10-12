//! Borrowed pass handles; beginning another pass invalidates all earlier copies.
const std = @import("std");
const graphics = @import("../graphics.zig");
const math = @import("../math.zig");
const options = @import("pass_options.zig");

fn validate(frame: anytype, generation: u64) !void {
    if (frame.generation != frame.app.generation or frame.app.state == .idle) return error.InvalidFrame;
    if (frame.app.state != .recording) return error.FrameSubmitted;
    if (generation != frame.app.pass_generation) return error.InvalidPass;
}

pub fn GeometryPass(comptime App: type) type {
    return struct {
        frame: App.Frame,
        generation: u64,
        pipeline: options.GeometryPipeline,

        pub fn drawModel(self: @This(), asset: anytype, transform: math.Mat4) !void {
            try validate(self.frame, self.generation);
            const matrix = try self.frame.app.uploads.matrix(transform);
            self.pipeline.apply(&self.frame.app.geometry);
            self.frame.app.geometry.drawModelWithTransform(asset, matrix);
        }

        /// Borrow a persistent transform without copying. Keep it unchanged until completion.
        pub fn drawModelBorrowed(self: @This(), asset: anytype, transform: *const math.FixedMat4) !void {
            try validate(self.frame, self.generation);
            self.pipeline.apply(&self.frame.app.geometry);
            self.frame.app.geometry.drawModelWithTransform(asset, transform);
        }

        /// Record immutable geometry/materials once in caller-owned persistent storage.
        /// Pipeline/material commands are captured. Camera, lighting and pose remain dynamic.
        pub fn recordModel(self: @This(), recorded: anytype, asset: anytype) !void {
            try validate(self.frame, self.generation);
            self.pipeline.apply(&self.frame.app.geometry);
            self.frame.app.geometry.recordModel(recorded, asset);
        }

        pub fn drawRecorded(self: @This(), recorded: anytype, transform: math.Mat4) !void {
            try validate(self.frame, self.generation);
            const matrix = try self.frame.app.uploads.matrix(transform);
            self.pipeline.apply(&self.frame.app.geometry);
            self.frame.app.geometry.drawRecordedWithTransform(recorded, matrix);
        }

        pub fn drawRecordedBorrowed(self: @This(), recorded: anytype, transform: *const math.FixedMat4) !void {
            try validate(self.frame, self.generation);
            self.pipeline.apply(&self.frame.app.geometry);
            self.frame.app.geometry.drawRecordedWithTransform(recorded, transform);
        }

        /// Snapshot fixed global bone matrices. The caller may immediately reuse the source.
        pub fn setPose(self: @This(), matrices: []const math.FixedMat4) !void {
            try validate(self.frame, self.generation);
            self.frame.app.geometry.setPose(try self.frame.app.uploads.pose(matrices));
        }

        /// Bind an already persistent pose; its storage remains borrowed until completion.
        pub fn setPoseBorrowed(self: @This(), matrices: []const math.FixedMat4) !void {
            try validate(self.frame, self.generation);
            if (matrices.len == 0) return error.EmptyPose;
            self.frame.app.geometry.setPose(matrices);
        }
    };
}

pub fn OverlayPass(comptime App: type) type {
    return struct {
        frame: App.Frame,
        generation: u64,
        options: options.OverlayOptions,

        fn prepare(self: @This()) !void {
            try validate(self.frame, self.generation);
            const render = &self.frame.app.renderer.render;
            render.setState(self.options.state());
            render.cmd_queue.pipeSync();
        }

        pub fn drawSprite(self: @This(), image: anytype, opts: options.SpriteOptions) !void {
            try validate(self.frame, self.generation);
            try opts.validate(image.width, image.height);
            if (opts.scale[0] == 0 or opts.scale[1] == 0) return;
            try self.prepare();
            const render = &self.frame.app.renderer.render;
            render.setPrimColor(opts.tint);
            render.drawSprite(image, opts.position[0], opts.position[1], opts.drawOptions());
        }

        /// Text coordinates use the first baseline. Font-specific state is local to this draw.
        pub fn drawText(self: @This(), font: graphics.font.Font, x: f32, y: f32, text: []const u8, opts: graphics.font.TextOptions) !void {
            try self.prepare();
            _ = try font.draw(&self.frame.app.renderer.render, x, y, text, opts);
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
