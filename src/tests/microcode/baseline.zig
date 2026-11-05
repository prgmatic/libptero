//! The checked-in RSP performance and behavior baseline.
//!
//! `baseline.zon` records, per workload, the estimated cycles, retired
//! instructions, and output digest of the current microcode. The test below
//! fails when a workload's outputs change or its cycles regress by more than
//! `tolerance_percent`. Improvements pass; record them with
//! `zig build rsp-baseline -- --update` so the gate tightens.
const std = @import("std");
const workloads = @import("workloads.zig");

pub const Entry = struct {
    name: []const u8,
    instructions: u64,
    cycles: u64,
    digest: []const u8,
};

pub const Baseline = struct {
    tolerance_percent: u64,
    workloads: []const Entry,
};

pub const recorded: Baseline = @import("baseline.zon");

pub const Verdict = enum {
    unchanged,
    faster,
    slower_within_tolerance,
    regression,
    output_changed,
    missing,

    pub fn fails(self: Verdict) bool {
        return switch (self) {
            .regression, .output_changed, .missing => true,
            else => false,
        };
    }
};

pub fn find(baseline: Baseline, name: []const u8) ?Entry {
    for (baseline.workloads) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry;
    }
    return null;
}

pub fn hex(digest: [16]u8) [32]u8 {
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn judge(entry: ?Entry, outcome: workloads.Outcome, tolerance_percent: u64) Verdict {
    const recorded_entry = entry orelse return .missing;
    if (!std.mem.eql(u8, recorded_entry.digest, &hex(outcome.digest))) return .output_changed;
    if (outcome.cycles < recorded_entry.cycles) return .faster;
    if (outcome.cycles == recorded_entry.cycles) return .unchanged;
    if (outcome.cycles * 100 <= recorded_entry.cycles * (100 + tolerance_percent)) return .slower_within_tolerance;
    return .regression;
}

pub const Named = struct { name: []const u8, outcome: workloads.Outcome };

/// Serializes a baseline in the format read by `@import("baseline.zon")`.
pub fn write(writer: *std.Io.Writer, tolerance_percent: u64, results: []const Named) !void {
    try writer.print(".{{\n    .tolerance_percent = {d},\n    .workloads = .{{\n", .{tolerance_percent});
    for (results) |result| {
        try writer.print("        .{{ .name = \"{s}\", .instructions = {d}, .cycles = {d}, .digest = \"{s}\" }},\n", .{
            result.name, result.outcome.instructions, result.outcome.cycles, hex(result.outcome.digest),
        });
    }
    try writer.writeAll("    },\n}\n");
}

const testing = std.testing;

test "judging compares digests first, then cycles against the tolerance" {
    const digest: [16]u8 = @splat(0xab);
    const entry: Entry = .{ .name = "w", .instructions = 10, .cycles = 100, .digest = &hex(digest) };
    const at = struct {
        fn cycles(value: u64, d: [16]u8) workloads.Outcome {
            return .{ .instructions = 10, .cycles = value, .digest = d };
        }
    }.cycles;
    try testing.expectEqual(Verdict.missing, judge(null, at(1, digest), 2));
    try testing.expectEqual(Verdict.output_changed, judge(entry, at(100, @splat(0)), 2));
    try testing.expectEqual(Verdict.faster, judge(entry, at(99, digest), 2));
    try testing.expectEqual(Verdict.unchanged, judge(entry, at(100, digest), 2));
    try testing.expectEqual(Verdict.slower_within_tolerance, judge(entry, at(102, digest), 2));
    try testing.expectEqual(Verdict.regression, judge(entry, at(103, digest), 2));
    try testing.expect(Verdict.regression.fails() and !Verdict.faster.fails());
    try testing.expectEqual(@as(?Entry, null), find(.{ .tolerance_percent = 0, .workloads = &.{entry} }, "other"));
}

test "baselines serialize to their ZON form" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try write(&writer, 2, &.{.{ .name = "w", .outcome = .{ .instructions = 1, .cycles = 2, .digest = @splat(0x0f) } }});
    try testing.expectEqualStrings(
        \\.{
        \\    .tolerance_percent = 2,
        \\    .workloads = .{
        \\        .{ .name = "w", .instructions = 1, .cycles = 2, .digest = "0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f0f" },
        \\    },
        \\}
        \\
    , writer.buffered());
}

test "every workload reproduces its recorded outputs within the cycle tolerance" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const failed = try runCommand(testing.io, testing.allocator, tmp.dir, &.{ "rsp-baseline", "baseline.zon" }, &output.writer);
    if (failed) {
        std.log.err("RSP baseline mismatch; run `zig build rsp-baseline` for details:\n{s}", .{output.written()});
        return error.RspBaselineMismatch;
    }
    for (workloads.all) |workload| try testing.expect(std.mem.indexOf(u8, output.written(), workload.name) != null);
    try testing.expect(std.mem.indexOf(u8, output.written(), "geometry_clipping") != null);
    try testing.expectError(error.FileNotFound, tmp.dir.access(testing.io, "baseline.zon", .{}));
}

test "update mode rewrites the baseline file" {
    var output: std.Io.Writer.Allocating = .init(testing.allocator);
    defer output.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try testing.expect(!try runCommand(testing.io, testing.allocator, tmp.dir, &.{ "rsp-baseline", "baseline.zon", "--update" }, &output.writer));
    const written = try tmp.dir.readFileAlloc(testing.io, "baseline.zon", testing.allocator, .limited(1 << 16));
    defer testing.allocator.free(written);
    try testing.expect(std.mem.indexOf(u8, written, ".tolerance_percent = ") != null);
    try testing.expectError(error.MissingBaselinePath, runCommand(testing.io, testing.allocator, tmp.dir, &.{"rsp-baseline"}, &output.writer));
}

