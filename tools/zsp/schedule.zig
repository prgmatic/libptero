//! Scheduling of straight-line instruction runs.
//!
//! Each run between labels and barriers is reordered within its dependence
//! graph (`ir_deps.zig`), together with the control transfer that ends it.
//! A beam search keeps the most promising partial orders, scored by the RSP
//! timing model (`tools/rsp_interp/timing.zig`, calibrated on hardware), and
//! may move one instruction into a transfer's empty delay slot. Instructions
//! in `exact` blocks, raw assembly, and filled delay slots stay in place.
const std = @import("std");
const timing = @import("rsp_timing");
const ir = @import("ir.zig");
const ir_deps = @import("ir_deps.zig");
const effects = @import("ir_effects.zig");

const Item = ir.Item;
const Items = std.ArrayList(Item);

/// Runs are scheduled in windows of at most this many instructions.
const max_window = 96;

/// Partial schedules kept at each step of the search.
const beam_width = 64;

pub fn scheduleItems(allocator: std.mem.Allocator, items: *Items) !void {
    var start: usize = 0;
    while (start < items.items.len) {
        var end = runEnd(items.items, start);
        end -= try scheduleRun(allocator, items, start, end);
        start = nextRunStart(items.items, end);
    }
}

/// An instruction the scheduler may move.
pub fn isMovable(item: Item) bool {
    if (item != .instruction) return false;
    const inst = item.instruction;
    return !inst.frozen and !effects.of(inst).isTransfer();
}

fn runEnd(items: []const Item, start: usize) usize {
    var end = start;
    while (end < items.len and isMovable(items[end])) end += 1;
    return end;
}

/// Skips the barrier at `end`, including a transfer's delay slot.
fn nextRunStart(items: []const Item, end: usize) usize {
    if (end >= items.len) return end;
    return end + 1 + @intFromBool(hasDelaySlot(items[end]));
}

pub fn hasDelaySlot(item: Item) bool {
    if (item != .instruction) return false;
    const control = effects.of(item.instruction).control;
    return control != .none and control != .halt;
}

/// The transfer ending a run and its delay slot.
const Tail = struct {
    transfer: ?ir.Inst = null,
    /// The fixed slot instruction issued after the transfer.
    slot: ?u32 = null,
    /// The slot holds a `nop` that a moved instruction may replace.
    slot_free: bool = false,
};

fn tailAt(items: []const Item, end: usize) Tail {
    const transfer = transferAt(items, end) orelse return .{};
    const slot = slotAfter(items, end) orelse return .{ .transfer = transfer };
    return .{ .transfer = transfer, .slot = slot.encode(), .slot_free = slot.isNop() and !slot.frozen };
}

/// A transfer the scheduler may order with its run.
fn transferAt(items: []const Item, index: usize) ?ir.Inst {
    if (index >= items.len or items[index] != .instruction) return null;
    const transfer = items[index].instruction;
    if (transfer.frozen or !effects.of(transfer).isTransfer()) return null;
    return transfer;
}

fn slotAfter(items: []const Item, transfer: usize) ?ir.Inst {
    if (!hasDelaySlot(items[transfer]) or transfer + 1 >= items.len) return null;
    return if (items[transfer + 1] == .instruction) items[transfer + 1].instruction else null;
}

/// Schedules `[start, end)` in windows; the last also orders the tail.
/// Returns 1 when an instruction moved into the delay slot.
fn scheduleRun(allocator: std.mem.Allocator, items: *Items, start: usize, end: usize) !usize {
    var window_start = start;
    while (end - window_start > max_window) : (window_start += max_window) {
        _ = try scheduleWindow(allocator, items, window_start, window_start + max_window, .{});
    }
    return scheduleWindow(allocator, items, window_start, end, tailAt(items.items, end));
}

fn scheduleWindow(allocator: std.mem.Allocator, items: *Items, start: usize, end: usize, tail: Tail) !usize {
    if (end == start or (end - start < 2 and !tail.slot_free)) return 0;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const body = try arena.allocator().dupe(Item, items.items[start..end]);
    const order = try listSchedule(arena.allocator(), body, tail, entryPipeline(items.items, start));
    return applyOrder(items, start, body, order, tail);
}

