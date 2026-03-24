
pub const Rgba5551 = packed struct(u16) {
    a: u1,
    b: u5,
    g: u5,
    r: u5,

    pub fn init(r: u5, g: u5, b: u5, a: 1) Rgba5551 {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub fn fromU32(value: u32) Rgba5551 {
        return .{
            .r = @intCast((value >> 27) & 0x1F), 
            .g = @intCast((value >> 19) & 0x1F),
            .b = @intCast((value >> 11)  & 0x1F), 
            .a = @intCast((value >> 7) & 1),
        };
    }

    pub fn fromU8s(r: u8, g: u8, b: u8, a: u8) Rgba5551 {
        return .{
            .r = @intCast(r >> 3),
            .g = @intCast(g >> 3),
            .b = @intCast(b >> 3),
            .a = @intCast(a >> 7),
        };
    }
};

pub const Rgba32 = packed struct(u32) {
    a: u8,
    b: u8,
    g: u8,
    r: u8,
};
