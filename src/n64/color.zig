
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
            .r = @intCast((value >> 19) & 0x1F), 
            .g = @intCast((value >> 11) & 0x1F),
            .b = @intCast((value >> 3)  & 0x1F), 
            .a = @intCast((value >> 31) & 1),
        };
    }

    pub fn fromU8s(r: u8, g: u8, b: u8, a: u8) Rgba5551 {
        return .{
            .r = r >> 3,
            .g = g >> 3,
            .b = b >> 3,
            .a = a >> 7,
        };
    }
};


