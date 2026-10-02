const rsp = @import("../../rsp/rsp.zig");
const interrupt = @import("../../interrupt.zig");

pub const WaitOptions = struct {
    /// Maximum unsuccessful polls, not an elapsed-time duration.
    max_attempts: u32 = 100_000_000,
};
pub const WaitError = error{ RspTimeout, RdpFenceTimeout };
pub const Status = enum { complete, rsp_pending, rdp_pending };

/// Completion of a submitted render batch. Copies refer to the same work.
/// Keep the queue and all borrowed render resources alive until completion.
/// Only one RDP fence and one RSP syncpoint may be outstanding at a time.
pub const Completion = struct {
    rdp: interrupt.RdpFence,
    rsp: ?rsp.Syncpoint = null,

    /// Polls both processors without waiting. Polling acknowledges completion
    /// signals, including the DP interrupt needed by the resident RSP program.
    pub fn poll(self: Completion) Status {
        const rdp_complete = self.rdp.isComplete();
        const rsp_complete = if (self.rsp) |point| point.isComplete() else true;
        if (!rsp_complete) return .rsp_pending;
        return if (rdp_complete) .complete else .rdp_pending;
    }

    pub fn isComplete(self: Completion) bool {
        return self.poll() == .complete;
    }

    /// A timeout leaves the completion valid for polling or retrying. Do not
    /// release borrowed resources merely because a wait timed out.
    pub fn wait(self: Completion, options: WaitOptions) WaitError!void {
        try waitFor(self, options);
    }
};

fn waitFor(poller: anytype, options: WaitOptions) WaitError!void {
    var remaining = options.max_attempts;
    while (true) {
        switch (poller.poll()) {
            .complete => return,
            .rsp_pending => if (remaining == 0) return error.RspTimeout,
            .rdp_pending => if (remaining == 0) return error.RdpFenceTimeout,
        }
        remaining -= 1;
    }
}

test "waiting identifies the stalled processor and permits retry" {
    const std = @import("std");
    const Poller = struct {
        status: Status,
        polls: usize = 0,
        pub fn poll(self: *@This()) Status {
            self.polls += 1;
            return self.status;
        }
    };
    var progress: Poller = .{ .status = .rsp_pending };
    try std.testing.expectError(error.RspTimeout, waitFor(&progress, .{ .max_attempts = 2 }));
    try std.testing.expectEqual(@as(usize, 3), progress.polls);
    progress.status = .rdp_pending;
    try std.testing.expectError(error.RdpFenceTimeout, waitFor(&progress, .{ .max_attempts = 0 }));
    progress.status = .complete;
    try waitFor(&progress, .{ .max_attempts = 0 });
}

test "waiting polls through RSP and RDP progress without allocating" {
    const std = @import("std");
    const Poller = struct {
        index: usize = 0,
        pub fn poll(self: *@This()) Status {
            const statuses = [_]Status{ .rsp_pending, .rdp_pending, .complete };
            const status = statuses[self.index];
            self.index += 1;
            return status;
        }
    };
    var progress: Poller = .{};
    try waitFor(&progress, .{ .max_attempts = 2 });
    try std.testing.expectEqual(@as(usize, 3), progress.index);
}
