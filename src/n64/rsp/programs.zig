const UCode = @import("ucode.zig").UCode;
const assets = @import("libptero_rsp_assets");

pub const command_dispatcher_rsp align(8) = assets.command_dispatcher;
pub const command_dispatcher = UCode.fromBlob(&command_dispatcher_rsp);
pub const command_dispatcher_symbols = assets.command_dispatcher_symbols;

pub const rdp_overlay_rsp align(8) = assets.rdp_overlay;
pub const rdp_overlay = UCode.fromBlob(&rdp_overlay_rsp);

pub const geometry_overlay_rsp align(8) = assets.geometry_overlay;
pub const geometry_overlay = UCode.fromBlob(&geometry_overlay_rsp);
pub const geometry_overlay_symbols = assets.geometry_overlay_symbols;
pub const geometry_clipping_rsp align(8) = assets.geometry_clipping;
pub const geometry_clipping = UCode.fromBlob(&geometry_clipping_rsp);
pub const geometry_clipping_symbols = assets.geometry_clipping_symbols;
