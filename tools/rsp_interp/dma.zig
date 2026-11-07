//! SP DMA engine: one transfer in flight plus one pending, each finishing a
//! calibrated number of cycles after it starts. Data moves when a transfer
//! completes, so microcode that touches a buffer too early reads stale bytes;
//! `check` reports such accesses as hazards instead of letting them pass.
//!
//! Costs come from the `dma_*` calibration benchmarks recorded on hardware.
const std = @import("std");

pub const Direction = enum { to_rsp, to_rdram };

/// The programmed registers of one transfer.
pub const Descriptor = struct {
    /// DMEM/IMEM byte address; bit 12 selects IMEM.
    mem_address: u13 = 0,
    dram_address: u24 = 0,
    length: u12 = 0,
    count: u8 = 0,
    skip: u12 = 0,

    pub fn rowBytes(self: Descriptor) u32 {
        return @as(u32, self.length) + 8;
    }

    pub fn rows(self: Descriptor) u32 {
        return @as(u32, self.count) + 1;
    }

    /// Bytes moved; RSP memory receives them contiguously.
    pub fn totalBytes(self: Descriptor) u32 {
        return self.rowBytes() * self.rows();
    }
};

pub const Transfer = struct {
    descriptor: Descriptor,
    direction: Direction,
    done_at: u64,

    /// True when `address` (13-bit, bit 12 selecting IMEM) lies in the RSP
    /// memory this transfer reads or writes. The range wraps within its bank.
    pub fn covers(self: Transfer, address: u32) bool {
        const start: u32 = self.descriptor.mem_address;
        if ((address ^ start) & 0x1000 != 0) return false;
        const offset = (address -% start) & 0xfff;
        return offset < @min(self.descriptor.totalBytes(), 0x1000);
    }
};

pub const Cost = struct {
    /// Cycles for a transfer of up to `free_bytes`.
    latency: u32,
    /// Cycles per 256 bytes beyond `free_bytes`.
    per_256_bytes: u32,
    per_extra_row: u32,

    /// Bytes the start-up latency already covers: hardware times 8- and
    /// 64-byte transfers almost alike.
    const free_bytes = 24;

    pub fn of(self: Cost, descriptor: Descriptor) u64 {
        const bytes: u64 = descriptor.totalBytes() -| free_bytes;
        return self.latency + (bytes * self.per_256_bytes + 255) / 256 + (descriptor.rows() - 1) * self.per_extra_row;
    }
};

pub const read_cost: Cost = .{ .latency = 18, .per_256_bytes = 40, .per_extra_row = 5 };
pub const write_cost: Cost = .{ .latency = 10, .per_256_bytes = 38, .per_extra_row = 3 };

pub fn cost(direction: Direction, descriptor: Descriptor) u64 {
    return (if (direction == .to_rsp) read_cost else write_cost).of(descriptor);
}

pub const Access = enum { load, store, fetch };

pub const Hazard = struct {
    pc: u32,
    /// 13-bit RSP address; bit 12 selects IMEM.
    address: u32,
    access: Access,
    direction: Direction,
};

pub const Queue = struct {
    /// `slots[0]` is in flight; `slots[1]` waits behind it.
    slots: [2]?Transfer = .{ null, null },

    pub fn busy(self: *const Queue) bool {
        return self.slots[0] != null;
    }

    pub fn full(self: *const Queue) bool {
        return self.slots[1] != null;
    }

    pub fn push(self: *Queue, descriptor: Descriptor, direction: Direction, now: u64) error{DmaQueueFull}!void {
        if (self.full()) return error.DmaQueueFull;
        const start = if (self.slots[0]) |first| @max(now, first.done_at) else now;
        const transfer: Transfer = .{ .descriptor = descriptor, .direction = direction, .done_at = start + cost(direction, descriptor) };
        if (self.slots[0] == null) self.slots[0] = transfer else self.slots[1] = transfer;
    }

    /// Removes and returns the in-flight transfer if it has finished by `now`.
    pub fn popFinished(self: *Queue, now: u64) ?Transfer {
        const first = self.slots[0] orelse return null;
        if (first.done_at > now) return null;
        return self.popFront();
    }

    pub fn popFront(self: *Queue) ?Transfer {
        const first = self.slots[0];
        self.slots = .{ self.slots[1], null };
        return first;
    }

    /// The transfer an access conflicts with: reads of memory a transfer
    /// has not filled yet, and writes to memory a transfer has not finished
    /// reading or filling.
    pub fn conflict(self: *const Queue, address: u32, access: Access) ?Transfer {
        for (self.slots) |maybe| {
            const transfer = maybe orelse continue;
            if (!transfer.covers(address)) continue;
            if (access == .store or transfer.direction == .to_rsp) return transfer;
        }
        return null;
    }
};

const testing = std.testing;

test "transfers queue behind the one in flight and finish in order" {
    var queue: Queue = .{};
    const small: Descriptor = .{ .length = 0 };
    try queue.push(small, .to_rsp, 100);
    try queue.push(small, .to_rdram, 100);
    try testing.expect(queue.busy() and queue.full());
    try testing.expectError(error.DmaQueueFull, queue.push(small, .to_rsp, 100));
    const first_done = 100 + cost(.to_rsp, small);
    try testing.expectEqual(@as(?Transfer, null), queue.popFinished(first_done - 1));
    try testing.expectEqual(Direction.to_rsp, queue.popFinished(first_done).?.direction);
    try testing.expectEqual(first_done + cost(.to_rdram, small), queue.slots[0].?.done_at);
    try testing.expect(!queue.full());
}

test "costs grow with bytes and rows" {
    const one_row: Descriptor = .{ .length = 56 };
    const eight_rows: Descriptor = .{ .length = 56, .count = 7 };
    try testing.expectEqual(@as(u64, 18 + 7), cost(.to_rsp, one_row));
    try testing.expectEqual(@as(u64, 18 + 77 + 35), cost(.to_rsp, eight_rows));
    try testing.expectEqual(@as(u64, 10 + 6), cost(.to_rdram, one_row));
}

test "hazards cover the transfer's RSP range in its own bank" {
    var queue: Queue = .{};
    try queue.push(.{ .mem_address = 0xff8, .length = 8 }, .to_rsp, 0);
    try testing.expect(queue.conflict(0xff8, .load) != null);
    try testing.expect(queue.conflict(0x007, .load) != null);
    try testing.expect(queue.conflict(0x008, .load) == null);
    try testing.expect(queue.conflict(0x1ff8, .fetch) == null);
    _ = queue.popFront();
    try queue.push(.{ .mem_address = 0x100, .length = 0 }, .to_rdram, 0);
    try testing.expect(queue.conflict(0x104, .load) == null);
    try testing.expect(queue.conflict(0x104, .store) != null);
}
