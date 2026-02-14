const config = @import("config");
comptime {
    if(@sizeOf(RomHeader) != 64)
        @panic("RomHeader is not 64 bytes");
}

const RomHeader = extern struct {
    pi_dom1_config: u32 align(1) = 0x80371240,
    clock_rate: u32 align(1) = 0x00000000,
    boot_address: u32 align(1) = 0x80000400,
    sdk_version: u32 align(1) = 0x00000000,
    checksum: u64 align(1) = 0,
    reserved1: u64 align(1) = 0,
    title: [20]u8 align(1) = [_]u8{0} ** 20,
    reserved2: [7]u8 align(1) = [_]u8{0} ** 7,
    gamecode: [4]u8 align(1) = [_]u8{0} ** 4,
    rom_version: u8 align(1) = 0,
};

export var rom_header: RomHeader linksection(".header") = blk: {
    var result: RomHeader = .{};

    // Insert the rom title
    const len = @min(result.title.len, config.title.len);
    @memcpy(result.title[0..len], config.title[0..len]);

    break :blk result;
};