/// Writes `order` back. The transfer keeps its position unless an
/// instruction follows it into the slot, which replaces the `nop`.
fn applyOrder(items: *Items, start: usize, body: []const Item, order: []const usize, tail: Tail) usize {
    var position = start;
    for (order) |index| {
        items.items[position] = if (index == body.len) .{ .instruction = tail.transfer.? } else body[index];
        position += 1;
    }
    const filled_slot = tail.transfer != null and order[order.len - 1] != body.len;
    if (filled_slot) _ = items.orderedRemove(position);
    return @intFromBool(filled_slot);
}

const Node = struct {
    word: u32,
    height: u32 = 0,
    preds: usize = 0,
};

/// Instructions before a window whose results it may still wait on.
const entry_history = 6;

/// The pipeline as the window is entered by falling through: the latest
/// instructions before it, so results still in flight delay their readers.
fn entryPipeline(items: []const Item, start: usize) timing.Pipeline {
    const first = historyStart(items, start);
    var pipeline: timing.Pipeline = .{};
    for (items[first..start]) |item| {
        if (item == .instruction) pipeline.issue(item.instruction.encode(), false);
    }
    return pipeline;
}

/// The earliest of the last `entry_history` instructions before `start`,
/// looking back across labels but not other items.
fn historyStart(items: []const Item, start: usize) usize {
    var first = start;
    var count: usize = 0;
    while (first > 0 and count < entry_history) : (first -= 1) {
        const item = items[first - 1];
        if (item != .instruction and item != .label) break;
        count += @intFromBool(item == .instruction);
    }
    return first;
}

/// Returns body indices in issue order; index `body.len` is the tail's
/// transfer, followed by at most one instruction that fills its slot.
/// `entry` is the pipeline state the window starts from.
pub fn listSchedule(arena: std.mem.Allocator, body: []const Item, tail: Tail, entry: timing.Pipeline) ![]usize {
    const count = body.len + @intFromBool(tail.transfer != null);
    const all = try arena.alloc(effects.Effects, count);
    const nodes = try arena.alloc(Node, count);
    for (all, nodes, 0..) |*item_effects, *node, index| {
        const inst = if (index == body.len) tail.transfer.? else body[index].instruction;
        item_effects.* = effects.of(inst);
        node.* = .{ .word = inst.encode() };
    }
    const graph = try ir_deps.Graph.init(arena, all);
    computeHeights(graph, nodes);
    for (nodes, 0..) |*node, index| node.preds = graph.preds[index].count();
    var search: Search = .{ .arena = arena, .graph = graph, .nodes = nodes, .body_len = body.len, .tail = tail, .entry = entry };
    return search.run();
}

/// Longest path from each node to the end of the window, where an edge
/// costs the producer's result latency when the consumer reads the result
/// and one issue cycle otherwise.
fn computeHeights(graph: ir_deps.Graph, nodes: []Node) void {
    var index = nodes.len;
    while (index > 0) {
        index -= 1;
        var longest: u32 = 1;
        for (nodes[index + 1 ..], index + 1..) |successor, later| {
            if (!graph.depends(later, index)) continue;
            const delay: u32 = @max(1, timing.resultLatency(nodes[index].word, successor.word));
            longest = @max(longest, delay + successor.height);
        }
        nodes[index].height = longest;
    }
}

/// A partial schedule: the pipeline after issuing `order[0..step]`.
const State = struct {
    pipeline: timing.Pipeline = .{},
    order: []usize,
    issued: []bool,
    /// Unissued predecessors of each node.
    waiting: []usize,
    /// Lower bound on completion: the clock plus the longest chain left.
    estimate: u64 = 0,
    /// Cycles after the slot issues, for complete schedules.
    total: u64 = 0,
};

