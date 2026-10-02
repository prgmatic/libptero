const std = @import("std");
const rsp = @import("../rsp/rsp.zig");
const rdp = @import("rdp.zig");
const cache = @import("../cpu/cache.zig");

/// RDP rendering through the built-in RSP runtime, independent of geometry.
/// Contains command storage and two 64 KiB RDP buffers; initializes in place
/// without heap allocation. Keep its address stable until work completes.
/// One renderer may attach to a runtime at a time.
pub const Renderer = struct {
    runtime: *rsp.Runtime,
    queue: rsp.Queue,
    render: rdp.DefaultRenderQueue,
    rdp_buffers: [2][rsp.rdp_dynamic_buffer_len]u8 align(16),
    geometry_attached: bool,

    /// Borrow a runtime without loading or replacing its resident program.
    pub fn init(self: *Renderer, runtime: *rsp.Runtime) void {
        std.debug.assert(!runtime.renderer_attached);
        self.runtime = runtime;
        self.queue.init(.low);
        @memset(std.mem.asBytes(&self.rdp_buffers), 0);
        cache.writebackData(&self.rdp_buffers);
        self.render = rdp.DefaultRenderQueue.init(rdp.OverlayQueue.init(
            &self.queue,
            &runtime.rdp_overlay,
            .{ self.rdp_buffers[0][0..], self.rdp_buffers[1][0..] },
        ));
        self.geometry_attached = false;
        runtime.renderer_attached = true;
    }

    /// Bind borrowed frame targets and perform explicitly requested clears.
    /// Previous frame work must be complete. Does not allocate, submit, or wait.
    pub fn beginFrame(self: *Renderer, image: anytype, options: rdp.FrameOptions(@TypeOf(image).Pixel)) void {
        self.render.beginFrame(image, options);
    }

    pub fn submit(self: *Renderer) rdp.Completion {
        return self.render.submit();
    }

    /// Deinitialize geometry first. All rendering and borrowed command blocks
    /// must be complete; teardown does not cancel work or free caller storage.
    pub fn deinit(self: *Renderer) void {
        std.debug.assert(!self.geometry_attached);
        std.debug.assert(!self.queue.storage.syncpoint_pending);
        rsp.halt();
        rsp.waitHalted();
        rsp.releaseRdpToDirect();
        self.runtime.renderer_attached = false;
        self.* = undefined;
    }
};
