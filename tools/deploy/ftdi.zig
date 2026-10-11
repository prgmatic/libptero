//! libftdi1 is loaded at runtime; cartridge protocols live entirely in Zig.
const std = @import("std");
const Stream = @import("stream.zig").Stream;
const interrupt = @import("interrupt.zig");
const Target = enum { sc64, everdrive };

// Stable public libftdi1 context ABI, needed for timeout and kernel-driver
// detach/reattach policy (libftdi has no setters for these fields).
const Context = extern struct {
    usb_ctx: ?*anyopaque,
    usb_dev: ?*anyopaque,
    read_timeout: c_int,
    write_timeout: c_int,
    chip_type: c_int,
    baudrate: c_int,
    bitbang_enabled: u8,
    readbuffer: ?[*]u8,
    readbuffer_offset: c_uint,
    readbuffer_remaining: c_uint,
    readbuffer_chunksize: c_uint,
    writebuffer_chunksize: c_uint,
    max_packet_size: c_uint,
    interface: c_int,
    index: c_int,
    in_ep: c_int,
    out_ep: c_int,
    bitbang_mode: u8,
    eeprom: ?*anyopaque,
    error_str: ?[*:0]const u8,
    module_detach_mode: c_int,
};

const Api = struct {
    ftdi_new: *const fn () callconv(.c) ?*Context,
    ftdi_free: *const fn (*Context) callconv(.c) void,
    ftdi_usb_open_desc_index: *const fn (*Context, c_int, c_int, ?[*:0]const u8, ?[*:0]const u8, c_uint) callconv(.c) c_int,
    ftdi_usb_close: *const fn (*Context) callconv(.c) c_int,
    ftdi_usb_reset: *const fn (*Context) callconv(.c) c_int,
    ftdi_tcioflush: *const fn (*Context) callconv(.c) c_int,
    ftdi_set_latency_timer: *const fn (*Context, u8) callconv(.c) c_int,
    ftdi_read_data: *const fn (*Context, [*]u8, c_int) callconv(.c) c_int,
    ftdi_write_data: *const fn (*Context, [*]const u8, c_int) callconv(.c) c_int,
    ftdi_setdtr: *const fn (*Context, c_int) callconv(.c) c_int,
    ftdi_poll_modem_status: *const fn (*Context, *u16) callconv(.c) c_int,
    fn load(library: *std.DynLib) !Api {
        var api: Api = undefined;
        inline for (@typeInfo(Api).@"struct".fields) |field| {
            @field(api, field.name) = try requiredSymbol(library, field.type, field.name);
        }
        return api;
    }
};

fn requiredSymbol(library: *std.DynLib, comptime T: type, comptime name: []const u8) !T {
    return library.lookup(T, name ++ "\x00") orelse error.IncompatibleLibFtdi;
}