/// Beam search over topological orders, scored by the timing model.
const Search = struct {
    arena: std.mem.Allocator,
    graph: ir_deps.Graph,
    nodes: []const Node,
    body_len: usize,
    tail: Tail,
    entry: timing.Pipeline = .{},

    /// The best order the beam finds, unless the source order is as good:
    /// the beam can drop a hand-arranged order on the way, and only a
    /// better estimate is worth the change.
    fn run(self: *Search) ![]usize {
        var beam: std.ArrayList(State) = .empty;
        try beam.append(self.arena, try self.initialState());
        for (0..self.nodes.len) |step| beam = try self.advance(beam, step);
        for (beam.items) |*state| state.total = self.finish(state.*);
        const best = bestFinal(beam.items);
        const source = try self.sourceOrder();
        return if (finalBefore(best, source) and best.total < source.total) best.order else source.order;
    }

    /// Every node in index order: the body as written, then the transfer.
    fn sourceOrder(self: *Search) !State {
        var state = try self.initialState();
        for (0..self.nodes.len) |index| state = try self.extend(state, index, index);
        state.total = self.finish(state);
        return state;
    }

    fn initialState(self: *Search) !State {
        const waiting = try self.arena.alloc(usize, self.nodes.len);
        for (self.nodes, waiting) |node, *count| count.* = node.preds;
        const issued = try self.arena.alloc(bool, self.nodes.len);
        @memset(issued, false);
        return .{ .pipeline = self.entry, .order = try self.arena.alloc(usize, self.nodes.len), .issued = issued, .waiting = waiting };
    }

    /// Extends every state by each ready node and keeps the best few.
    fn advance(self: *Search, beam: std.ArrayList(State), step: usize) !std.ArrayList(State) {
        var next: std.ArrayList(State) = .empty;
        for (beam.items) |state| {
            for (0..self.nodes.len) |index| {
                if (!self.isReady(state, index, step)) continue;
                try next.append(self.arena, try self.extend(state, index, step));
            }
        }
        std.mem.sort(State, next.items, {}, rankBefore);
        next.shrinkRetainingCapacity(@min(next.items.len, beam_width));
        return next;
    }

    /// The transfer waits until only its slot candidate, if any, remains.
    fn isReady(self: *const Search, state: State, index: usize, step: usize) bool {
        if (state.issued[index] or state.waiting[index] != 0) return false;
        return index != self.body_len or self.transferMayIssue(state, step);
    }

    fn transferMayIssue(self: *const Search, state: State, step: usize) bool {
        const remaining = self.nodes.len - 1 - step;
        if (remaining == 0) return true;
        return remaining == 1 and self.tail.slot_free and self.lastBodyReady(state);
    }

    fn lastBodyReady(self: *const Search, state: State) bool {
        for (state.issued[0..self.body_len], state.waiting[0..self.body_len]) |done, waiting| {
            if (!done) return waiting == 0;
        }
        return false;
    }

    fn extend(self: *Search, state: State, index: usize, step: usize) !State {
        var result: State = .{
            .pipeline = state.pipeline,
            .order = try self.arena.dupe(usize, state.order),
            .issued = try self.arena.dupe(bool, state.issued),
            .waiting = try self.arena.dupe(usize, state.waiting),
        };
        result.pipeline.issue(self.nodes[index].word, false);
        result.order[step] = index;
        result.issued[index] = true;
        for (result.waiting[index + 1 ..], index + 1..) |*count, later| {
            if (self.graph.depends(later, index)) count.* -= 1;
        }
        result.estimate = result.pipeline.cycles + self.longestRemaining(result.issued);
        return result;
    }

    fn longestRemaining(self: *const Search, issued: []const bool) u64 {
        var longest: u64 = 0;
        for (self.nodes, issued) |node, done| {
            if (!done) longest = @max(longest, node.height);
        }
        return longest;
    }

    /// Issues the fixed slot when the transfer ended the schedule.
    fn finish(self: *const Search, state: State) u64 {
        var pipeline = state.pipeline;
        const transfer_last = self.tail.transfer != null and state.order[state.order.len - 1] == self.body_len;
        if (transfer_last) {
            if (self.tail.slot) |slot| pipeline.issue(slot, false);
        }
        return pipeline.cycles;
    }
};

fn rankBefore(_: void, a: State, b: State) bool {
    if (a.estimate != b.estimate) return a.estimate < b.estimate;
    if (a.pipeline.cycles != b.pipeline.cycles) return a.pipeline.cycles < b.pipeline.cycles;
    return std.mem.order(usize, a.order, b.order) == .lt;
}

/// Results still in flight when the window ends delay the next block.
fn drain(pipeline: timing.Pipeline) u64 {
    return std.mem.max(u64, &pipeline.ready) -| pipeline.cycles;
}

fn finalBefore(a: State, b: State) bool {
    if (a.total != b.total) return a.total < b.total;
    if (drain(a.pipeline) != drain(b.pipeline)) return drain(a.pipeline) < drain(b.pipeline);
    return std.mem.order(usize, a.order, b.order) == .lt;
}

