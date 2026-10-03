pub const mixer = @import("audio/mixer.zig");
pub const output = @import("audio/output.zig");
pub const Output = output.Output;
pub const Sample = @import("audio/sample.zig").Sample;

test {
    _ = mixer;
    _ = output;
    _ = @import("audio/sample.zig");
}
