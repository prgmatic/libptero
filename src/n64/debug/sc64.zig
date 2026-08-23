const std = @import("std");
const pi = @import("../interfaces/parallel.zig");

const status_read: *const volatile Status = @ptrFromInt(0xBFFF0000);
const status_write: *volatile u32 = @ptrFromInt(0xBFFF0000);
const data_0: *volatile u32 = @ptrFromInt(0xBFFF0004);
const data_1: *volatile u32 = @ptrFromInt(0xBFFF0008);
const identifier: *volatile u32 = @ptrFromInt(0xBFFF000C);
const key: *volatile u32 = @ptrFromInt(0xBFFF0010);
const aux: *volatile u32 = @ptrFromInt(0xBFFF0018);
pub const data_buffer: *[8192 / 4]u32 = @ptrFromInt(0xBFFE0000);

const register_enable_0: u32 = 0x5F554E4C;
const register_enable_1: u32 = 0x4F434B5F;
const register_lock: u32 = 0xFFFFFFFF;
const register_enable_reset: u32 = 0x00000000;
const identity_value: u32 = 0x53437632;
const usb_wait_attempts = 1_000_000;

pub fn detect() bool {
    unlockRegisters();
    pi.waitIo();
    return identifier.* == identity_value;
}

fn unlockRegisters() void {
    pi.waitIo();
    key.* = register_enable_reset;
    pi.waitIo();
    key.* = register_enable_0;
    pi.waitIo();
    key.* = register_enable_1;
}

pub fn print(str: []const u8) void {
    if (str.len == 0 or !waitUsbReady()) return;
    const len = str.len;
    const word_count = std.mem.alignForward(usize, len, 4) / 4;
    for (0..word_count) |word_index| {
        var value: u32 = 0;
        inline for (0..4) |byte_index| {
            const index = word_index * 4 + byte_index;
            if (index < len) value |= @as(u32, str[index]) << (24 - byte_index * 8);
        }
        data_buffer[word_index] = value;
        pi.waitIo();
    }
    flushBuffer(str.len);
}

pub fn flushBuffer(size: u32) void {
    pi.waitIo();
    data_0.* = @intFromPtr(data_buffer);
    pi.waitIo();
    data_1.* = (size & 0xFFFFFF) | (1 << 24);
    pi.waitIo();
    status_write.* = 'M';
    pi.waitIo();
    _ = waitUsbReady();
}

fn waitUsbReady() bool {
    var remaining: u32 = usb_wait_attempts;
    while (isUsbBusy()) {
        if (remaining == 0) return false;
        remaining -= 1;
    }
    return true;
}

pub fn isUsbBusy() bool {
    pi.waitIo();
    if (!waitCommandReady()) return true;
    status_write.* = 'U';
    pi.waitIo();
    if (!waitCommandReady()) return true;
    return data_0.* & (1 << 31) > 0;
}

fn waitCommandReady() bool {
    var remaining: u32 = usb_wait_attempts;
    while (status_read.command_busy) {
        if (remaining == 0) return false;
        remaining -= 1;
    }
    return true;
}

const Status = packed struct(u32) {
    command_id: u8,
    command_irq_request: bool,
    unused: u13 = 0,
    aux_irq_mask: bool,
    aux_irq_pending: bool,
    usb_irq_mask: bool,
    usb_irq_pending: bool,
    command_irq_mask: bool,
    command_irq_pending: bool,
    button_irq_mask: bool,
    button_irq_pending: bool,
    command_error: bool,
    command_busy: bool,
};