fn bestFinal(states: []const State) State {
    var best = states[0];
    for (states[1..]) |state| {
        if (finalBefore(state, best)) best = state;
    }
    return best;
}

/// Estimated cycles of a straight-line instruction sequence.
pub fn estimateCycles(items: []const Item) u64 {
    var pipeline: timing.Pipeline = .{};
    for (items) |item| {
        if (item == .instruction) pipeline.issue(item.instruction.encode(), false);
    }
    return pipeline.cycles;
}

const testing = std.testing;

fn listOf(comptime list: []const ir.Inst) !Items {
    var items: Items = .empty;
    for (list) |inst| try items.append(testing.allocator, .{ .instruction = inst });
    return items;
}

test "independent work fills load latency" {
    var items = try listOf(&.{
        .{ .op = .lw, .rt = .t0, .rs = .a0 },
        .{ .op = .addu, .rd = .t1, .rs = .t0, .rt = .a1 },
        .{ .op = .addiu, .rt = .t2, .imm = 1 },
        .{ .op = .addiu, .rt = .t3, .imm = 2 },
    });
    defer items.deinit(testing.allocator);
    const before = estimateCycles(items.items);
    try scheduleItems(testing.allocator, &items);
    try testing.expectEqual(ir.Op.addu, items.items[3].instruction.op);
    try testing.expect(estimateCycles(items.items) < before);
}

test "scalar and vector work interleave to dual-issue" {
    var items = try listOf(&.{
        .{ .op = .addiu, .rt = .t0, .imm = 1 },
        .{ .op = .addiu, .rt = .t1, .imm = 2 },
        .{ .op = .vadd, .vd = .v03, .vs = .v01, .vt = .v02 },
        .{ .op = .vadd, .vd = .v04, .vs = .v01, .vt = .v02 },
    });
    defer items.deinit(testing.allocator);
    try scheduleItems(testing.allocator, &items);
    try testing.expectEqual(@as(u64, 2), estimateCycles(items.items));
}

test "the search looks past a greedy choice to avoid a store stall" {
    var items = try listOf(&.{
        .{ .op = .addiu, .rt = .s4, .symbol = "staging" },
        .{ .op = .lw, .rt = .s3, .symbol = "pointer" },
        .{ .op = .sw, .rt = .s4, .symbol = "pointer" },
    });
    defer items.deinit(testing.allocator);
    try scheduleItems(testing.allocator, &items);
    try testing.expectEqual(@as(u64, 3), estimateCycles(items.items));
}

test "an independent instruction moves into an empty delay slot" {
    var items = try listOf(&.{
        .{ .op = .addiu, .rt = .t1, .imm = 2 },
        .{ .op = .addiu, .rt = .t0, .imm = 1 },
        .{ .op = .bne, .rs = .t0, .symbol = "x" },
        .{ .op = .nop },
    });
    defer items.deinit(testing.allocator);
    try scheduleItems(testing.allocator, &items);
    try testing.expectEqual(@as(usize, 3), items.items.len);
    try testing.expectEqual(ir.Op.bne, items.items[1].instruction.op);
    try testing.expectEqual(ir.Reg.t1, items.items[2].instruction.rt);
}

test "transfers, filled delay slots, frozen code, and labels stay in place" {
    var items = try listOf(&.{
        .{ .op = .lw, .rt = .t0, .rs = .a0 },
        .{ .op = .bne, .rs = .t0, .symbol = "x" },
        .{ .op = .addiu, .rt = .t1, .imm = 1 },
        .{ .op = .lw, .rt = .t2, .rs = .a0, .frozen = true },
        .{ .op = .addu, .rd = .t3, .rs = .t2, .rt = .t2, .frozen = true },
        .{ .op = .addiu, .rt = .t4, .imm = 1, .frozen = true },
        .{ .op = .@"break" },
        .{ .op = .addiu, .rt = .t5, .imm = 1 },
    });
    defer items.deinit(testing.allocator);
    try items.insert(testing.allocator, 3, .{ .label = "x" });
    const copy = try testing.allocator.dupe(Item, items.items);
    defer testing.allocator.free(copy);
    try scheduleItems(testing.allocator, &items);
    for (copy, items.items) |expected, actual| try testing.expect(std.meta.eql(expected, actual));
    try testing.expect(!hasDelaySlot(.{ .instruction = .{ .op = .@"break" } }));
    try testing.expect(!hasDelaySlot(.{ .label = "x" }));
}
