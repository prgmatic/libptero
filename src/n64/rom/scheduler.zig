//! Cooperative, allocation-free PI scheduling. Poll retires a chunk; dispatch
//! admits the next. Audio can refill between those two operations.
const std = @import("std");
const pi = @import("../io/pi.zig");
pub const Priority = enum(u2) { background, normal, urgent };
pub const Options = struct { chunk_bytes: usize = 4096 };
pub const Scheduler = Queue(8, pi.Transfer);

pub fn Queue(comptime capacity: usize, comptime Dma: type) type {
    if (capacity == 0) @compileError("a scheduler requires at least one slot");
    return struct {
        const Self = @This();
        pub const Ticket = struct { owner: *Self, index: usize, generation: u32 };
        const Job = struct {
            state: enum { free, queued, active, complete, failed } = .free,
            generation: u32 = 0,
            source: u32 = 0,
            destination: []align(16) u8 = &.{},
            completed: usize = 0,
            priority: Priority = .background,
            failure: ?anyerror = null,
        };
        jobs: [capacity]Job = @splat(.{}),
        transfer: Dma = .{},
        active: ?usize = null,
        chunk: usize = 0,
        cursor: usize = 0,
        options: Options,
        bytes_transferred: u64 = 0,
        transfers: u64 = 0,
        pi_busy: u64 = 0,

        pub fn init(options: Options) !Self {
            if (options.chunk_bytes == 0 or options.chunk_bytes % 16 != 0 or options.chunk_bytes > 64 * 1024) return error.InvalidChunkSize;
            return .{ .options = options };
        }
        pub fn enqueue(self: *Self, source: u32, destination: []align(16) u8, priority: Priority) !Ticket {
            if (source % 16 != 0 or destination.len % 16 != 0) return error.UnalignedTransfer;
            if (@as(u64, source) + destination.len > 64 * 1024 * 1024) return error.InvalidRomRange;
            for (&self.jobs, 0..) |*job, index| {
                if (job.state != .free) continue;
                var generation = job.generation +% 1;
                if (generation == 0) generation = 1;
                job.* = .{ .state = if (destination.len == 0) .complete else .queued, .generation = generation, .source = source, .destination = destination, .priority = priority };
                return .{ .owner = self, .index = index, .generation = generation };
            }
            return error.LoadQueueFull;
        }

        /// Retire at most one DMA without starting another. Active DMA cannot
        /// be cancelled; even a caller's timeout retains its destination.
        pub fn poll(self: *Self) !void {
            const index = self.active orelse return;
            const completed = self.transfer.poll() catch |err| {
                self.jobs[index].failure = err;
                self.jobs[index].state = .failed;
                self.active = null;
                return err;
            };
            if (!completed) return;
            const job = &self.jobs[index];
            job.completed += self.chunk;
            self.bytes_transferred += self.chunk;
            job.state = if (job.completed == job.destination.len) .complete else .queued;
            self.active = null;
        }

        /// Start at most one bounded chunk. Equal priorities rotate fairly.
        /// Raw PI owners are respected; a busy PI leaves the request queued.
        pub fn dispatch(self: *Self) !void {
            if (self.active != null) return;
            const index = self.next() orelse return;
            const job = &self.jobs[index];
            const length = @min(self.options.chunk_bytes, job.destination.len - job.completed);
            const destination: []align(16) u8 = @alignCast(job.destination[job.completed..][0..length]);
            self.transfer.begin(job.source + @as(u32, @intCast(job.completed)), destination) catch |err| {
                if (err == error.PiBusy) {
                    self.pi_busy += 1;
                    return;
                }
                job.state = .failed;
                job.failure = err;
                return err;
            };
            self.active = index;
            self.chunk = length;
            job.state = .active;
            self.cursor = (index + 1) % capacity;
            self.transfers += 1;
        }
        fn next(self: *Self) ?usize {
            var best: ?usize = null;
            for (0..capacity) |offset| {
                const index = (self.cursor + offset) % capacity;
                const job = &self.jobs[index];
                if (job.state != .queued) continue;
                if (best == null or @intFromEnum(job.priority) > @intFromEnum(self.jobs[best.?].priority)) best = index;
            }
            return best;
        }
        pub fn service(self: *Self) !void {
            try self.poll();
            try self.dispatch();
        }
        /// Service AI even during background DMA. Once that DMA retires, fill
        /// audio first, then admit one background chunk. Call every game frame
        /// (or more often); this does not preempt an already active PI transfer.
        pub fn serviceAudio(self: *Self, player: anytype, options: @import("../audio/player.zig").UpdateOptions) !void {
            try self.poll();
            player.output.service();
            if (self.active != null) return;
            _ = try player.update(options);
            try self.dispatch();
        }
        pub fn isComplete(self: *Self, ticket: Ticket) !bool {
            const job = try self.get(ticket);
            if (job.failure) |failure| return failure;
            return job.state == .complete;
        }
        pub fn progress(self: *Self, ticket: Ticket) !usize {
            return (try self.get(ticket)).completed;
        }
        /// Release a completed/failed job or cancel queued work. No running
        /// DMA is abandoned. The owner must keep storage alive until success.
        pub fn release(self: *Self, ticket: Ticket) !void {
            const job = try self.get(ticket);
            if (job.state == .active) return error.TransferBusy;
            job.state = .free;
        }
        fn get(self: *Self, ticket: Ticket) !*Job {
            if (ticket.owner != self or ticket.index >= capacity) return error.InvalidTicket;
            const job = &self.jobs[ticket.index];
            if (job.state == .free or job.generation != ticket.generation) return error.InvalidTicket;
            return job;
        }
        pub fn isIdle(self: *const Self) bool {
            for (self.jobs) |job| if (job.state != .free) return false;
            return true;
        }
    };
}

