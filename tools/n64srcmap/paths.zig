const std = @import("std");

pub fn normalizedProjectRoot(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try normalizeSlashes(alloc, path);
    defer alloc.free(normalized);

    var trimmed_len = normalized.len;
    while (trimmed_len > 1 and normalized[trimmed_len - 1] == '/') {
        trimmed_len -= 1;
    }

    return alloc.dupe(u8, normalized[0..trimmed_len]);
}

pub fn normalizeDisplayPath(
    alloc: std.mem.Allocator,
    project_root: []const u8,
    path: []const u8,
) ![]u8 {
    const normalized = try normalizeSlashes(alloc, path);
    defer alloc.free(normalized);

    if (stripPathPrefix(normalized, project_root)) |relative| {
        return alloc.dupe(u8, relative);
    }

    if (stripZigLibPrefix(normalized)) |relative| {
        return alloc.dupe(u8, relative);
    }

    return alloc.dupe(u8, normalized);
}

pub fn readFileLine(
    io: std.Io,
    alloc: std.mem.Allocator,
    path: []const u8,
    line_num: u16,
) ![]const u8 {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return alloc.dupe(u8, "");
    defer file.close(io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(io, &buf);

    var current: u16 = 1;
    while (true) {
        const line = reader.interface.takeDelimiterInclusive('\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (current == line_num) {
                    const remaining = reader.interface.buffered();
                    return try alloc.dupe(u8, std.mem.trimEnd(u8, remaining, "\r\n"));
                }
                return try alloc.dupe(u8, "");
            },
            else => |e| return e,
        };

        if (current == line_num) {
            return try alloc.dupe(u8, std.mem.trimEnd(u8, line, "\r\n"));
        }
        current += 1;
    }
}

fn normalizeSlashes(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    const normalized = try alloc.dupe(u8, path);
    for (normalized) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return normalized;
}

fn stripPathPrefix(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (path.len == prefix.len and std.mem.eql(u8, path, prefix)) return "";
    if (path.len <= prefix.len or path[prefix.len] != '/') return null;
    if (!startsWithPath(path, prefix)) return null;
    return path[prefix.len + 1 ..];
}

fn startsWithPath(path: []const u8, prefix: []const u8) bool {
    if (path.len < prefix.len) return false;
    if (nativePathCaseInsensitive()) {
        return std.ascii.eqlIgnoreCase(path[0..prefix.len], prefix);
    }
    return std.mem.eql(u8, path[0..prefix.len], prefix);
}

fn stripZigLibPrefix(path: []const u8) ?[]const u8 {
    const marker = "/lib/zig/";
    if (std.mem.indexOf(u8, path, marker)) |idx| {
        return path[idx + marker.len ..];
    }

    // Some installs use a directory named just "zig" as the lib dir.
    const std_marker = "/zig/std/";
    if (std.mem.indexOf(u8, path, std_marker)) |idx| {
        return path[idx + "/zig/".len ..];
    }

    return null;
}

fn nativePathCaseInsensitive() bool {
    return switch (@import("builtin").os.tag) {
        .windows, .uefi => true,
        else => false,
    };
}
