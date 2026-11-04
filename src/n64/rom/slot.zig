//! Heterogeneous typed ROM owners in one reusable slot. Each owner keeps its
//! own loaded material table; drawing goes through the shared ModelAsset type.
const std = @import("std");
const scheduling = @import("scheduler.zig");

pub fn Slot(comptime assets: anytype) type {
    const fields = std.meta.fields(@TypeOf(assets));
    if (fields.len == 0) @compileError("Slot requires a named struct of ROM assets");
    const Tag = std.meta.FieldEnum(@TypeOf(assets));
    const Payload = blk: {
        var names: [fields.len][]const u8 = undefined;
        var types: [fields.len]type = undefined;
        for (fields, 0..) |field, index| {
            names[index] = field.name;
            types[index] = @TypeOf(@field(assets, field.name)).Loaded;
        }
        break :blk @Union(.auto, Tag, &names, &types, &@splat(.{}));
    };
    return struct {
        pub const Id = Tag;
        owner: ?Payload = null,

        pub fn storageSize() usize {
            comptime var size: usize = 0;
            inline for (fields) |field| size = @max(size, @field(assets, field.name).storageSize());
            return size;
        }
        /// Call only on an empty slot. Place the slot and backing bytes at their
        /// final addresses first. Both remain borrowed through loading/rendering.
        pub fn request(self: *@This(), id: Id, bytes: []align(16) u8, queue: *scheduling.Scheduler) !void {
            if (self.owner != null) return error.SlotOccupied;
            inline for (fields) |field| {
                if (id == @field(Id, field.name)) {
                    self.owner = @unionInit(Payload, field.name, try @field(assets, field.name).initBuffer(bytes));
                    errdefer self.owner = null;
                    try @field(self.owner.?, field.name).beginScheduled(queue, .background);
                    return;
                }
            }
            unreachable;
        }
        /// Call after queue.service/serviceAudio. Binds native metadata once.
        pub fn poll(self: *@This()) !bool {
            const owner = if (self.owner) |*value| value else return false;
            return switch (owner.*) {
                inline else => |*value| value.poll(),
            };
        }
        pub fn draw(self: *@This(), context: anytype) !void {
            const owner = if (self.owner) |*value| value else return error.EmptySlot;
            switch (owner.*) {
                inline else => |*value| context.drawModel(try value.view()),
            }
        }
        /// Retire only after all GPU/CPU borrowers have finished. Pending DMA
        /// rejects retirement, retaining the slot and its storage for retry.
        pub fn retire(self: *@This()) !void {
            const owner = if (self.owner) |*value| value else return;
            switch (owner.*) {
                inline else => |*value| try value.unload(),
            }
            self.owner = null;
        }
    };
}

fn FakeAsset(comptime size: usize) type {
    return struct {
        pub const Loaded = struct {
            loading: bool = false,
            ready: bool = false,
            pub fn beginScheduled(self: *@This(), _: *scheduling.Scheduler, _: scheduling.Priority) !void {
                self.loading = true;
            }
            pub fn poll(self: *@This()) !bool {
                self.loading = false;
                self.ready = true;
                return true;
            }
            pub fn view(self: *@This()) !usize {
                if (!self.ready) return error.NotLoaded;
                return size;
            }
            pub fn unload(self: *@This()) !void {
                if (self.loading) return error.AssetBusy;
                self.ready = false;
            }
        };
        pub fn storageSize(_: @This()) usize {
            return size;
        }
        pub fn initBuffer(_: @This(), bytes: []align(16) u8) !Loaded {
            if (bytes.len < size) return error.BufferTooSmall;
            return .{};
        }
    };
}

test "slot rejects replacement and pending retirement, then reuses storage for another type" {
    const Assets = Slot(.{ .small = FakeAsset(16){}, .large = FakeAsset(64){} });
    var slot: Assets = .{};
    var queue: scheduling.Scheduler = .{ .options = .{} };
    var bytes: [Assets.storageSize()]u8 align(16) = undefined;
    var context: struct {
        drawn: usize = 0,
        pub fn drawModel(self: *@This(), value: usize) void {
            self.drawn = value;
        }
    } = .{};
    try std.testing.expectEqual(@as(usize, 64), bytes.len);
    try std.testing.expect(!try slot.poll());
    try std.testing.expectError(error.EmptySlot, slot.draw(&context));
    try std.testing.expectError(error.BufferTooSmall, slot.request(.large, bytes[0..16], &queue));
    try slot.request(.small, &bytes, &queue);
    try std.testing.expectError(error.SlotOccupied, slot.request(.large, &bytes, &queue));
    try std.testing.expectError(error.NotLoaded, slot.draw(&context));
    try std.testing.expectError(error.AssetBusy, slot.retire());
    try std.testing.expect(try slot.poll());
    try slot.draw(&context);
    try std.testing.expectEqual(@as(usize, 16), context.drawn);
    try slot.retire();
    try slot.request(.large, &bytes, &queue);
    try std.testing.expect(try slot.poll());
    try slot.draw(&context);
    try std.testing.expectEqual(@as(usize, 64), context.drawn);
    try slot.retire();
    try slot.retire();
}
