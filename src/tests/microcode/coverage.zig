//! Every command handler of every shipped RSP program must execute in at
//! least one host workload, so a rewrite cannot silently change an untested
//! handler. Overlays share IMEM, so a handler counts only when it runs in a
//! workload that drives its overlay; resident handlers count everywhere.
const std = @import("std");
const n64 = @import("n64");
const interp = @import("rsp_interp");
const workloads = @import("workloads.zig");

const programs = n64.rsp.programs;
const Program = n64.rsp.Program;

pub const Exemption = struct { kind: ?workloads.OverlayKind, index: u8, reason: []const u8 };

/// Handlers deliberately left to hardware tests or without runtime callers.
pub const exemptions = [_]Exemption{
    .{ .kind = .geometry, .index = 12, .reason = "drawTriangleSequence has no runtime encoder; a geometry_workloads test compares it with single triangles" },
    .{ .kind = .geometry, .index = 13, .reason = "patchCode rewrites IMEM; covered by the hardware geometry tests" },
};

fn programFor(kind: ?workloads.OverlayKind) Program {
    const selected = kind orelse return programs.command_dispatcher;
    return switch (selected) {
        .rdp => programs.rdp_overlay,
        .audio_mixer => programs.audio_mixer,
        .audio_vadpcm => programs.audio_vadpcm,
        .geometry => programs.geometry_overlay,
    };
}

pub fn exempt(kind: ?workloads.OverlayKind, index: u8) bool {
    for (exemptions) |exemption| {
        if (exemption.kind == kind and exemption.index == index) return true;
    }
    return false;
}

const kinds = [_]?workloads.OverlayKind{ null, .rdp, .audio_mixer, .audio_vadpcm, .geometry };

/// Marks handlers of `kind`'s program that executed in `profile`.
fn markExecuted(covered: *[256]bool, kind: ?workloads.OverlayKind, profile: *const interp.Profile) void {
    const program = programFor(kind);
    for (0..program.commandCount()) |metadata| {
        const command = program.commandAt(metadata);
        if (profile.instructions[command.handler_offset / 4] != 0) covered[command.index] = true;
    }
}

test "every shipped command handler executes in a host workload" {
    var covered: [kinds.len][256]bool = @splat(@splat(false));
    for (workloads.all) |workload| {
        var profile: interp.Profile = .{};
        var harness: workloads.Harness = undefined;
        try harness.init(std.testing.allocator);
        defer harness.deinit();
        harness.profile = &profile;
        _ = try workload.run(&harness);
        markExecuted(&covered[0], null, &profile);
        if (workload.overlay) |kind| markExecuted(&covered[@as(usize, @intFromEnum(kind)) + 1], kind, &profile);
    }
    for (kinds, covered) |kind, executed| {
        const program = programFor(kind);
        for (0..program.commandCount()) |metadata| {
            const index = program.commandAt(metadata).index;
            if (executed[index] or exempt(kind, index)) continue;
            std.log.err("RSP command {d} of {s} is not exercised by any host workload", .{ index, if (kind) |k| @tagName(k) else "dispatcher" });
            return error.UncoveredCommandHandler;
        }
    }
}

test "exemptions name real commands" {
    for (exemptions) |exemption| try std.testing.expect(exempt(exemption.kind, exemption.index));
    try std.testing.expect(!exempt(.rdp, 0));
}
