//! Read-only bank snapshots. No graphics submission, allocation or RSP waits.
const std = @import("std");
const model = @import("memory_model.zig");
const pi = @import("../../pi/Transfer.zig");
var boot_bounds: model.Bounds = .{};
var cart_staging: [model.page_bytes]u8 align(16) = undefined;
var cart_transfer: pi = .{};

/// Call at startup after clearing BSS, before applications reuse SP DMEM.
pub fn initBootBounds() void {
    const detected = @as(*const volatile u32, @ptrFromInt(0xa4000000)).*;
    boot_bounds.rdram_size = if (detected == 8 * 1024 * 1024) detected else 4 * 1024 * 1024;
}

pub fn bounds() model.Bounds {
    return boot_bounds;
}

pub fn capture(limits: model.Bounds, state: model.State, max_attempts: u32) model.View {
    const page = model.window(limits, state.bank, state.address()) orelse return .{ .bank = state.bank, .status = .invalid_address };
    var view: model.View = .{ .bank = state.bank, .address = page.address };
    if (state.bank == .cart) {
        view.status = readCart(page, max_attempts);
        if (view.status != .ready) return view;
        @memcpy(view.bytes[0..page.length], cart_staging[0..page.length]);
    } else {
        const address = if (state.bank == .rdram) page.address | 0x20000000 else page.address;
        var offset: usize = 0;
        while (offset < page.length) : (offset += 4) {
            // SP memory and the cartridge bus require word-sized CPU accesses.
            const word = @as(*const volatile u32, @ptrFromInt(address + offset)).*;
            std.mem.writeInt(u32, view.bytes[offset..][0..4], word, .big);
        }
        view.status = .ready;
    }
    view.length = page.length;
    return view;
}

fn readCart(page: model.Window, max_attempts: u32) model.Status {
    // A timed-out DMA retains this static buffer until completion. Never reuse
    // it or reset/steal an application's active PI transfer to service the UI.
    if (cart_transfer.destination != null) cart_transfer.wait(max_attempts) catch |err| return piStatus(err);
    cart_transfer.begin(page.address - 0xb0000000, cart_staging[0..page.length]) catch |err| return piStatus(err);
    cart_transfer.wait(max_attempts) catch |err| return piStatus(err);
    return .ready;
}

fn piStatus(err: anyerror) model.Status {
    return switch (err) {
        error.PiBusy => .pi_busy,
        error.PiTimeout => .pi_timeout,
        else => .pi_error,
    };
}
