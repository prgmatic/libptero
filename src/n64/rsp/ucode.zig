const std = @import("std");

const header_size = 24;

pub const UCode = struct {
    text: []const u8,
    data: []const u8 = &.{},
    pc_start: u16 = 0,
    text_offset: u16 = 0,
    commands: []const u8 = &.{},
    state_offset: u16 = 0,
    state_len: u16 = 0,

    pub fn fromBlob(blob: []const u8) UCode {
        if (blob.len < header_size) {
            @panic("RSP program blob is missing its header");
        }

        const header = Header.read(blob[0..header_size]);
        const text_start = header_size;
        const text_end = text_start + header.text_len;
        const data_start = header.data_offset;
        const data_end = data_start + header.data_len;
        const commands_start = header.commands_offset;
        const commands_end = commands_start + header.command_count * Command.encoded_len;

        if (text_end > blob.len or data_end > blob.len or commands_end > blob.len) {
            @panic("RSP program blob has invalid segment bounds");
        }

        return .{
            .text = blob[text_start..text_end],
            .data = blob[data_start..data_end],
            .pc_start = header.pc_start,
            .text_offset = header.text_offset,
            .commands = blob[commands_start..commands_end],
            .state_offset = header.state_offset,
            .state_len = header.state_len,
        };
    }

    pub fn commandCount(self: UCode) usize {
        return self.commands.len / Command.encoded_len;
    }

    pub fn commandAt(self: UCode, index: usize) Command {
        if (index >= self.commandCount()) @panic("RSP command metadata index is out of bounds");
        return Command.read(self.commands[index * Command.encoded_len ..][0..Command.encoded_len]);
    }
};

pub const Command = struct {
    index: u8,
    size: u8,
    handler_offset: u16,

    const encoded_len = 4;

    fn read(bytes: *const [encoded_len]u8) Command {
        return .{
            .index = bytes[0],
            .size = bytes[1],
            .handler_offset = std.mem.readInt(u16, bytes[2..4], .big),
        };
    }
};

const Header = struct {
    text_len: u16,
    data_len: u16,
    data_offset: u16,
    pc_start: u16,
    text_offset: u16,
    commands_offset: u16,
    command_count: u16,
    state_offset: u16,
    state_len: u16,

    fn read(bytes: *const [header_size]u8) Header {
        return .{
            .text_len = std.mem.readInt(u16, bytes[0..2], .big),
            .data_len = std.mem.readInt(u16, bytes[2..4], .big),
            .data_offset = std.mem.readInt(u16, bytes[4..6], .big),
            .pc_start = std.mem.readInt(u16, bytes[6..8], .big),
            .text_offset = std.mem.readInt(u16, bytes[8..10], .big),
            .commands_offset = std.mem.readInt(u16, bytes[10..12], .big),
            .command_count = std.mem.readInt(u16, bytes[12..14], .big),
            .state_offset = std.mem.readInt(u16, bytes[14..16], .big),
            .state_len = std.mem.readInt(u16, bytes[16..18], .big),
        };
    }
};
