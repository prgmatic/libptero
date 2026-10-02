//! Synchronous controller polling. One System may use SI at a time; polling
//! completes its DMA before returning, so snapshots and the System are movable.
const std = @import("std");
const si = @import("../interfaces/serial.zig");
const JoybusBuffer = @import("joybus.zig").JoybusBuffer;
const Commands = @import("joybus.zig").Commands;

pub const Port = enum(u2) { one, two, three, four };
pub const Button = enum { a, b, z, start, d_up, d_down, d_left, d_right, l, r, c_up, c_down, c_left, c_right };
pub const Style = enum(u8) { none, unknown, n64, mouse, game_cube };
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

/// A value snapshot. Edges are relative to the preceding poll and remain stable
/// until the next poll. A failed read releases previously held buttons.
pub const Snapshot = struct {
    style: Style = .none,
    state: State = .{},
    previous: State = .{},

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
/// Do not interleave calls with another System or raw Joybus/SI transactions.
pub const System = struct {
    buffer: JoybusBuffer align(64) = .{},
    ports: [4]Snapshot = @splat(.{}),

    pub fn init() System {
        var self: System = .{};
        si.setPifJoybusMode();
        self.refresh();
        return self;
    }

    /// Identify attached controller types; call again after hot-plugging.
    pub fn refresh(self: *System) void {
        const command = self.buffer.roundTripCommand(Commands.CommandIdentifyAll);
        inline for (0..4) |i| {
            const response = @field(command, "port" ++ std.fmt.comptimePrint("{d}", .{i}));
            self.ports[i].style = if (response.response_len & 0xc0 != 0) .none else styleFromId(response.response.id);
        }
    }

    pub fn poll(self: *System) void {
        const command = self.buffer.roundTripCommand(Commands.CommandJoypadStateAll);
        inline for (0..4) |i| {
            self.ports[i].update(stateFromResponse(@field(command, "port" ++ std.fmt.comptimePrint("{d}", .{i}))));
        }
    }

    pub fn get(self: *const System, port: Port) Snapshot {
        return self.ports[@intFromEnum(port)];
    }
};

fn styleFromId(id: u16) Style {
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
    try std.testing.expectEqual(Style.n64, styleFromId(0x500));
    try std.testing.expectEqual(Style.mouse, styleFromId(0x200));
    try std.testing.expectEqual(Style.game_cube, styleFromId(0x900));
    try std.testing.expectEqual(Style.unknown, styleFromId(0xffff));
    const system: System = .{ .ports = .{ .{ .state = .{ .a = true } }, .{}, .{}, .{} } };
    try std.testing.expect(system.get(.one).pressed(.a));
    try std.testing.expect(!system.get(.two).held(.a));
    try std.testing.expectEqual(@as(usize, 64), @alignOf(System));
}
