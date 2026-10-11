const std = @import("std");
const Options = @import("options.zig").Options;
const Relay = @import("relay.zig").Relay;

pub fn run(io: std.Io, a: std.mem.Allocator, options: Options, rom_path: []const u8) !u8 {
    const setting = try discoverSetting(io, a, options.ares);
    const argv = arguments(options.ares, rom_path, setting);
    var child = try std.process.spawn(io, .{ .argv = &argv, .stdout = .pipe, .stderr = .inherit, .stdin = .ignore });
    defer child.kill(io);
    var relay = Relay.init(io, options);
    return listen(io, &child, &relay);
}

fn discoverSetting(io: std.Io, a: std.mem.Allocator, executable: []const u8) ![]const u8 {
    const result = try std.process.run(a, io, .{
        .argv = &.{ executable, "--dump-all-settings" },
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(5), .clock = .awake } },
    });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try successfulExit(result.term);
    return selectSetting(result.stdout);
}
fn selectSetting(settings: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, settings, "Developer/HomebrewMode") != null) return "Developer/HomebrewMode=true";
    if (std.mem.indexOf(u8, settings, "General/HomebrewMode") != null) return "General/HomebrewMode=true";
    return error.UnsupportedAresVersion;
}
pub fn arguments(executable: []const u8, rom: []const u8, setting: []const u8) [9][]const u8 {
    return .{ executable, "--no-file-prompt", "--system", "Nintendo 64", "--setting", setting, "--setting", "Input/Defocus=Block", rom };
}

fn listen(io: std.Io, child: *std.process.Child, relay: *Relay) !u8 {
    const stdout = child.stdout orelse return error.MissingDebugPipe;
    var buffer: [4096]u8 = undefined;
    while (true) {
        try relay.check();
        if (!try readable(stdout.handle)) continue;
        const n = try std.posix.read(stdout.handle, &buffer);
        if (n == 0) return childExited(io, child, relay);
        if (try relay.feed(buffer[0..n])) |code| return code;
    }
}
fn readable(fd: std.posix.fd_t) !bool {
    var poll = [_]std.posix.pollfd{.{ .fd = fd, .events = std.posix.POLL.IN, .revents = 0 }};
    return try std.posix.poll(&poll, 10) != 0;
}
fn childExited(io: std.Io, child: *std.process.Child, relay: *Relay) !u8 {
    try successfulExit(try child.wait(io));
    return relay.monitor.eof();
}
fn successfulExit(term: std.process.Child.Term) !void {
    switch (term) {
        .exited => |code| if (code != 0) return error.AresFailed,
        else => return error.AresFailed,
    }
}

test "ares arguments handle old and new homebrew setting names" {
    const setting = try selectSetting("Video\nGeneral/HomebrewMode\n");
    const args = arguments("custom-ares", "/roms/my game.z64", setting);
    try std.testing.expectEqualStrings("/roms/my game.z64", args[8]);
    try std.testing.expectEqualStrings("Input/Defocus=Block", args[7]);
    try std.testing.expectEqualStrings("General/HomebrewMode=true", args[5]);
    try std.testing.expectEqualStrings("Developer/HomebrewMode=true", try selectSetting("Developer/HomebrewMode\n"));
    try std.testing.expectError(error.UnsupportedAresVersion, selectSetting("Video\n"));
    try successfulExit(.{ .exited = 0 });
    try std.testing.expectError(error.AresFailed, successfulExit(.{ .exited = 1 }));
}

fn testProcess(program: []const u8, options: Options) !u8 {
    const io = std.testing.io;
    var child = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", program }, .stdout = .pipe, .stderr = .inherit });
    defer child.kill(io);
    var relay = Relay.init(io, options);
    var buffer: [4096]u8 = undefined;
    var output = std.Io.Writer.fixed(&buffer);
    relay.output = &output;
    return listen(io, &child, &relay);
}

test "emulator lifecycle reports ROM failure, missing completion, child failure and timeout" {
    try std.testing.expectEqual(@as(u8, 0), try testProcess("printf '@@LIBPTERO_'; printf 'RUN_END@@ {\"code\":0}\\n'; while :; do :; done", .{ .mode = .wait }));
    try std.testing.expectEqual(@as(u8, 1), try testProcess("printf '@@LIBPTERO_RUN_END@@ {\"code\":1}\\n'", .{ .mode = .wait }));
    try std.testing.expectError(error.MissingCompletion, testProcess("exit 0", .{ .mode = .wait }));
    try std.testing.expectError(error.AresFailed, testProcess("exit 7", .{}));
    try std.testing.expectEqual(@as(u8, 0), try testProcess("exit 0", .{}));
    try std.testing.expectError(error.RunTimeout, testProcess("while :; do :; done", .{ .mode = .wait, .timeout_ms = 10 }));
}
