const std = @import("std");

const header_size = 8;

pub const UCode = struct {
    text: []const u8,
    data: []const u8 = &.{},
    pc_start: u16 = 0,

    pub fn fromBlob(blob: []const u8) UCode {
        if (blob.len < header_size) {
            @panic("RSP program blob is missing its header");
        }

        const header = Header.read(blob[0..header_size]);
        const text_start = header_size;
        const text_end = text_start + header.text_len;
        const data_start = header.data_offset;
        const data_end = data_start + header.data_len;

        if (text_end > blob.len or data_end > blob.len) {
            @panic("RSP program blob has invalid segment bounds");
        }

        return .{
            .text = blob[text_start..text_end],
            .data = blob[data_start..data_end],
            .pc_start = header.pc_start,
        };
    }
};

const Header = struct {
    text_len: u16,
    data_len: u16,
    data_offset: u16,
    pc_start: u16,

    fn read(bytes: *const [header_size]u8) Header {
        return .{
            .text_len = std.mem.readInt(u16, bytes[0..2], .big),
            .data_len = std.mem.readInt(u16, bytes[2..4], .big),
            .data_offset = std.mem.readInt(u16, bytes[4..6], .big),
            .pc_start = std.mem.readInt(u16, bytes[6..8], .big),
        };
    }
};
