const UCode = @import("ucode.zig").UCode;
const assets = @import("libptero_rsp_assets");

pub const command_dispatcher_rsp align(8) = assets.command_dispatcher;
pub const command_dispatcher = UCode.fromBlob(&command_dispatcher_rsp);

pub const rdp_overlay_rsp align(8) = assets.rdp_overlay;
pub const rdp_overlay = UCode.fromBlob(&rdp_overlay_rsp);
