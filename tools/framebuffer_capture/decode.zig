//! Decode one framed framebuffer from a relayed debug log.
const std = @import("std");

pub const Frame = struct {
    width: u16,
    height: u16,
    rgba: []u8,
    pub fn deinit(self: Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.rgba);
    }
};

/// Return the first complete transfer. Ordinary log lines are ignored. Reject
/// missing, duplicate, reordered, or truncated chunks rather than saving corruption.
pub fn decode(allocator: std.mem.Allocator, log: []const u8) !Frame {
    var lines = std.mem.tokenizeAny(u8, log, "\r\n");
    var transfer: Transfer = .{ .allocator = allocator };
    defer if (transfer.raw) |bytes| allocator.free(bytes);
    while (lines.next()) |line| {
        const start = std.mem.indexOf(u8, line, "@@PTERO_FB_") orelse continue;
        var fields = std.mem.tokenizeScalar(u8, line[start..], ' ');
        const tag = fields.next().?;
        if (try transfer.consume(tag, &fields)) return transfer.finish();
        if (fields.next() != null) return error.InvalidChunk;
    }
    return transfer.incomplete();
}

const Fields = std.mem.TokenIterator(u8, .scalar);
const Transfer = struct {
    allocator: std.mem.Allocator,
    raw: ?[]u8 = null,
    width: u16 = 0,
    height: u16 = 0,
    bpp: usize = 0,
    id: u32 = 0,
    offset: usize = 0,

    fn incomplete(self: Transfer) error{ NoCapture, IncompleteCapture } {
        return if (self.raw == null) error.NoCapture else error.IncompleteCapture;
    }

    fn consume(self: *Transfer, tag: []const u8, fields: *Fields) !bool {
        if (std.mem.eql(u8, tag, "@@PTERO_FB_BEGIN@@")) {
            try self.begin(fields);
        } else if (std.mem.eql(u8, tag, "@@PTERO_FB_DATA@@")) {
            try self.data(fields);
        } else if (std.mem.eql(u8, tag, "@@PTERO_FB_END@@")) {
            try self.checkId(fields);
            if (fields.next() != null) return error.InvalidChunk;
            return true;
        } else return error.InvalidChunk;
        return false;
    }

    fn begin(self: *Transfer, fields: *Fields) !void {
        if (self.raw != null) return error.IncompleteCapture;
        self.id = try integer(u32, fields);
        self.width = try integer(u16, fields);
        self.height = try integer(u16, fields);
        try dimensions(self.width, self.height);
        self.bpp = switch (try integer(u8, fields)) {
            16 => 2,
            32 => 4,
            else => return error.UnsupportedFormat,
        };
        self.raw = try self.allocator.alloc(u8, @as(usize, self.width) * self.height * self.bpp);
    }

    fn checkId(self: *Transfer, fields: *Fields) !void {
        if (self.raw == null) return error.MissingHeader;
        if (try integer(u32, fields) != self.id) return error.WrongCaptureId;
    }

    fn data(self: *Transfer, fields: *Fields) !void {
        try self.checkId(fields);
        if (try integer(usize, fields) != self.offset) return error.InvalidOffset;
        self.offset += try decodeChunk(self.raw.?[self.offset..], fields.next() orelse return error.InvalidChunk);
    }

    fn finish(self: *Transfer) !Frame {
        const bytes = self.raw.?;
        if (self.offset != bytes.len) return error.IncompleteCapture;
        return .{ .width = self.width, .height = self.height, .rgba = try expand(self.allocator, bytes, self.bpp) };
    }
};

fn dimensions(width: u16, height: u16) !void {
    if (width == 0 or height == 0 or width > 4096 or height > 4096) return error.InvalidDimensions;
}

fn decodeChunk(destination: []u8, hex: []const u8) !usize {
    if (hex.len == 0 or hex.len % 2 != 0 or hex.len / 2 > destination.len) return error.InvalidChunk;
    for (0..hex.len / 2) |i| destination[i] = std.fmt.parseInt(u8, hex[i * 2 ..][0..2], 16) catch return error.InvalidChunk;
    return hex.len / 2;
}