const interp = @import("rsp_interp");
const hottest_functions = 6;

pub const Options = struct { path: []const u8, update: bool };

pub fn parseOptions(args: []const []const u8) !Options {
    if (args.len < 2) return error.MissingBaselinePath;
    return .{ .path = args[1], .update = args.len > 2 and std.mem.eql(u8, args[2], "--update") };
}

/// `rsp-baseline <baseline.zon> [--update]`: prints every workload against
/// the recorded baseline with its hottest functions. Returns true when the
/// gate fails; with `--update`, rewrites the baseline instead.
pub fn runCommand(io: std.Io, allocator: std.mem.Allocator, dir: std.Io.Dir, args: []const []const u8, out: *std.Io.Writer) !bool {
    const options = try parseOptions(args);
    var results: [workloads.all.len]Named = undefined;
    const failed = try report(allocator, out, &results);
    if (!options.update) return failed;
    var text: std.Io.Writer.Allocating = .init(allocator);
    defer text.deinit();
    try write(&text.writer, recorded.tolerance_percent, &results);
    try dir.writeFile(io, .{ .sub_path = options.path, .data = text.written() });
    return false;
}

const n64 = @import("n64");

/// Shipped programs whose sizes the report tracks.
const sized_programs = .{
    .{ "command_dispatcher", n64.rsp.programs.command_dispatcher },
    .{ "rdp_overlay", n64.rsp.programs.rdp_overlay },
    .{ "audio_mixer", n64.rsp.programs.audio_mixer },
    .{ "audio_vadpcm", n64.rsp.programs.audio_vadpcm },
    .{ "geometry_overlay", n64.rsp.programs.geometry_overlay },
    .{ "geometry_clipping", n64.rsp.programs.geometry_clipping },
};

fn printSizes(out: *std.Io.Writer) !void {
    try out.print("{s:<22} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{ "program", "imem_at", "text", "data", "state" });
    inline for (sized_programs) |entry| {
        const program = entry[1];
        try out.print("{s:<22} {d:>10} {d:>10} {d:>10} {d:>10}\n", .{ entry[0], program.text_offset, program.text.len, program.data.len, program.state_len });
    }
    try out.writeAll("\n");
}

fn report(allocator: std.mem.Allocator, out: *std.Io.Writer, results: []Named) !bool {
    var failed = false;
    try printSizes(out);
    try out.print("{s:<22} {s:>12} {s:>12} {s:>12} {s:>8}  verdict\n", .{ "workload", "instructions", "cycles", "recorded", "delta" });
    for (workloads.all, results) |workload, *result| {
        var profile: interp.Profile = .{};
        var harness: workloads.Harness = undefined;
        try harness.init(allocator);
        defer harness.deinit();
        harness.profile = &profile;
        result.* = .{ .name = workload.name, .outcome = try workload.run(&harness) };
        const entry = find(recorded, workload.name);
        const verdict = judge(entry, result.outcome, recorded.tolerance_percent);
        failed = failed or verdict.fails();
        try printRow(out, result.*, entry, verdict);
        try printHottest(allocator, out, &profile, workload.symbols);
    }
    return failed;
}

fn printRow(out: *std.Io.Writer, result: Named, entry: ?Entry, verdict: Verdict) !void {
    const recorded_cycles: u64 = if (entry) |e| e.cycles else 0;
    try out.print("{s:<22} {d:>12} {d:>12} {d:>12} {d:>7.2}%  {s}\n", .{
        result.name, result.outcome.instructions, result.outcome.cycles, recorded_cycles, percentChange(result.outcome.cycles, recorded_cycles), @tagName(verdict),
    });
}

fn percentChange(current: u64, previous: u64) f64 {
    if (previous == 0) return 0;
    return (@as(f64, @floatFromInt(current)) / @as(f64, @floatFromInt(previous)) - 1) * 100;
}

fn printHottest(allocator: std.mem.Allocator, out: *std.Io.Writer, profile: *const interp.Profile, source: workloads.SymbolSource) !void {
    const symbols = try source(allocator);
    defer allocator.free(symbols);
    const sorted = try interp.Profile.sortedSymbols(allocator, symbols);
    defer allocator.free(sorted);
    const costs = try profile.attribute(allocator, sorted, 0, 0x1000, "(unnamed)");
    defer allocator.free(costs);
    std.mem.sort(interp.Profile.Cost, costs, {}, moreCycles);
    for (costs[0..@min(costs.len, hottest_functions)]) |cost| {
        try out.print("    {s:<44} {d:>10} cycles {d:>10} instructions\n", .{ cost.name, cost.cycles, cost.instructions });
    }
}

fn moreCycles(_: void, a: interp.Profile.Cost, b: interp.Profile.Cost) bool {
    return a.cycles > b.cycles;
}

test "percent change handles a missing baseline" {
    try testing.expectEqual(@as(f64, 0), percentChange(10, 0));
    try testing.expectApproxEqAbs(@as(f64, 10), percentChange(110, 100), 0.0001);
    try testing.expectEqual(Options{ .path = "b", .update = false }, try parseOptions(&.{ "x", "b", "--other" }));
}
