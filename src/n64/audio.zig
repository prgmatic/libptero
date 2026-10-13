//! Resident and streamed audio on a shared RSP runtime.
pub const Player = @import("audio/Player.zig");
pub const Voice = Player.Voice;
pub const Mixer = @import("audio/Mixer.zig");
pub const Output = @import("audio/Output.zig");
pub const Sample = @import("audio/Sample.zig");
pub const StreamSample = @import("audio/StreamSample.zig");
pub const Stream = @import("audio/Stream.zig");
pub const vadpcm = @import("audio/vadpcm.zig");
test {
    _ = Player;
    _ = Mixer;
    _ = Output;
    _ = Sample;
    _ = StreamSample;
    _ = Stream;
    _ = vadpcm;
}
