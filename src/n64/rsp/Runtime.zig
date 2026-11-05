//! Owns the built-in resident dispatcher and RDP overlay registration. This is
//! an exclusive hardware session, not an allocation. Keep it at a stable address
//! until every attached renderer is deinitialized. Raw RSP APIs remain available
//! for custom resident programs outside this session.

const std = @import("std");
const rsp = @import("../rsp.zig");

const Runtime = @This();

/// Overlay id of the RDP overlay. Its commands occupy queue ids 0xC0-0xFF so
/// each command header doubles as the raw RDP command word it forwards.
pub const rdp_overlay_id = 12;

rdp_overlay: rsp.Overlay,
renderer_attached: bool,
mixer_attached: bool,

/// Halt RSP, load the dispatcher, and register only the RDP overlay. Does
/// not allocate or initialize geometry. Do not replace an active session.
pub fn init(self: *Runtime) void {
    rsp.halt();
    rsp.waitHalted();
    rsp.loadResident(rsp.programs.command_dispatcher);
    self.rdp_overlay.init(rsp.programs.rdp_overlay);
    rsp.registerOverlayStatic(&self.rdp_overlay, rdp_overlay_id);
    self.renderer_attached = false;
    self.mixer_attached = false;
}

/// Detach renderers first and complete all work before teardown.
pub fn deinit(self: *Runtime) void {
    std.debug.assert(!self.renderer_attached);
    std.debug.assert(!self.mixer_attached);
    rsp.unregisterOverlay(&self.rdp_overlay);
    self.* = undefined;
}
