const rsp = @import("../rsp/rsp.zig");
const rdp_api = @import("rdp.zig");
const RdpRenderer = @import("renderer.zig").Renderer;
const Context = @import("geometry.zig").Context;

/// Owns the built-in runtime, RDP renderer, and geometry context in one place.
/// Initialize in persistent storage and keep its address stable. Contains all
/// command storage; initialization allocates no heap memory. Display and image
/// storage remain separately owned by the caller.
pub const Renderer = struct {
    runtime: rsp.Runtime,
    rdp: RdpRenderer,
    geometry: Context,

    /// Start an exclusive hardware session with geometry enabled.
    pub fn init(self: *Renderer) void {
        self.runtime.init();
        self.rdp.init(&self.runtime);
        self.geometry.init(&self.rdp);
    }

    /// Borrow frame targets. Previous GPU work must be complete.
    pub fn beginFrame(self: *Renderer, image: anytype, options: rdp_api.FrameOptions(@TypeOf(image).Pixel)) void {
        self.geometry.beginFrame(image, options);
    }

    /// Submit geometry and RDP work together without waiting or presenting.
    pub fn submit(self: *Renderer) rdp_api.Completion {
        return self.geometry.submit();
    }

    /// Complete GPU work first. Tears down components in dependency order;
    /// does not free display/image storage or wait for unfinished submissions.
    pub fn deinit(self: *Renderer) void {
        self.geometry.deinit();
        self.rdp.deinit();
        self.runtime.deinit();
        self.* = undefined;
    }
};
