//! Reusable framebuffer-log decoder and lossless PNG encoder.
pub const Frame = @import("decode.zig").Frame;
pub const decode = @import("decode.zig").decode;
pub const encodePng = @import("png.zig").encode;

test {
    _ = @import("decode.zig");
    _ = @import("png.zig");
}
