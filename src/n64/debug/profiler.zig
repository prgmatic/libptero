//! Opt-in hardware tracing. Recording never allocates, transmits, or waits.
const std = @import("std");
const builtin = @import("builtin");
const cp0 = @import("../cpu/cp0.zig");
const time = @import("../time.zig");
const trace = @import("profiler/trace.zig");
pub const Recorder = trace.Recorder;
pub const Event = trace.Event;
pub const Lane = trace.Lane;
var active: ?*Recorder = null;
var generation: u32 = 0;

/// Tokens may cross capture boundaries; an old token never edits a new capture.
/// Each token must be ended at most once. Use defer for CPU scopes.
pub const Scope = struct {
    token: trace.Token = .{},
    generation: u32 = 0,
    pub fn end(self: Scope) void {
        self.endValue(0);
    }
    pub fn endValue(self: Scope, value: u32) void {
        if (self.token.span == 0) return;
        const status = lock();
        defer unlock(status);
        const recorder = active orelse return;
        if (self.generation != generation) return;
        recorder.endAt(now(), self.token, value);
    }
};

/// Recorder and storage remain at stable addresses until stop. One capture at
/// a time. Interrupt writers are serialized by a short CPU interrupt mask.
pub fn start(recorder: *Recorder) !void {
    const status = lock();
    defer unlock(status);
    if (active != null) return error.AlreadyCapturing;
    generation +%= 1;
    recorder.startAt(now());
    active = recorder;
}
pub fn stop(recorder: *Recorder) !void {
    const status = lock();
    defer unlock(status);
    if (active != recorder) return error.NotCapturing;
    recorder.stopAt(now());
    active = null;
}
pub fn scope(comptime name: []const u8) Scope {
    return begin(.cpu, name, 0);
}
pub fn begin(lane: Lane, comptime name: []const u8, value: u32) Scope {
    comptime validateName(name);
    // No Count read or interrupt masking while disabled.
    if (active == null) return .{};
    const status = lock();
    defer unlock(status);
    const recorder = active orelse return .{};
    return .{ .token = recorder.beginAt(now(), lane, name, value), .generation = generation };
}
pub fn instant(lane: Lane, comptime name: []const u8, value: u32) void {
    mark(lane, name, .instant, value);
}
pub fn counter(lane: Lane, comptime name: []const u8, value: u32) void {
    mark(lane, name, .counter, value);
}
fn mark(lane: Lane, comptime name: []const u8, kind: trace.Kind, value: u32) void {
    comptime validateName(name);
    if (active == null) return;
    const status = lock();
    defer unlock(status);
    const recorder = active orelse return;
    recorder.markAt(now(), lane, name, kind, value);
}
fn validateName(comptime name: []const u8) void {
    if (!trace.validName(name)) @compileError("trace names require 1..63 printable ASCII bytes");
}
fn lock() u32 {
    if (builtin.cpu.arch != .mips and builtin.cpu.arch != .mipsel) return 0;
    const status = cp0.regRead(.Status);
    cp0.regWrite(.Status, status & ~@as(u32, 1));
    return status;
}
fn unlock(status: u32) void {
    if (builtin.cpu.arch != .mips and builtin.cpu.arch != .mipsel) return;
    cp0.regWrite(.Status, status);
}
fn now() u32 {
    if (builtin.cpu.arch != .mips and builtin.cpu.arch != .mipsel) return 0;
    return time.Instant.now().ticks;
}
const DebugWriter = struct {
    pub fn print(_: DebugWriter, comptime fmt: []const u8, args: anytype) !void {
        @import("../debug.zig").print(fmt, args);
    }
};
/// Stop first and drain audio before exporting. Backend IO may block. Do not
/// call from interrupts or interleave other debug transmissions with export.
pub fn exportTrace(recorder: *const Recorder, id: u32) !void {
    if (recorder.running) return error.CaptureRunning;
    if (comptime builtin.cpu.arch != .mips and builtin.cpu.arch != .mipsel) return error.NoDebugBackend;
    if (@import("../debug.zig").current_backend == .none) return error.NoDebugBackend;
    try recorder.write(DebugWriter{}, id);
}

test "disabled calls, capture exclusivity, and old scope generations" {
    var events: [8]Event = undefined;
    var r = Recorder.init(&events);
    scope("disabled").end();
    try start(&r);
    try std.testing.expectError(error.AlreadyCapturing, start(&r));
    const old = scope("old");
    try stop(&r);
    try std.testing.expectError(error.NotCapturing, stop(&r));
    try start(&r);
    old.end();
    const current = scope("current");
    counter(.audio, "queued", 2);
    current.end();
    try stop(&r);
    try std.testing.expectEqual(@as(usize, 3), r.count);
    try std.testing.expectEqualStrings("current", r.labels[0]);
}

test "export refuses running captures and absent debug backends" {
    var events: [1]Event = undefined;
    var r = Recorder.init(&events);
    try start(&r);
    try std.testing.expectError(error.CaptureRunning, exportTrace(&r, 1));
    try stop(&r);
    try std.testing.expectError(error.NoDebugBackend, exportTrace(&r, 1));
}
