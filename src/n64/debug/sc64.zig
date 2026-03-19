const std = @import("std");
const pi = @import("../io/pi.zig");

const status: *volatile Status = @ptrFromInt(0xBFFF0000);
const data_0: *volatile u32 = @ptrFromInt(0xBFFF0004);
const data_1: *volatile u32 = @ptrFromInt(0xBFFF0008);
const identifier: *volatile u32 = @ptrFromInt(0xBFFF000C);
const key: *volatile u32 = @ptrFromInt(0xBFFF0010);
const irq: *volatile InteruptRequest = @ptrFromInt(0xBFFF0014);
const aux: *volatile u32 = @ptrFromInt(0xBFFF0018);
pub const data_buffer: *[8192/4]u32 = @ptrFromInt(0xBFFE0000);

const register_enable_0:     u32 = 0x5F554E4C;
const register_enable_1:     u32 = 0x4F434B5F;
const register_lock:         u32 = 0xFFFFFFFF;
const register_enable_reset: u32 = 0x00000000;
const identity_value:        u32 = 0x53437632;

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
    const len = str.len;
    const ptr: [*]const u8 = @ptrCast(str);
    var c = len / 4;
    const rem = @mod(len, 4);
    if(rem > 0)
        c += 1;
    for(0..c) |i| {
        var val: u32 = @as(u32, ptr[i * 4]) << 24;
        val |= @as(u32, ptr[i * 4 + 1]) << 16;
        val |= @as(u32, ptr[i * 4 + 2]) << 8;
        val |= @as(u32, ptr[i * 4 + 3]);
        data_buffer[i] = val;
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
    status.command_id = 'M';
    pi.waitIo();
    while (isUsbBusy()) {}
}

pub fn isUsbBusy() bool {
    pi.waitIo();
    while (status.command_busy) {}
    status.command_id = 'U';
    pi.waitIo();
    while (status.command_busy) {}
    return data_0.* & (1 << 31) > 0;
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

const InteruptRequest = packed struct(u32) {
    unused0: u8 = 0,
    enable_aux: bool,
    disable_aux: bool,
    enable_usb: bool,
    disable_usb: bool,
    unused2: u16 = 0,
    clear_aux: bool,
    clear_usb: bool,
    clear_cmd: bool,
    clear_btn: bool,
};
