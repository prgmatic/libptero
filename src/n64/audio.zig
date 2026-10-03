pub const mixer = @import("audio/mixer.zig");
pub const output = @import("audio/output.zig");
pub const Output = output.Output;
pub const Sample = @import("audio/sample.zig").Sample;
pub const StreamSample = @import("audio/stream.zig").Sample;
pub const Stream = @import("audio/stream.zig").Stream;

test {
    _ = mixer;
    _ = output;
    _ = @import("audio/sample.zig");
    _ = @import("audio/stream.zig");
}
