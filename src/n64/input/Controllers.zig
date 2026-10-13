//! Synchronous controller polling. One Controllers may use SI at a time; polling
//! completes its DMA before returning, so snapshots and the Controllers are movable.
const std = @import("std");
const si = @import("../hw/si.zig");
const JoybusBuffer = @import("joybus.zig").JoybusBuffer;
const Commands = @import("joybus.zig").Commands;

pub const Port = enum(u2) { one, two, three, four };
pub const Button = enum { a, b, z, start, d_up, d_down, d_left, d_right, l, r, c_up, c_down, c_left, c_right };
pub const DeviceType = enum(u8) { none, unknown, n64, mouse, game_cube };
pub const Accessory = enum(u8) { none, unknown, controller_pak, rumble_pak, transfer_pak, bio_sensor, snap_station };

/// The hardware response layout. Axes use the controller's signed raw range.
pub const State = packed struct {
    stick_y: i8 = 0,
    stick_x: i8 = 0,
    c_right: bool = false,
    c_left: bool = false,
    c_down: bool = false,
    c_up: bool = false,
    r: bool = false,
    l: bool = false,
    reserved: bool = false,
    reset: bool = false,
    d_right: bool = false,
    d_left: bool = false,
    d_down: bool = false,
    d_up: bool = false,
    start: bool = false,
    z: bool = false,
    b: bool = false,
    a: bool = false,

    pub fn held(self: State, button: Button) bool {
        return switch (button) {
            inline else => |value| @field(self, @tagName(value)),
        };
    }
};

const StickOptions = struct { deadzone: f32 = 0.15, range: f32 = 80 };
pub const Stick = struct { x: f32, y: f32 };

/// A value snapshot. Edges are relative to the preceding poll and remain stable
/// until the next poll. A failed read releases previously held buttons.
pub const Snapshot = struct {
    pub const Options = StickOptions;
    device_type: DeviceType = .none,
    state: State = .{},
    previous: State = .{},

    /// Radial deadzone and unit-length clamping. Raw axes remain in state.
    pub fn stick(self: Snapshot, options: StickOptions) Stick {
        std.debug.assert(std.math.isFinite(options.range) and options.range > 0);
        std.debug.assert(options.deadzone >= 0 and options.deadzone < 1);
        const x = @as(f32, @floatFromInt(self.state.stick_x)) / options.range;
        const y = @as(f32, @floatFromInt(self.state.stick_y)) / options.range;
        const length = @sqrt(x * x + y * y);
        if (length <= options.deadzone) return .{ .x = 0, .y = 0 };
        const magnitude = (@min(length, 1) - options.deadzone) / (1 - options.deadzone);
        return .{ .x = x * magnitude / length, .y = y * magnitude / length };
    }

    pub fn held(self: Snapshot, button: Button) bool {
        return self.state.held(button);
    }
    pub fn pressed(self: Snapshot, button: Button) bool {
        return self.state.held(button) and !self.previous.held(button);
    }
    pub fn released(self: Snapshot, button: Button) bool {
        return !self.state.held(button) and self.previous.held(button);
    }
    pub fn update(self: *Snapshot, state: State) void {
        self.previous = self.state;
        self.state = state;
    }
};

/// Owns fixed storage for all four ports. No heap allocation or teardown.
/// Do not interleave calls with another Controllers or raw Joybus/SI transactions.
const Controllers = @This();

buffer: JoybusBuffer align(64) = .{},
ports: [4]Snapshot = @splat(.{}),

pub fn init() Controllers {
    var self: Controllers = .{};
    si.setPifJoybusMode();
    self.refresh();
    return self;
}

/// Identify attached controller types; call again after hot-plugging.
pub fn refresh(self: *Controllers) void {
    const command = self.buffer.roundTripCommand(Commands.CommandIdentifyAll);
    inline for (0..4) |i| {
        const response = @field(command, "port" ++ std.fmt.comptimePrint("{d}", .{i}));
        self.ports[i].device_type = if (response.response_len & 0xc0 != 0) .none else deviceTypeFromId(response.response.id);
    }
}

