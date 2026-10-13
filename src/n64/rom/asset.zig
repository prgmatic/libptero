//! Typed cartridge payloads with explicit, stable-address RAM ownership.
const std = @import("std");
const rom = @import("../rom.zig");
const scheduling = @import("scheduler.zig");

/// Generated Definition provides byte_len, Storage, Value and bind(). Metadata
/// stays native Zig; payloads contain hardware-ready bytes without pointer fixups.
pub fn Asset(comptime Definition: type) type {
    return struct {
        pub const Loaded = LoadedAsset(Definition, scheduling.Transfer);
        pub const Value = Definition.Value;
        asset: rom.Region,

        /// Model material identifiers are available before the cartridge payload is loaded.
        pub fn materialIndex(_: @This(), comptime name: []const u8) u16 {
            if (!@hasDecl(Value, "materialIndex")) @compileError("materialIndex requires a typed model asset");
            return Value.materialIndex(undefined, name);
        }

        pub fn storageSize(_: @This()) usize {
            return std.mem.alignForward(usize, Definition.byte_len, 16);
        }

        /// Allocate only; call load or begin after placing the result at its final
        /// address. Use the same allocator for deinit. Owners must not be copied.
        pub fn init(self: @This(), allocator: std.mem.Allocator) !Loaded {
            const bytes = try allocator.alignedAlloc(u8, .@"16", self.storageSize());
            errdefer allocator.free(bytes);
            var result = try self.initBuffer(bytes);
            result.owned = true;
            return result;
        }

        /// Borrow complete DMA cache lines. Extra storage is left untouched.
        pub fn initBuffer(self: @This(), bytes: []align(16) u8) !Loaded {
            if (self.asset.size != Definition.byte_len) return error.InvalidAsset;
            if (bytes.len < self.storageSize()) return error.BufferTooSmall;
            return .{ .source = self.asset, .bytes = bytes[0..self.storageSize()] };
        }
    };
}

fn LoadedAsset(comptime Definition: type, comptime Transfer: type) type {
    return struct {
        source: rom.Region,
        bytes: []align(16) u8,
        owned: bool = false,
        transfer: Transfer = .{},
        metadata: Definition.Storage = undefined,
        value: ?Definition.Value = null,
        loading: bool = false,

        pub const Layout = Definition;
        /// Enqueue a bounded load. Drive queue.service()/serviceAudio(), then
        /// poll this owner. Scheduled waits reject blocking to avoid starving audio.
        pub fn beginScheduled(self: *@This(), queue: *scheduling.Scheduler, priority: scheduling.Priority) !void {
            if (self.loading) return error.AssetBusy;
            if (self.value != null) return error.AlreadyLoaded;
            self.transfer.scheduler = if (self.bytes.len == 0) null else queue;
            self.transfer.priority = priority;
            errdefer self.transfer.scheduler = null;
            try @import("load.zig").begin(self);
        }
        pub const begin = @import("load.zig").begin;
        pub const poll = @import("load.zig").poll;
        pub const wait = @import("load.zig").wait;
        pub const load = @import("load.zig").load;
        pub const view = @import("load.zig").view;
        pub const unload = @import("load.zig").unload;
        pub const deinit = @import("load.zig").deinit;
    };
}

test "typed storage validates payload size, cache lines, extra capacity and allocation failures" {
    const Fixture = TestDefinition;
    const asset: Asset(Fixture) = .{ .asset = .{ .offset = 0, .size = Fixture.byte_len } };
    var bytes: [48]u8 align(16) = @splat(0xaa);
    var borrowed = try asset.initBuffer(&bytes);
    try std.testing.expectEqual(@as(usize, 32), borrowed.bytes.len);
    try std.testing.expectError(error.NotLoaded, borrowed.view());
    try std.testing.expectError(error.BufferTooSmall, asset.initBuffer(bytes[0..16]));
    try borrowed.deinit(std.testing.failing_allocator);
    try std.testing.expectEqual(@as(u8, 0xaa), bytes[47]);
    const invalid: Asset(Fixture) = .{ .asset = .{ .offset = 0, .size = 16 } };
    try std.testing.expectError(error.InvalidAsset, invalid.initBuffer(&bytes));
    try std.testing.expectError(error.OutOfMemory, asset.init(std.testing.failing_allocator));
    var owned = try asset.init(std.testing.allocator);
    try std.testing.expect(owned.owned);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(owned.bytes.ptr) % 16);
    try owned.deinit(std.testing.allocator);
}

test "DMA retry retains storage, binds once, and gives reloaded data a new identity" {
    const old_offset = rom.__rom_assets_rom_offset;
    const old_size = rom.__rom_assets_rom_size;
    defer {
        rom.__rom_assets_rom_offset = old_offset;
        rom.__rom_assets_rom_size = old_size;
    }
    rom.__rom_assets_rom_offset = 0x1000;
    rom.__rom_assets_rom_size = 32;
    var bytes: [32]u8 align(16) = @splat(0);
    var loaded: LoadedAsset(TestDefinition, TestTransfer) = .{ .source = .{ .offset = 0, .size = 17 }, .bytes = &bytes };
    try std.testing.expectError(error.NotLoaded, loaded.wait(10));
    loaded.transfer.busy = true;
    try std.testing.expectError(error.PiBusy, loaded.begin());
    try std.testing.expect(!loaded.loading);
    loaded.transfer.busy = false;
    try std.testing.expectError(error.PiTimeout, loaded.load(0));
    try std.testing.expectError(error.AssetBusy, loaded.begin());
    try std.testing.expectError(error.AssetBusy, loaded.unload());
    try std.testing.expectError(error.AssetBusy, loaded.deinit(std.testing.allocator));
    try std.testing.expectError(error.NotLoaded, loaded.view());
    loaded.transfer.complete = true;
    try loaded.load(10);
    const first = try loaded.view();
    try std.testing.expectEqual(@as(u8, 42), first.bytes[0]);
    try std.testing.expectEqual(@as(usize, 17), first.bytes.len);
    try std.testing.expectEqual(@as(u32, 0x1000), loaded.transfer.offset);
    try std.testing.expectEqual(@as(usize, 1), loaded.transfer.starts);
    try loaded.load(10);
    try std.testing.expectEqual(first.id, (try loaded.view()).id);
    try std.testing.expectError(error.AlreadyLoaded, loaded.begin());
    try loaded.unload();
    try loaded.load(10);
    try std.testing.expect(first.id != (try loaded.view()).id);
    loaded.transfer.fail = true;
    try loaded.unload();
    try std.testing.expectError(error.PiError, loaded.load(10));
    try std.testing.expectError(error.NotLoaded, loaded.view());
    try loaded.deinit(std.testing.failing_allocator);
}

const TestDefinition = struct {
    pub const byte_len = 17;
    pub const Storage = struct {};
    pub const Value = struct { bytes: []const u8, id: u64 };
    pub fn bind(bytes: []align(16) const u8, _: *Storage, id: u64) Value {
        return .{ .bytes = bytes, .id = id };
    }
};
const TestTransfer = struct {
    complete: bool = false,
    busy: bool = false,
    fail: bool = false,
    bytes: []u8 = &.{},
    starts: usize = 0,
    offset: u32 = 0,
    pub fn begin(self: *@This(), offset: u32, bytes: []align(16) u8) !void {
        if (self.busy) return error.PiBusy;
        self.bytes = bytes;
        self.offset = offset;
        self.starts += 1;
    }
    pub fn poll(self: *@This()) !bool {
        if (self.fail) return error.PiError;
        if (!self.complete) return false;
        @memset(self.bytes, 42);
        return true;
    }
};
