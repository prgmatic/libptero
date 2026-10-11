const std = @import("std");
pub const Target = enum { sc64, everdrive, ares };
pub const Mode = enum { interactive, wait, tests };
pub const Action = enum { run, power_on, power_off, help };
pub const Save = enum(u32) { none, eeprom4k, eeprom16k, sram, flashram, sram_banked, sram1m };
pub const Options = struct {
    target: Target = .sc64,
    mode: Mode = .interactive,
    action: Action = .run,
    rom: ?[]const u8 = null,
    serial: ?[]const u8 = null,
    device_index: u32 = 0,
    ares: []const u8 = "ares",
    timeout_ms: u32 = 30_000,
    startup_timeout_ms: u32 = 1000,
    test_timeout_ms: u32 = 200,
    power_delay_ms: u32 = 1500,
    keep_on: bool = false,
    save: Save = .none,
    cic_seed: ?u8 = null,
    ha_url: ?[]const u8 = null,
    ha_entity: ?[]const u8 = null,
    ha_token_file: ?[]const u8 = null,

    pub fn validate(self: Options) !void {
        if (self.action == .help) return;
        try self.validatePower();
        if (self.action != .run) return;
        if (self.rom == null) return error.MissingRom;
        try self.validateTarget();
    }
    fn validateTarget(self: Options) !void {
        if (self.target == .ares and self.ha_url != null) return error.PowerControlWithEmulator;
        if (self.target != .sc64 and self.cic_seed != null) return error.CicSeedRequiresSc64;
    }
    fn validatePower(self: Options) !void {
        if ((self.ha_url == null) != (self.ha_entity == null)) return error.IncompleteHomeAssistantConfig;
        if (self.action != .run and self.ha_url == null) return error.HomeAssistantNotConfigured;
        if (self.ha_token_file != null and self.ha_url == null) return error.IncompleteHomeAssistantConfig;
    }
};

pub fn configPath(args: []const []const u8) !?[]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--config")) {
            if (i + 1 == args.len) return error.MissingOptionValue;
            return args[i + 1];
        }
    }
    return null;
}

pub fn parse(args: []const []const u8, defaults: Options) !Options {
    var result = defaults;
    if (args.len == 0) result.action = .help;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (try flag(&result, args[i])) continue;
        if (std.mem.startsWith(u8, args[i], "--")) {
            i += 1;
            if (i == args.len) return error.MissingOptionValue;
            try option(&result, args[i - 1], args[i]);
        } else try positional(&result, args[i]);
    }
    try result.validate();
    return result;
}

fn flag(o: *Options, arg: []const u8) !bool {
    const flags = .{ .{ "--help", "action", Action.help }, .{ "-h", "action", Action.help }, .{ "--wait", "mode", Mode.wait }, .{ "--test", "mode", Mode.tests }, .{ "--interactive", "mode", Mode.interactive }, .{ "--keep-on", "keep_on", true } };
    inline for (flags) |f| {
        if (std.mem.eql(u8, arg, f[0])) {
            @field(o, f[1]) = f[2];
            return true;
        }
    }
    return false;
}
fn positional(o: *Options, arg: []const u8) !void {
    if (std.mem.eql(u8, arg, "power-on")) {
        o.action = .power_on;
        return;
    }
    if (std.mem.eql(u8, arg, "power-off")) {
        o.action = .power_off;
        return;
    }
    if (o.rom != null) return error.UnexpectedArgument;
    o.rom = arg;
}
fn option(o: *Options, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "--config")) return;
    const strings = .{ .{ "--serial", "serial" }, .{ "--ares", "ares" }, .{ "--ha-url", "ha_url" }, .{ "--ha-entity", "ha_entity" }, .{ "--ha-token-file", "ha_token_file" } };
    inline for (strings) |s| {
        if (std.mem.eql(u8, key, s[0])) {
            @field(o, s[1]) = value;
            return;
        }
    }
    try numericOrEnum(o, key, value);
}
fn numericOrEnum(o: *Options, key: []const u8, value: []const u8) !void {
    const numbers = .{ .{ "--device-index", "device_index" }, .{ "--timeout-ms", "timeout_ms" }, .{ "--startup-timeout-ms", "startup_timeout_ms" }, .{ "--test-timeout-ms", "test_timeout_ms" }, .{ "--power-delay-ms", "power_delay_ms" } };
    inline for (numbers) |n| {
        if (std.mem.eql(u8, key, n[0])) {
            @field(o, n[1]) = std.fmt.parseInt(u32, value, 10) catch return error.InvalidNumber;
            return;
        }
    }
    try enumOption(o, key, value);
}
fn enumOption(o: *Options, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "--target")) {
        o.target = try enumValue(Target, value);
        return;
    }
    if (std.mem.eql(u8, key, "--save")) {
        o.save = try enumValue(Save, value);
        return;
    }
    if (std.mem.eql(u8, key, "--cic-seed")) {
        o.cic_seed = std.fmt.parseInt(u8, value, 0) catch return error.InvalidNumber;
        return;
    }
    return error.UnknownOption;
}
fn enumValue(comptime T: type, text: []const u8) !T {
    return std.meta.stringToEnum(T, text) orelse error.InvalidOptionValue;
}

test "CLI options override config and validate combinations" {
    const o = try parse(&.{ "--target", "everdrive", "--wait", "--timeout-ms", "25000", "--device-index", "2", "--serial", "cart", "--save", "eeprom4k", "game.z64" }, .{});
    try std.testing.expectEqual(Target.everdrive, o.target);
    try std.testing.expectEqual(Mode.wait, o.mode);
    try std.testing.expectEqual(@as(u32, 25000), o.timeout_ms);
    try std.testing.expectEqual(@as(u32, 2), o.device_index);
    try std.testing.expectEqual(Save.eeprom4k, o.save);
    try std.testing.expectEqualStrings("cart", o.serial.?);
    try std.testing.expectEqual(Action.help, (try parse(&.{}, .{})).action);
    try std.testing.expectEqualStrings("cfg.json", (try configPath(&.{ "--config", "cfg.json" })).?);
    try std.testing.expectError(error.MissingOptionValue, configPath(&.{"--config"}));
    try std.testing.expectError(error.InvalidNumber, parse(&.{ "--timeout-ms", "bad", "game" }, .{}));
    try std.testing.expectError(error.UnknownOption, parse(&.{ "--oops", "x" }, .{}));
    try std.testing.expectError(error.MissingOptionValue, parse(&.{"--target"}, .{}));
    try std.testing.expectError(error.PowerControlWithEmulator, parse(&.{ "--target", "ares", "game" }, .{ .ha_url = "url", .ha_entity = "switch.n64" }));
    try std.testing.expectError(error.HomeAssistantNotConfigured, parse(&.{"power-off"}, .{}));
    try std.testing.expectEqual(Action.power_on, (try parse(&.{"power-on"}, .{ .ha_url = "url", .ha_entity = "switch.n64" })).action);
}
