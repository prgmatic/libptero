const io = @import("io.zig");
const UCode = @import("ucode.zig").UCode;

pub const max_id = 15;
pub const commands_per_id = 16;
pub const max_command_count = max_id * commands_per_id;
pub const dmem_offset = 0x800;
pub const payload_offset = 0x200;
pub const backing_len = io.dmem_len - dmem_offset;

pub const Overlay = struct {
    id: u8,
    slot_count: u8,
    program: UCode,
    data: [backing_len]u8 align(16),
    data_len: usize,
    state: [io.dmem_len]u8 align(16),

    pub fn init(self: *Overlay, program: UCode) void {
        self.* = .{
            .id = 0,
            .slot_count = 0,
            .program = program,
            .data = undefined,
            .data_len = 0,
            .state = undefined,
        };
        @memset(&self.state, 0);
    }

    pub fn commandId(self: *const Overlay, command_index: u8) u8 {
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
};