fn integer(comptime T: type, fields: *std.mem.TokenIterator(u8, .scalar)) !T {
    return std.fmt.parseInt(T, fields.next() orelse return error.InvalidChunk, 10) catch error.InvalidChunk;
}

fn expand(allocator: std.mem.Allocator, bytes: []const u8, bpp: usize) ![]u8 {
    const rgba = try allocator.alloc(u8, bytes.len / bpp * 4);
    for (0..bytes.len / bpp) |i| {
        if (bpp == 4) {
            @memcpy(rgba[i * 4 ..][0..4], bytes[i * 4 ..][0..4]);
        } else {
            const value = std.mem.readInt(u16, bytes[i * 2 ..][0..2], .big);
            inline for (.{ 11, 6, 1 }, 0..) |shift, channel| {
                const v: u8 = @intCast((value >> shift) & 31);
                rgba[i * 4 + channel] = (v << 3) | (v >> 2);
            }
            rgba[i * 4 + 3] = if (value & 1 != 0) 255 else 0;
        }
    }
    return rgba;
}

test "RGBA16 decoding ignores debug prefixes and expands five bit channels" {
    const a = std.testing.allocator;
    const frame = try decode(a, "noise\n[debug] @@PTERO_FB_BEGIN@@ 4 2 1 16\n@@PTERO_FB_DATA@@ 4 0 f80107c1\n@@PTERO_FB_END@@ 4\n");
    defer frame.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 }, frame.rgba);
}

test "RGBA32 capture and malformed transfer validation" {
    const a = std.testing.allocator;
    const frame = try decode(a, "@@PTERO_FB_BEGIN@@ 0 1 1 32\n@@PTERO_FB_DATA@@ 0 0 12345678\n@@PTERO_FB_END@@ 0\n");
    defer frame.deinit(a);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x34, 0x56, 0x78 }, frame.rgba);
    const header = "@@PTERO_FB_BEGIN@@ 0 1 1 16\n";
    try std.testing.expectError(error.IncompleteCapture, decode(a, header));
    try std.testing.expectError(error.InvalidOffset, decode(a, header ++ "@@PTERO_FB_DATA@@ 0 1 ffff\n"));
    try std.testing.expectError(error.InvalidChunk, decode(a, header ++ "@@PTERO_FB_DATA@@ 0 0 zz00\n"));
    try std.testing.expectError(error.WrongCaptureId, decode(a, header ++ "@@PTERO_FB_END@@ 1\n"));
    try std.testing.expectError(error.IncompleteCapture, decode(a, header ++ "@@PTERO_FB_END@@ 0\n"));
    try std.testing.expectError(error.InvalidDimensions, decode(a, "@@PTERO_FB_BEGIN@@ 0 0 1 16\n"));
    try std.testing.expectError(error.NoCapture, decode(a, "ordinary log\n"));
    try std.testing.expectError(error.UnsupportedFormat, decode(a, "@@PTERO_FB_BEGIN@@ 0 1 1 8\n"));
    try std.testing.expectError(error.MissingHeader, decode(a, "@@PTERO_FB_DATA@@ 0 0 ffff\n"));
    try std.testing.expectError(error.InvalidChunk, decode(a, header ++ "@@PTERO_FB_DATA@@ 0 0 ffffff\n"));
    try std.testing.expectError(error.InvalidChunk, decode(a, header ++ "@@PTERO_FB_DATA@@ 0 0 ffff extra\n"));
    try std.testing.expectError(error.InvalidOffset, decode(a, header ++ "@@PTERO_FB_DATA@@ 0 0 ffff\n@@PTERO_FB_DATA@@ 0 0 ffff\n"));
    try std.testing.expectError(error.IncompleteCapture, decode(a, header ++ header));
}

test {
    _ = @import("png.zig");
}
