const std = @import("std");
pub fn read(io: std.Io, a: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(a, .limited(limit));
}

pub fn loadConfig(io: std.Io, a: std.mem.Allocator, path: ?[]const u8) !@import("options.zig").Options {
    const name = path orelse return .{};
    const bytes = try read(io, a, name, 64 * 1024);
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(@import("options.zig").Options, a, bytes, .{ .allocate = .alloc_always });
    // This function is called with the CLI arena; strings remain live until exit.
    var options = parsed.value;
    if (options.ha_token_file) |token| options.ha_token_file = try configRelativePath(a, name, token);
    return options;
}
fn configRelativePath(a: std.mem.Allocator, config: []const u8, path: []const u8) ![]const u8 {
    if (std.fs.path.isAbsolute(path)) return path;
    return std.fs.path.join(a, &.{ std.fs.path.dirname(config) orelse ".", path });
}

test "config token paths are relative to config location" {
    const path = try configRelativePath(std.testing.allocator, "/project/config/deploy.json", "token.txt");
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/project/config/token.txt", path);
    try std.testing.expectEqualStrings("/private/token", try configRelativePath(std.testing.allocator, "x", "/private/token"));
}

test "configuration files load defaults, resolve token paths and reject unknown keys" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try temp.dir.writeFile(io, .{ .sub_path = "config.json", .data = "{\"target\":\"everdrive\",\"ha_token_file\":\"secret\"}" });
    const path = try temp.dir.realPathFileAlloc(io, "config.json", a);
    const o = try loadConfig(io, a, path);
    try std.testing.expectEqual(@import("options.zig").Target.everdrive, o.target);
    try std.testing.expect(std.fs.path.isAbsolute(o.ha_token_file.?));
    try std.testing.expectEqual(@import("options.zig").Target.sc64, (try loadConfig(io, a, null)).target);
    try temp.dir.writeFile(io, .{ .sub_path = "config.json", .data = "{\"typo\":1}" });
    try std.testing.expectError(error.UnknownField, loadConfig(io, a, path));
}
