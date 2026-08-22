const UCode = @import("ucode.zig").UCode;

pub const fill_dmem_rsp align(8) = @embedFile("fill_dmem_rsp").*;
pub const fill_dmem = UCode.fromBlob(&fill_dmem_rsp);

pub const command_dispatcher_rsp align(8) = @embedFile("command_dispatcher_rsp").*;
pub const command_dispatcher = UCode.fromBlob(&command_dispatcher_rsp);

pub const static_overlay_rsp align(8) = @embedFile("static_overlay_rsp").*;
pub const static_overlay = UCode.fromBlob(&static_overlay_rsp);

pub const static_overlay_2_rsp align(8) = @embedFile("static_overlay_2_rsp").*;
pub const static_overlay_2 = UCode.fromBlob(&static_overlay_2_rsp);

pub const rdp_overlay_rsp align(8) = @embedFile("rdp_overlay_rsp").*;
pub const rdp_overlay = UCode.fromBlob(&rdp_overlay_rsp);
