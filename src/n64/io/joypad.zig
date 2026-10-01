const std = @import("std");
const si = @import("../interfaces/serial.zig");
const cache = @import("../cpu/cache.zig");
const JoybusBuffer = @import("joybus.zig").JoybusBuffer;
const Commands = @import("joybus.zig").Commands;

var joybus_buffer: *JoybusBuffer = undefined;
pub var joypads: []Joypad = undefined;

pub fn init(allocator: std.mem.Allocator) void {
    // TODO: catch this?
    joybus_buffer = allocator.create(JoybusBuffer) catch undefined;
    joypads = allocator.alloc(Joypad, 4) catch undefined;

    si.setPifJoybusMode();
    updateJoypadStatus();
}

pub fn updateJoypadStatus() void {
    const cmd = joybus_buffer.roundTripCommand(Commands.CommandIdentifyAll);

    joypads[0].style = getJoypadStyle(cmd.port0.response.id);
    joypads[1].style = getJoypadStyle(cmd.port1.response.id);
    joypads[2].style = getJoypadStyle(cmd.port2.response.id);
    joypads[3].style = getJoypadStyle(cmd.port3.response.id);
}

fn getJoypadStyle(deviceId: u16) JoypadStyle {
    return switch (deviceId) {
        0x0 => .None,
        0x500 => .N64,
        0x200 => .Mouse,
        0x900 => .GameCube,
        else => .Unknown,
    };
}

pub fn pollJoypadState() void {
    const cmd = joybus_buffer.roundTripCommand(Commands.CommandJoypadStateAll);

    joypads[0].state = stateFromResponse(cmd.port0);
    joypads[1].state = stateFromResponse(cmd.port1);
    joypads[2].state = stateFromResponse(cmd.port2);
    joypads[3].state = stateFromResponse(cmd.port3);
}

/// PIF sets the high receive-length bits on absent devices or failed reads.
/// The response bytes are not button data in that case (often all ones).
pub fn stateFromResponse(command: Commands.CommandJoypadState) JoypadState {
    return if (command.response_len & 0xc0 == 0) command.response else .{};
}

pub const Joypad = struct {
    style: JoypadStyle,
    state: JoypadState,
};

pub const JoypadStyle = enum(u8) { None, Unknown, N64, GameCube, Mouse };

pub const JoypadAccessory = enum(u8) { Noen, Unknown, ControllerPak, RumblePak, TransferPak, BioSensor, SnapStation };

pub const JoypadState = packed struct {
    y_axis: i8 = 0,
    x_axis: i8 = 0,
    c_right: bool = false,
    c_left: bool = false,
    c_down: bool = false,
    c_up: bool = false,
    rt: bool = false,
    lt: bool = false,
    unused: bool = false,
    reset: bool = false,
    d_right: bool = false,
    d_left: bool = false,
    d_down: bool = false,
    d_up: bool = false,
    start: bool = false,
    z: bool = false,
    b: bool = false,
    a: bool = false,
};

test "failed joybus reads do not press buttons" {
    const pressed: JoypadState = .{ .a = true, .b = true, .x_axis = 42 };
    try std.testing.expectEqual(pressed, stateFromResponse(.{ .response = pressed }));
    for ([_]u8{ 0x44, 0x84, 0xc4 }) |response_len| {
        try std.testing.expectEqual(JoypadState{}, stateFromResponse(.{
            .response = @bitCast(@as(u32, 0xffffffff)),
            .response_len = response_len,
        }));
    }
}
