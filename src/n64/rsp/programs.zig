const Program = @import("Program.zig");
const assets = @import("libptero_rsp_assets");

pub const command_dispatcher_rsp align(8) = assets.command_dispatcher;
pub const command_dispatcher = Program.fromBlob(&command_dispatcher_rsp);
pub const command_dispatcher_symbols = assets.command_dispatcher_symbols;

pub const rdp_overlay_rsp align(8) = assets.rdp_overlay;
pub const rdp_overlay = Program.fromBlob(&rdp_overlay_rsp);

pub const audio_mixer_rsp align(8) = assets.audio_mixer;
pub const audio_mixer = Program.fromBlob(&audio_mixer_rsp);
pub const audio_mixer_symbols = assets.audio_mixer_symbols;

pub const audio_vadpcm_rsp align(8) = assets.audio_vadpcm;
pub const audio_vadpcm = Program.fromBlob(&audio_vadpcm_rsp);
pub const audio_vadpcm_symbols = assets.audio_vadpcm_symbols;

pub const geometry_overlay_rsp align(8) = assets.geometry_overlay;
pub const geometry_overlay = Program.fromBlob(&geometry_overlay_rsp);
pub const geometry_overlay_symbols = assets.geometry_overlay_symbols;
pub const geometry_clipping_rsp align(8) = assets.geometry_clipping;
pub const geometry_clipping = Program.fromBlob(&geometry_clipping_rsp);
pub const geometry_clipping_symbols = assets.geometry_clipping_symbols;