/// Typed assets use direct DMA by default. beginScheduled opts an owner into
/// the scheduler; its queue and ticket stay borrowed until poll completes.
pub const Transfer = struct {
    direct: pi.Transfer = .{},
    scheduler: ?*Scheduler = null,
    priority: Priority = .background,
    ticket: ?Scheduler.Ticket = null,
    pub fn begin(self: *Transfer, source: u32, destination: []align(16) u8) !void {
        if (self.ticket != null) return error.TransferBusy;
        if (self.scheduler) |queue| {
            self.ticket = try queue.enqueue(source, destination, self.priority);
        } else try self.direct.begin(source, destination);
    }
    pub fn poll(self: *Transfer) !bool {
        if (self.ticket) |ticket| {
            const queue = self.scheduler.?;
            const complete = queue.isComplete(ticket) catch |err| {
                try queue.release(ticket);
                self.ticket = null;
                self.scheduler = null;
                return err;
            };
            if (!complete) return false;
            try queue.release(ticket);
            self.ticket = null;
            self.scheduler = null;
            return true;
        }
        return self.direct.poll();
    }
    pub fn isScheduled(self: *const Transfer) bool {
        return self.ticket != null;
    }
};

const FakeDma = struct {
    ready: bool = false,
    busy: bool = false,
    fail: bool = false,
    destination: []u8 = &.{},
    pub fn begin(self: *@This(), _: u32, destination: []align(16) u8) !void {
        if (self.busy) return error.PiBusy;
        self.destination = destination;
    }
    pub fn poll(self: *@This()) !bool {
        if (self.fail) return error.PiError;
        if (!self.ready) return false;
        @memset(self.destination, 42);
        return true;
    }
};

test "priority and bounded chunks permit audio between background transfers" {
    var queue = try Queue(2, FakeDma).init(.{ .chunk_bytes = 16 });
    var a: [32]u8 align(16) = @splat(0);
    var b: [16]u8 align(16) = @splat(0);
    const background = try queue.enqueue(0, &a, .background);
    const urgent = try queue.enqueue(32, &b, .urgent);
    try std.testing.expectError(error.LoadQueueFull, queue.enqueue(64, &b, .normal));
    try queue.dispatch();
    try std.testing.expectError(error.TransferBusy, queue.release(urgent));
    try queue.poll();
    try std.testing.expect(!try queue.isComplete(urgent));
    queue.transfer.ready = true;
    try queue.poll();
    try std.testing.expect(queue.active == null);
    try std.testing.expect(try queue.isComplete(urgent));
    try std.testing.expectEqual(@as(u8, 0), a[0]);
    try queue.release(urgent);
    try queue.dispatch();
    try queue.poll();
    try std.testing.expectEqual(@as(usize, 16), try queue.progress(background));
    try std.testing.expectEqual(@as(u8, 0), a[16]);
    try queue.dispatch();
    try queue.poll();
    try std.testing.expect(try queue.isComplete(background));
    try queue.release(background);
    try std.testing.expect(queue.isIdle());
    try std.testing.expectError(error.InvalidTicket, queue.isComplete(background));
}

test "PI busy retries and failures retain a releasable ticket" {
    var queue = try Queue(1, FakeDma).init(.{});
    var data: [16]u8 align(16) = undefined;
    const ticket = try queue.enqueue(0, &data, .normal);
    queue.transfer.busy = true;
    try queue.dispatch();
    try std.testing.expect(queue.active == null);
    queue.transfer.busy = false;
    try queue.dispatch();
    queue.transfer.fail = true;
    try std.testing.expectError(error.PiError, queue.poll());
    try std.testing.expectError(error.PiError, queue.isComplete(ticket));
    try queue.release(ticket);
    _ = try queue.enqueue(0, &data, .normal);
    try std.testing.expectError(error.InvalidTicket, queue.release(ticket));
    try std.testing.expectError(error.InvalidChunkSize, Queue(1, FakeDma).init(.{ .chunk_bytes = 1 }));
}