pub const Device = struct {
    library: std.DynLib,
    api: Api,
    context: *Context,
    io: std.Io,
    pub fn open(io: std.Io, target: Target, serial: ?[:0]const u8, index: u32) !Device {
        var library = try openLibrary();
        errdefer library.close();
        const api = try Api.load(&library);
        const context = api.ftdi_new() orelse return error.OutOfMemory;
        errdefer api.ftdi_free(context);
        const identity = deviceIdentity(target);
        context.module_detach_mode = 2; // AUTO_DETACH_REATACH_SIO_MODULE
        try openResult(api.ftdi_usb_open_desc_index(context, 0x0403, identity.product, identity.description, serialPointer(serial), index));
        errdefer _ = api.ftdi_usb_close(context);
        var self: Device = .{ .library = library, .api = api, .context = context, .io = io };
        try self.configure();
        return self;
    }
    fn configure(self: *Device) !void {
        self.context.read_timeout = 10;
        self.context.write_timeout = 5000;
        try check(self.api.ftdi_usb_reset(self.context));
        try check(self.api.ftdi_set_latency_timer(self.context, 2));
        try check(self.api.ftdi_tcioflush(self.context));
    }
    pub fn close(self: *Device) void {
        _ = self.api.ftdi_usb_close(self.context);
        self.api.ftdi_free(self.context);
        self.library.close();
    }
    pub fn stream(self: *Device) Stream {
        return .{ .context = self, .vtable = &.{ .read = read, .write = write, .now = now, .sleep = sleep, .dtr = dtr, .dsr = dsr, .purge = purge } };
    }
    fn cast(ctx: *anyopaque) *Device {
        return @ptrCast(@alignCast(ctx));
    }
    fn read(ctx: *anyopaque, bytes: []u8) !usize {
        try interrupt.check();
        const self = cast(ctx);
        return count(self.api.ftdi_read_data(self.context, bytes.ptr, @intCast(@min(bytes.len, 0x10000))));
    }
    fn write(ctx: *anyopaque, bytes: []const u8) !usize {
        try interrupt.check();
        const self = cast(ctx);
        return count(self.api.ftdi_write_data(self.context, bytes.ptr, @intCast(@min(bytes.len, 0x8000))));
    }
    fn now(ctx: *anyopaque) i64 {
        return @intCast(@divTrunc(std.Io.Clock.awake.now(cast(ctx).io).nanoseconds, std.time.ns_per_ms));
    }
    fn sleep(ctx: *anyopaque, ms: u32) !void {
        try interrupt.check();
        try std.Io.sleep(cast(ctx).io, .fromMilliseconds(ms), .awake);
    }
    fn dtr(ctx: *anyopaque, enabled: bool) !void {
        const self = cast(ctx);
        try check(self.api.ftdi_setdtr(self.context, @intFromBool(enabled)));
    }
    fn dsr(ctx: *anyopaque) !bool {
        try interrupt.check();
        const self = cast(ctx);
        var status: u16 = 0;
        try check(self.api.ftdi_poll_modem_status(self.context, &status));
        return status & 0x20 != 0;
    }
    fn purge(ctx: *anyopaque) !void {
        const self = cast(ctx);
        try check(self.api.ftdi_tcioflush(self.context));
    }
};

fn openLibrary() !std.DynLib {
    const name = try libraryName(@import("builtin").os.tag);
    return std.DynLib.open(name) catch return error.LibFtdiNotFound;
}
fn libraryName(os: std.Target.Os.Tag) ![]const u8 {
    return switch (os) {
        .linux => "libftdi1.so.2",
        .macos => "libftdi1.dylib",
        else => error.UnsupportedHost,
    };
}
fn deviceIdentity(target: Target) struct { product: c_int, description: [*:0]const u8 } {
    return switch (target) {
        .sc64 => .{ .product = 0x6014, .description = "SC64" },
        .everdrive => .{ .product = 0x6001, .description = "FT245R USB FIFO" },
    };
}
fn serialPointer(serial: ?[:0]const u8) ?[*:0]const u8 {
    return if (serial) |s| s.ptr else null;
}
fn openResult(result: c_int) !void {
    return switch (result) {
        0 => {},
        -3 => error.UsbDeviceNotFound,
        -4, -5 => error.UsbPermissionDenied,
        else => error.UsbOpenFailed,
    };
}
fn check(result: c_int) !void {
    if (result < 0) return error.UsbIoFailed;
}
fn count(result: c_int) !usize {
    try check(result);
    return @intCast(result);
}

test "USB errors distinguish missing devices, permissions and transport failures" {
    try std.testing.expectEqualStrings("libftdi1.so.2", try libraryName(.linux));
    try std.testing.expectEqualStrings("libftdi1.dylib", try libraryName(.macos));
    try std.testing.expectError(error.UnsupportedHost, libraryName(.windows));
    try std.testing.expectEqual(@as(c_int, 0x6001), deviceIdentity(.everdrive).product);
    try std.testing.expectEqual(@as(c_int, 0x6014), deviceIdentity(.sc64).product);
    try openResult(0);
    try std.testing.expectError(error.UsbDeviceNotFound, openResult(-3));
    try std.testing.expectError(error.UsbPermissionDenied, openResult(-4));
    try std.testing.expectError(error.UsbOpenFailed, openResult(-9));
    try std.testing.expectError(error.UsbIoFailed, count(-1));
    try std.testing.expectEqual(@as(usize, 0), try count(0));
    try std.testing.expectEqual(@as(usize, 8), try count(8));
}
