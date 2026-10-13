//! Compile-time source-name identifiers. Numeric indices remain the draw ABI.
const std = @import("std");

pub fn index(comptime names: []const []const u8, comptime name: []const u8) u16 {
    @setEvalBranchQuota(10_000 + names.len * (name.len + 1) * 8);
    return comptime find(names, name) catch |err| @compileError(std.fmt.comptimePrint(
        "material '{s}': {s}; use a unique nonempty source name or a numeric index",
        .{ name, @errorName(err) },
    ));
}

fn find(names: []const []const u8, name: []const u8) error{ EmptyMaterialName, UnknownMaterialName, AmbiguousMaterialName }!u16 {
    if (name.len == 0) return error.EmptyMaterialName;
    var result: ?u16 = null;
    for (names, 0..) |candidate, i| {
        if (!std.mem.eql(u8, candidate, name)) continue;
        if (result != null) return error.AmbiguousMaterialName;
        result = @intCast(i);
    }
    return result orelse error.UnknownMaterialName;
}

test "identifiers follow source order and preserve punctuation and UTF-8" {
    const names = [_][]const u8{ "body", "visor \"blue\"", "café" };
    try std.testing.expectEqual(@as(u16, 0), index(&names, "body"));
    try std.testing.expectEqual(@as(u16, 1), index(&names, "visor \"blue\""));
    try std.testing.expectEqual(@as(u16, 2), index(&names, "café"));
    try std.testing.expectEqual(@as(u16, 1), index(&.{ "visor", "body" }, "body"));
}

test "missing, unnamed and ambiguous identifiers are rejected" {
    try std.testing.expectError(error.UnknownMaterialName, find(&.{ "body", "visor" }, "missing"));
    try std.testing.expectError(error.EmptyMaterialName, find(&.{""}, ""));
    try std.testing.expectError(error.AmbiguousMaterialName, find(&.{ "body", "body" }, "body"));
}

test "large material tables resolve without the default comptime branch limit" {
    const names = [_][]const u8{"unused"} ** 2000 ++ [_][]const u8{"last"};
    try std.testing.expectEqual(@as(u16, 2000), index(&names, "last"));
}