pub fn poll(self: *Controllers) void {
    const command = self.buffer.roundTripCommand(Commands.CommandJoypadStateAll);
    inline for (0..4) |i| {
        self.ports[i].update(stateFromResponse(@field(command, "port" ++ std.fmt.comptimePrint("{d}", .{i}))));
    }
}

pub fn get(self: *const Controllers, port: Port) Snapshot {
    return self.ports[@intFromEnum(port)];
}

fn deviceTypeFromId(id: u16) DeviceType {
    return switch (id) {
        0 => .none,
        0x500 => .n64,
        0x200 => .mouse,
        0x900 => .game_cube,
        else => .unknown,
    };
}

/// PIF sets high receive-length bits on absent devices or failed reads.
pub fn stateFromResponse(command: Commands.CommandJoypadState) State {
    return if (command.response_len & 0xc0 == 0) command.response else .{};
}

test "snapshots retain button edges and raw axes until the next update" {
    var input: Snapshot = .{};
    inline for (comptime std.meta.tags(Button)) |button| {
        var state: State = .{ .stick_x = -80, .stick_y = 42 };
        @field(state, @tagName(button)) = true;
        input.update(state);
        try std.testing.expect(input.pressed(button));
        try std.testing.expect(input.held(button));
        try std.testing.expect(!input.released(button));
        try std.testing.expectEqual(@as(i8, -80), input.state.stick_x);
        input.update(state);
        try std.testing.expect(!input.pressed(button));
        input.update(.{});
        try std.testing.expect(input.released(button));
        try std.testing.expect(!input.held(button));
        input.update(.{});
        try std.testing.expect(!input.released(button));
    }
}

test "failed joybus reads release buttons and neutralize axes" {
    const pressed: State = .{ .a = true, .b = true, .stick_x = 42 };
    try std.testing.expectEqual(pressed, stateFromResponse(.{ .response = pressed }));
    for ([_]u8{ 0x44, 0x84, 0xc4 }) |response_len| {
        var input: Snapshot = .{ .state = pressed };
        input.update(stateFromResponse(.{ .response = @bitCast(@as(u32, 0xffffffff)), .response_len = response_len }));
        try std.testing.expect(input.released(.a));
        try std.testing.expectEqual(State{}, input.state);
    }
}

test "controller identities and independent port snapshots" {
    try std.testing.expectEqual(DeviceType.n64, deviceTypeFromId(0x500));
    try std.testing.expectEqual(DeviceType.mouse, deviceTypeFromId(0x200));
    try std.testing.expectEqual(DeviceType.game_cube, deviceTypeFromId(0x900));
    try std.testing.expectEqual(DeviceType.unknown, deviceTypeFromId(0xffff));
    const system: Controllers = .{ .ports = .{ .{ .state = .{ .a = true } }, .{}, .{}, .{} } };
    try std.testing.expect(system.get(.one).pressed(.a));
    try std.testing.expect(!system.get(.two).held(.a));
    try std.testing.expectEqual(@as(usize, 64), @alignOf(Controllers));
}

test "normalized stick has a radial deadzone and bounded diagonals" {
    try std.testing.expectEqual(Stick{ .x = 0, .y = 0 }, (Snapshot{ .state = .{ .stick_x = 8 } }).stick(.{}));
    try std.testing.expectEqual(Stick{ .x = 1, .y = 0 }, (Snapshot{ .state = .{ .stick_x = 80 } }).stick(.{}));
    const diagonal = (Snapshot{ .state = .{ .stick_x = 127, .stick_y = -128 } }).stick(.{});
    try std.testing.expectApproxEqAbs(@as(f32, 1), diagonal.x * diagonal.x + diagonal.y * diagonal.y, 0.0001);
    try std.testing.expect(diagonal.y < 0);
}
