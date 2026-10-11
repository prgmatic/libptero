const std = @import("std");
const Options = @import("options.zig").Options;
const files = @import("files.zig");

pub const Client = struct {
    http: std.http.Client,
    allocator: std.mem.Allocator,
    base: []const u8,
    entity: []const u8,
    authorization: []const u8,

    pub fn init(io: std.Io, a: std.mem.Allocator, options: Options, environment_token: ?[]const u8) !?Client {
        const base = options.ha_url orelse return null;
        const token = try loadToken(io, a, options.ha_token_file, environment_token);
        const auth = try std.fmt.allocPrint(a, "Bearer {s}", .{token});
        return .{ .http = .{ .io = io, .allocator = a }, .allocator = a, .base = base, .entity = options.ha_entity.?, .authorization = auth };
    }
    pub fn deinit(self: *Client) void {
        self.http.deinit();
        self.allocator.free(self.authorization);
    }
    pub fn set(self: *Client, enabled: bool) !void {
        const url = try endpoint(self.allocator, self.base, enabled);
        defer self.allocator.free(url);
        const body = try payload(self.allocator, self.entity);
        defer self.allocator.free(body);
        const result = try self.http.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .redirect_behavior = .not_allowed,
            .headers = .{ .authorization = .{ .override = self.authorization }, .content_type = .{ .override = "application/json" } },
        });
        try checkStatus(@intFromEnum(result.status));
    }
};

fn loadToken(io: std.Io, a: std.mem.Allocator, path: ?[]const u8, environment: ?[]const u8) ![]const u8 {
    if (environment) |token| return validateToken(token);
    const file = path orelse return error.MissingHomeAssistantToken;
    return validateToken(try files.read(io, a, file, 16 * 1024));
}
fn validateToken(bytes: []const u8) ![]const u8 {
    const token = std.mem.trim(u8, bytes, " \r\n\t");
    if (token.len == 0) return error.EmptyHomeAssistantToken;
    if (std.mem.indexOfAny(u8, token, "\r\n") != null) return error.InvalidHomeAssistantToken;
    return token;
}
fn endpoint(a: std.mem.Allocator, base: []const u8, enabled: bool) ![]u8 {
    const action = if (enabled) "turn_on" else "turn_off";
    return std.fmt.allocPrint(a, "{s}/api/services/homeassistant/{s}", .{ std.mem.trimEnd(u8, base, "/"), action });
}
fn payload(a: std.mem.Allocator, entity: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .entity_id = entity }, .{});
}
fn checkStatus(status: u16) !void {
    if (status < 200 or status >= 300) return error.HomeAssistantRequestFailed;
}

/// Cleanup policy is independent of USB: enabled sessions own console power
/// until successfully handed off with keep-on. Errors always request power-off.
pub const Session = struct {
    context: *anyopaque,
    set_fn: *const fn (*anyopaque, bool) anyerror!void,
    armed: bool = false,
    pub fn begin(self: *Session, target: @import("options.zig").Target) !void {
        self.armed = true;
        try self.set_fn(self.context, target == .everdrive);
    }
    pub fn boot(self: *Session, target: @import("options.zig").Target) !void {
        if (target == .sc64) try self.set_fn(self.context, true);
    }
    pub fn finish(self: *Session, keep_on: bool) void {
        if (keep_on) self.armed = false;
    }
    pub fn close(self: *Session) !void {
        if (self.armed) try self.set_fn(self.context, false);
        self.armed = false;
    }
};
pub fn session(client: *Client) Session {
    return .{ .context = client, .set_fn = setClient };
}
fn setClient(ctx: *anyopaque, enabled: bool) !void {
    const client: *Client = @ptrCast(@alignCast(ctx));
    try client.set(enabled);
}

test "Home Assistant request construction and token validation" {
    const a = std.testing.allocator;
    const url = try endpoint(a, "http://localhost:8123/", false);
    defer a.free(url);
    try std.testing.expectEqualStrings("http://localhost:8123/api/services/homeassistant/turn_off", url);
    const body = try payload(a, "switch.\"n64");
    defer a.free(body);
    try std.testing.expectEqualStrings("{\"entity_id\":\"switch.\\\"n64\"}", body);
    try std.testing.expectEqualStrings("secret", try validateToken(" secret\n"));
    try std.testing.expectError(error.EmptyHomeAssistantToken, validateToken("\n"));
    try std.testing.expectError(error.InvalidHomeAssistantToken, validateToken("x\ny"));
    try checkStatus(200);
    try std.testing.expectError(error.HomeAssistantRequestFailed, checkStatus(401));
}

test "token environment overrides file and absence produces a useful error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const a = arena.allocator();
    const io = std.testing.io;
    try temp.dir.writeFile(io, .{ .sub_path = "token", .data = "file-secret\n" });
    const path = try temp.dir.realPathFileAlloc(io, "token", a);
    try std.testing.expectEqualStrings("file-secret", try loadToken(io, a, path, null));
    try std.testing.expectEqualStrings("env-secret", try loadToken(io, a, path, "env-secret"));
    try std.testing.expectError(error.MissingHomeAssistantToken, loadToken(io, a, null, null));
}

test "power sequencing shuts down on failures and keeps on only after success" {
    const Fake = struct {
        values: std.ArrayList(bool) = .empty,
        fn set(ctx: *anyopaque, enabled: bool) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try self.values.append(std.testing.allocator, enabled);
        }
    };
    var fake: Fake = .{};
    defer fake.values.deinit(std.testing.allocator);
    var s: Session = .{ .context = &fake, .set_fn = Fake.set };
    try s.begin(.sc64);
    try s.boot(.sc64);
    try s.close();
    try std.testing.expectEqualSlices(bool, &.{ false, true, false }, fake.values.items);
    try s.begin(.everdrive);
    try s.boot(.everdrive);
    s.finish(true);
    try s.close();
    try std.testing.expectEqualSlices(bool, &.{ false, true, false, true }, fake.values.items);
}
