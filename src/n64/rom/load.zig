//! Direct typed-asset DMA lifecycle. Operations specialize for each owner type.
const std = @import("std");

// Zero denotes ordinary embedded images. Each completed load receives a new
// identity so recycled RDRAM addresses cannot hit an old texture/TLUT cache entry.
var next_content_id: u64 = 1;

/// Begin one direct DMA into final storage. PiBusy leaves the owner idle
/// so admission can be retried. Existing loaded views remain valid.
pub fn begin(self: anytype) !void {
    if (self.loading) return error.AssetBusy;
    if (self.value != null) return error.AlreadyLoaded;
    const offset = try self.source.romOffset();
    if (self.bytes.len != 0) try self.transfer.begin(offset, self.bytes);
    self.loading = true;
}

/// Finish metadata binding once. No allocation, staging copy, or decoding.
pub fn poll(self: anytype) !bool {
    if (!self.loading) return self.value != null;
    const complete = self.transfer.poll() catch |err| {
        self.loading = false;
        return err;
    };
    if (!complete) return false;
    self.value = @TypeOf(self.*).Layout.bind(self.bytes[0..self.source.size], &self.metadata, next_content_id);
    next_content_id +%= 1;
    if (next_content_id == 0) next_content_id = 1;
    self.loading = false;
    return true;
}

/// A timeout retains the owner and buffer. Retry wait/load at the same
/// address; deinit/unload reject pending DMA. Call outside interrupts.
pub fn wait(self: anytype, max_attempts: u32) !void {
    if (!self.loading and self.value == null) return error.NotLoaded;
    if (@hasDecl(@TypeOf(self.transfer), "isScheduled")) {
        if (self.transfer.isScheduled()) return error.ScheduledLoadRequiresService;
    }
    var remaining = max_attempts;
    while (!try self.poll()) {
        if (remaining == 0) return error.PiTimeout;
        remaining -= 1;
    }
}

/// Load synchronously or finish a previous timed-out load. A completed
/// owner can be reused without issuing another DMA.
pub fn load(self: anytype, max_attempts: u32) !void {
    if (!self.loading and self.value == null) try self.begin();
    try self.wait(max_attempts);
}

/// O(1) borrowed image/model value, valid until unload/deinit. Keep the
/// owner at a stable address and alive until all RSP/RDP work completes.
pub fn view(self: anytype) !@TypeOf(self.*).Layout.Value {
    return self.value orelse error.NotLoaded;
}

/// Forget residency without freeing storage. The caller must first wait
/// for rendering, skinning and recorded blocks that borrow this asset.
pub fn unload(self: anytype) !void {
    if (self.loading) return error.AssetBusy;
    self.value = null;
}

/// No implicit hardware wait. Pending DMA retains ownership for retry;
/// GPU completion remains the caller's responsibility.
pub fn deinit(self: anytype, allocator: std.mem.Allocator) !void {
    if (self.loading) return error.AssetBusy;
    if (self.owned) allocator.free(self.bytes);
    self.* = undefined;
}
