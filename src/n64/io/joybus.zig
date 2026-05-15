const JoypadState = @import("joypad.zig").JoypadState;
const si = @import("../interfaces/serial.zig");
const cache = @import("../cpu/cache.zig");

const pif_ram_size = 64;


pub const Commands = struct {

    pub const CommandIdentify = JoybusCommand(packed struct {
        extra: u8,
        id: u16,
    }, @as(u8, 0));
    pub const CommandJoypadState = JoybusCommand(JoypadState, @as(u8, 1));

    pub const CommandIdentifyAll = JoybusCommandAllPorts(CommandIdentify);
    pub const CommandJoypadStateAll = JoybusCommandAllPorts(CommandJoypadState);

    fn JoybusCommand(comptime Response: type, comptime commandValue: anytype) type {
        const Command = @TypeOf(commandValue);
        return packed struct {
            response: Response = undefined,
            command: Command = commandValue,
            response_len: u8 = @intCast(@bitSizeOf(Response) / 8),
            command_len: u8 = @intCast(@sizeOf(Command)),
        };
    }

    fn JoybusCommandAllPorts(comptime Command: type) type {
        return packed struct {
            port4: Command = .{},
            port3: Command = .{},
            port2: Command = .{},
            port1: Command = .{},
            port0: Command = .{},
        };
    }
};

pub const JoybusBuffer = struct {
    memory: [pif_ram_size / @sizeOf(u32)]u32 = undefined, 

    pub fn clear(b: *JoybusBuffer) void {
        @memset(&b.memory, 0);
    }

    pub fn sendCommand(b: *JoybusBuffer) void {
        si.dmaDramToPif(@intFromPtr(b));
    }

    pub fn readFromPif(b: *JoybusBuffer) void {
        si.dmaPifToDram(@intFromPtr(b));
    }

    pub fn roundTripCommand(b: *JoybusBuffer, CmdType: type) *CmdType {
        const cmd = b.as(CmdType);
        cmd.* = .{};
        // TODO: remove this
        b.memory[15] = 1;
        
        cache.writebackData(b);
        b.sendCommand();
        si.waitDmaIo();
        b.readFromPif();
        si.waitDmaIo();
        cache.invalidateData(b);
        return cmd;
    }

    pub inline fn as(b: *JoybusBuffer, comptime t: type) *t {
        return @ptrFromInt(@intFromPtr(b));
    }

    // pub fn setCommand(b: *JoybusBuffer, commandType: CommandType) void {
    //     switch (commandType) {
    //         .Identify => 
    //     }
    // }

    pub const CommandType = enum(u8) {
        Identify = 0,
        State = 1,
    };
};


