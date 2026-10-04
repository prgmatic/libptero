//! Host trace conversion API. No transport, credentials or browser dependency.
pub const Trace = @import("decode.zig").Trace;
pub const decode = @import("decode.zig").decode;
pub const writeJson = @import("output.zig").writeJson;
pub const writeHtml = @import("output.zig").writeHtml;
pub const writeChrome = @import("output.zig").writeChrome;
test {
    _ = @import("tests.zig");
}
