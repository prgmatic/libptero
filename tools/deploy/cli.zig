const std = @import("std");
const options = @import("options.zig");
const files = @import("files.zig");
const power = @import("power.zig");

pub const usage =
    \\Usage: ptero-deploy [options] <rom.z64|rom.v64|rom.n64>
    \\       ptero-deploy [options] power-on|power-off
    \\  --target sc64|everdrive|ares   Backend (default: sc64)
    \\  --wait                       Exit on debug.finish; require completion
    \\  --test                       Require completion; enforce test deadlines
    \\  --interactive                Listen until completion or Ctrl-C (default)
    \\  --config <file.json>          Defaults; command-line flags override these
    \\  --serial <USB serial>         Select a cartridge by FTDI serial number
    \\  --device-index <n>            Select matching USB device (default: 0)
    \\  --ares <executable>           ares path (default: ares on PATH)
    \\  --save <type>                 none,eeprom4k,eeprom16k,sram,flashram,sram_banked,sram1m
    \\  --cic-seed <byte>             Override SC64 automatic IPL3 signing seed
    \\  --timeout-ms <n>              Whole-run timeout for --wait (default: 30000)
    \\  --startup-timeout-ms <n>      Time to first test for --test (default: 1000)
    \\  --test-timeout-ms <n>         Per-test timeout (default: 200)
    \\  --ha-url <url>                Enable optional Home Assistant power control
    \\  --ha-entity <entity>          Console power entity, e.g. switch.n64
    \\  --ha-token-file <path>        Token file; PTERO_HA_TOKEN overrides it
    \\  --power-delay-ms <n>          Wait after initial power change (default: 1500)
    \\  --keep-on                    Leave managed console on after a completed run
    \\Exit codes: 0 success, 1 ROM failure, 2 infrastructure failure, 130 interrupted.
    \\SC64: upload while off, then power on. EverDrive: power on into its OS menu first.
    \\Without Home Assistant, control console power manually. ares needs a display.
    \\
;

pub fn run(init: std.process.Init) !u8 {
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const config = try configFile(args[1..], init.environ_map);
    const defaults = try files.loadConfig(init.io, a, config);
    const parsed = try options.parse(args[1..], defaults);
    if (parsed.action == .help) {
        try std.Io.File.stdout().writeStreamingAll(init.io, usage);
        return 0;
    }
    @import("interrupt.zig").install();
    return execute(init, parsed);
}
fn configFile(args: []const []const u8, env: *const std.process.Environ.Map) !?[]const u8 {
    return try options.configPath(args) orelse env.get("PTERO_DEPLOY_CONFIG");
}

fn execute(init: std.process.Init, o: options.Options) !u8 {
    const a = init.arena.allocator();
    var ha = try power.Client.init(init.io, a, o, init.environ_map.get("PTERO_HA_TOKEN"));
    defer deinitPower(&ha);
    if (o.action != .run) {
        try ha.?.set(o.action == .power_on);
        return 0;
    }
    return executeRun(init.io, a, o, &ha);
}
fn executeRun(io: std.Io, a: std.mem.Allocator, o: options.Options, ha: *?power.Client) !u8 {
    const rom = try files.read(io, a, o.rom.?, @import("rom.zig").max_size + 1);
    defer a.free(rom);
    try @import("rom.zig").normalize(rom);
    if (o.target == .ares) return @import("ares.zig").run(io, a, o, o.rom.?);
    return deployHardware(io, a, o, rom, ha);
}
fn deinitPower(ha: *?power.Client) void {
    if (ha.*) |*client| client.deinit();
}

fn deployHardware(io: std.Io, a: std.mem.Allocator, o: options.Options, rom: []u8, ha: *?power.Client) !u8 {
    var session: ?power.Session = if (ha.*) |*client| power.session(client) else null;
    errdefer cleanup(&session);
    try beginPower(io, o, &session);
    const code = try @import("hardware.zig").run(io, a, o, rom, sessionPtr(&session));
    try endPower(&session, keepPowerOn(o.keep_on, code));
    return code;
}
fn keepPowerOn(requested: bool, code: u8) bool {
    return requested and code == 0;
}
fn sessionPtr(session: *?power.Session) ?*power.Session {
    return if (session.*) |*s| s else null;
}
fn beginPower(io: std.Io, o: options.Options, session: *?power.Session) !void {
    if (session.*) |*s| {
        try s.begin(o.target);
        try std.Io.sleep(io, .fromMilliseconds(o.power_delay_ms), .awake);
    }
}
fn endPower(session: *?power.Session, keep_on: bool) !void {
    if (session.*) |*s| {
        s.finish(keep_on);
        try s.close();
    }
}
fn cleanup(session: *?power.Session) void {
    endPower(session, false) catch |err| std.debug.print("ptero-deploy: console power-off failed: {s}\n", .{@errorName(err)});
}

pub fn report(err: anyerror) u8 {
    std.debug.print("ptero-deploy: {s}\n", .{@errorName(err)});
    if (hint(err)) |message| std.debug.print("{s}\n", .{message});
    return errorCode(err);
}
fn errorCode(err: anyerror) u8 {
    return if (err == error.Interrupted) 130 else 2;
}
fn hint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.LibFtdiNotFound => "Install libftdi1 (Linux: libftdi1.so.2; macOS: libftdi1.dylib). ares does not need it.",
        error.UsbPermissionDenied => "USB access was denied. Check device permissions and whether another uploader owns the device.",
        error.UsbDeviceNotFound => "No matching USB cartridge found. Check the cable, --target, --serial and --device-index.",
        error.UsbTimeout, error.EverDriveMenuNotReady => "USB communication timed out. EverDrive must be powered on in its OS menu before upload.",
        else => runHint(err),
    };
}
fn runHint(err: anyerror) ?[]const u8 {
    return switch (err) {
        error.MissingHomeAssistantToken => "Set PTERO_HA_TOKEN or --ha-token-file; configure --ha-url and --ha-entity together.",
        error.RunTimeout => "The ROM did not report completion/progress before its deadline.",
        error.MissingCompletion => "The emulator exited without calling n64.debug.finish(...).",
        else => null,
    };
}

test "actionable errors have concise diagnostics" {
    try std.testing.expect(hint(error.LibFtdiNotFound) != null);
    try std.testing.expectEqual(null, hint(error.Unknown));
    try std.testing.expect(keepPowerOn(true, 0));
    try std.testing.expect(!keepPowerOn(true, 1));
    try std.testing.expect(!keepPowerOn(false, 0));
}
