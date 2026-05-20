// RGBA

/// 32-bit RGBA color with 8 bits per channel.
pub const Rgba32 = packed struct(u32) {
    a: u8,
    b: u8,
    g: u8,
    r: u8,

    pub fn fromInt(int: u32) Rgba32 {
        return @bitCast(int);
    }

    pub fn fromBytes(r: u8, g: u8, b: u8, a: u8) Rgba32 {
        return .{.r = r, .g = g, .b = b, .a = a };
    }

    pub const white: Rgba32 = .fromInt(0xFFFFFFFF);
    pub const black: Rgba32 = .fromInt(0x000000FF);
    pub const red: Rgba32 = .fromInt(0xFF0000FF);
    pub const green: Rgba32 = .fromInt(0x00FF00FF);
    pub const blue: Rgba32 = .fromInt(0x0000FFFF);
    pub const cyan: Rgba32 = .fromInt(0x00FFFFFF);
    pub const magenta: Rgba32 = .fromInt(0xFF00FFFF);
    pub const yellow: Rgba32 = .fromInt(0xFFFF00FF);

    pub const format: Format = .rgba;
    pub const bit_depth: BitDepth = .@"32";
};

/// 16-bit RGBA color with 5 bits per RGB channel and 1 bit alpha.
pub const Rgba16 = packed struct(u16) {
    a: u1,
    b: u5,
    g: u5,
    r: u5,

    pub const white: Rgba16 = .fromInt(0xFFFFFFFF);
    pub const black: Rgba16 = .fromInt(0x000000FF);
    pub const red: Rgba16 = .fromInt(0xFF0000FF);
    pub const green: Rgba16 = .fromInt(0x00FF00FF);
    pub const blue: Rgba16 = .fromInt(0x0000FFFF);
    pub const cyan: Rgba16 = .fromInt(0x00FFFFFF);
    pub const magenta: Rgba16 = .fromInt(0xFF00FFFF);
    pub const yellow: Rgba16 = .fromInt(0xFFFF00FF);

    pub const format: Format = .rgba;
    pub const bit_depth: BitDepth = .@"16";

    pub fn init(r: u5, g: u5, b: u5, a: 1) Rgba16 {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn fromInt(value: u32) Rgba16 {
        return .{
            .r = @intCast((value >> 27) & 0x1F), 
            .g = @intCast((value >> 19) & 0x1F),
            .b = @intCast((value >> 11)  & 0x1F), 
            .a = @intCast((value >> 7) & 1),
        };
    }

    pub fn fromBytes(r: u8, g: u8, b: u8, a: u8) Rgba16 {
        return .{
            .r = @intCast(r >> 3),
            .g = @intCast(g >> 3),
            .b = @intCast(b >> 3),
            .a = @intCast(a >> 7),
        };
    }
};

// Intensity Alpha

/// 16-bit intensity+alpha with 8 bits per channel.
pub const Ia16 = packed struct(u16) {
    alpha: u8,
    intensity: u8,

    pub const format: Format = .intensity_alpha;
    pub const bit_depth: BitDepth = .@"16";
};

/// 8-bit intensity+alpha with 4 bits per channel.
pub const Ia8 = packed struct(u8) {
    alpha: u4,
    intensity: u4,

    pub const format: Format = .intensity_alpha;
    pub const bit_depth: BitDepth = .@"8";
};

/// Two 4-bit intensity+alpha texels packed into one byte (2 bits each channel).
pub const Ia4Pair = packed struct(u8) {
    texel1_alpha: u2,
    texel1_intensity: u2,
    texel0_alpha: u2,
    texel0_intensity: u2,

    pub const format: Format = .intensity_alpha;
    pub const bit_depth: BitDepth = .@"4";
};

// Intensity

/// 8-bit grayscale intensity.
pub const I8 = packed struct(u8) {
    intensity: u8,

    pub const format: Format = .intensity;
    pub const bit_depth: BitDepth = .@"8";
};

/// Two 4-bit grayscale intensity texels packed into one byte.
pub const I4Pair = packed struct(u8) {
    texel1_intensity: u4,
    texel0_intensity: u4,

    pub const format: Format = .intensity;
    pub const bit_depth: BitDepth = .@"4";
};

// Color Indexed

/// 8-bit palette color index.
pub const Ci8 = packed struct(u8) {
    index: u8,

    pub const format: Format = .color_indexed;
    pub const bit_depth: BitDepth = .@"8";
};

/// Two 4-bit palette color indices packed into one byte.
pub const Ci4Pair = packed struct(u8) {
    texel0_index: u4,
    texel1_index: u4,

    pub const format: Format = .color_indexed;
    pub const bit_depth: BitDepth = .@"4";
};

pub const Format = enum(u3) {
    rgba,
    yuv,
    color_indexed,
    intensity_alpha,
    intensity,
};

pub const BitDepth = enum(u2) {
    @"4",
    @"8",
    @"16",
    @"32",
};
