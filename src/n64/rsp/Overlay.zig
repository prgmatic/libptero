const io = @import("../hw/sp.zig");
const Program = @import("Program.zig");

const layout = @import("overlay_layout.zig");

pub const max_id = layout.max_id;
pub const commands_per_id = layout.commands_per_id;
pub const max_command_count = max_id * commands_per_id;
pub const dmem_offset = layout.header_dmem_offset;
pub const program_data_offset = layout.program_data_offset;
pub const backing_len = layout.backing_len;

const Overlay = @This();

id: u8,
slot_count: u8,
program: Program,
data: [backing_len]u8 align(16),
data_len: usize,
state: [io.dmem_len]u8 align(16),

pub fn init(self: *Overlay, program: Program) void {
    self.* = .{
        .id = 0,
        .slot_count = 0,
        .program = program,
        .data = undefined,
        .data_len = 0,
        .state = undefined,
    };
    @memset(&self.state, 0);
    @memcpy(self.state[dataAddress(program)..][0..program.data.len], program.data);
    @memcpy(self.state[program.state_offset..][0..program.state_init.len], program.state_init);
}

pub inline fn commandId(self: *const Overlay, command_index: u8) u8 {
    if (self.id == 0) {
        @panic("RSP overlay must be registered before commands are queued");
    }
    if (command_index / commands_per_id >= self.slot_count or
        @as(u16, self.id) + command_index / commands_per_id > max_id)
    {
        @panic("RSP overlay command index exceeds its registered slots");
    }
    return (self.id << 4) +% command_index;
}

pub const dataAddress = layout.dataAddress;
