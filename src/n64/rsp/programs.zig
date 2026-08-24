const UCode = @import("ucode.zig").UCode;
const assets = @import("libptero_rsp_assets");

pub const command_dispatcher_rsp align(8) = assets.command_dispatcher;
pub const command_dispatcher = UCode.fromBlob(&command_dispatcher_rsp);

pub const static_overlay_rsp align(8) = assets.static_overlay;
pub const static_overlay = UCode.fromBlob(&static_overlay_rsp);

pub const static_overlay_2_rsp align(8) = assets.static_overlay_2;
pub const static_overlay_2 = UCode.fromBlob(&static_overlay_2_rsp);

pub const multi_slot_overlay_rsp align(8) = assets.multi_slot_overlay;
pub const multi_slot_overlay = UCode.fromBlob(&multi_slot_overlay_rsp);

pub const rdp_overlay_rsp align(8) = assets.rdp_overlay;
pub const rdp_overlay = UCode.fromBlob(&rdp_overlay_rsp);
