const std = @import("std");

pub const Format = enum(u8) {
    rgba16 = 2,
    rgba32 = 3,
    yuv16 = 6,
    ci4 = 8,
    ci8 = 9,
    ia4 = 12,
    ia8 = 13,
    ia16 = 14,
    i4 = 16,
    i8 = 17,

    pub fn parse(text: []const u8) ?Format {
        inline for (std.meta.fields(Format)) |field| {
            if (std.ascii.eqlIgnoreCase(text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn name(self: Format) []const u8 {
        return switch (self) {
            .rgba16, .rgba32, .yuv16 => directColorName(self),
            .ci4, .ci8 => indexedColorName(self),
            .ia4, .ia8, .ia16 => alphaIntensityName(self),
            .i4, .i8 => intensityName(self),
        };
    }
};

fn directColorName(format: Format) []const u8 {
    return switch (format) {
        .rgba16 => "RGBA16",
        .rgba32 => "RGBA32",
        .yuv16 => "YUV16",
        else => unreachable,
    };
}

fn indexedColorName(format: Format) []const u8 {
    return switch (format) {
        .ci4 => "CI4",
        .ci8 => "CI8",
        else => unreachable,
    };
}

fn alphaIntensityName(format: Format) []const u8 {
    return switch (format) {
        .ia4 => "IA4",
        .ia8 => "IA8",
        .ia16 => "IA16",
        else => unreachable,
    };
}

fn intensityName(format: Format) []const u8 {
    return switch (format) {
        .i4 => "I4",
        .i8 => "I8",
        else => unreachable,
    };
}

pub const Dither = enum { none, ordered };
pub const Mipmap = enum { none, box };

pub const Options = struct {
    format: ?Format = null,
    dither: Dither = .none,
    mipmap: Mipmap = .none,
    gamma_correct: bool = false,
};

pub const Result = struct {
    texels: []u8,
    palette: []u8,
    format: Format,
    width: u32,
    height: u32,
    levels: u8,
    base_texel_bytes: usize,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.texels);
        allocator.free(self.palette);
    }
};
