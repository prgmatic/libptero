//! Shared flat colors and clipped CPU text for emergency report pages.
const model = @import("model.zig");
const text = @import("font.zig");
pub const fonts = text.assets;
pub const Pixel = @import("../../graphics/color.zig").Rgba16;
pub const Image = @import("../../graphics/image.zig").ImgRgba16;
pub const bg = Pixel.fromInt(0x17191eff);
pub const header = Pixel.fromInt(0x202229ff);
pub const panel = Pixel.fromInt(0x252832ff);
pub const rule = Pixel.fromInt(0x383c46ff);
pub const fg = Pixel.fromInt(0xdde2ebff);
pub const muted = Pixel.fromInt(0x929caaff);
pub const violet = Pixel.fromInt(0xb494ecff);
pub const cyan = Pixel.fromInt(0x78cce4ff);
pub const amber = Pixel.fromInt(0xf0bc70ff);
pub const body_clip: text.Clip = .{ .left = 26, .top = model.viewport_top, .right = 608, .bottom = model.viewport_bottom };

pub fn pane(img: Image) void {
    img.fillRegion(panel, 16, model.viewport_top, 592, model.viewport_height);
}

pub fn label(img: Image, str: []const u8, x: i32, y: i32) void {
    text.drawClipped(img, muted, fonts.small, str, x, y, body_clip);
}

pub fn value(img: Image, str: []const u8, x: i32, y: i32) void {
    text.drawClipped(img, cyan, fonts.data, str, x, y, body_clip);
}

pub fn keyHint(img: Image, x: u16, key: []const u8, action: []const u8) void {
    img.fillRegion(violet, x, 221, 17, 16);
    img.fillRegion(bg, x + 1, 222, 15, 14);
    text.draw(img, fg, fonts.small, key, x + 6, 233);
    text.draw(img, fg, fonts.ui, action, x + 24, 233);
}
